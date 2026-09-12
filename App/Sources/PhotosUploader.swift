import Foundation

/// Serialises and rate-limits the phase callbacks `GPMCClient` fires
/// synchronously from its hashing loop and its `URLSessionTaskDelegate`.
///
/// The previous `Task { await emit(...) }` per callback spawned one unstructured
/// task per progress tick — thousands for a large video — and unstructured tasks
/// carry no ordering guarantee, so a later fraction could be applied before an
/// earlier one and the bar would visibly jump backwards. A single consumer keeps
/// the order, and coalescing to the newest pending state keeps the main actor
/// out of a hot loop it gains nothing from.
final class UploadPhaseRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: UploadItem.State?
    private var lastSentAt = Date.distantPast
    private var draining = false
    private var stopped = false
    private let emit: UploadEventSink
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.1, emit: @escaping UploadEventSink) {
        self.interval = interval
        self.emit = emit
    }

    /// Safe to call from any thread, including a delegate queue.
    func report(_ state: UploadItem.State) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        pending = state
        let shouldStart = !draining
        if shouldStart { draining = true }
        lock.unlock()
        guard shouldStart else { return }
        Task { await self.drain() }
    }

    /// Flush whatever is pending, ignoring the rate limit. Used for the phase
    /// changes that matter for the row's meaning rather than its percentage.
    /// Drop anything still pending and refuse further reports. Called once the
    /// worker has a terminal outcome, so a late progress tick cannot land on a
    /// row that has already moved on.
    func stop() {
        lock.lock()
        stopped = true
        pending = nil
        lock.unlock()
    }

    func flush() async {
        let state: UploadItem.State?
        lock.lock()
        state = pending
        pending = nil
        lastSentAt = Date()
        lock.unlock()
        if let state { await emit(.state(state)) }
    }

    private func drain() async {
        while true {
            let wait: TimeInterval
            let state: UploadItem.State?
            lock.lock()
            let elapsed = Date().timeIntervalSince(lastSentAt)
            if elapsed >= interval, let next = pending {
                state = next
                pending = nil
                lastSentAt = Date()
                wait = 0
            } else if pending != nil {
                state = nil
                wait = max(0, interval - elapsed)
            } else {
                draining = false
                lock.unlock()
                return
            }
            lock.unlock()
            if let state { await emit(.state(state)) }
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
    }
}

/// The one real `UploadWorker`: export the item to a file, hand it to
/// `GPMCClient`, and retain it across retry/relaunch boundaries until the
/// transfer commits or reaches a terminal state.
///
/// Kept separate from `UploadQueue` so the queue's state machine can be tested
/// with a stub worker and no photo library, network or credential in sight.
struct PhotosUploader {
    let exporter: MediaExporter
    /// Resolved per item rather than captured, so a reconnect swaps the client
    /// under a queue that is already running.
    let client: @Sendable () async -> GPMCClient?
    /// Items at least this large are noted in the diagnostic log together with
    /// the memory available, since a large video is the likeliest thing to push
    /// the app over iOS's memory limit.
    static let largeItemThreshold: Int64 = 1_000_000_000

    func worker() -> UploadWorker {
        let exporter = self.exporter
        let client = self.client
        let largeItemThreshold = Self.largeItemThreshold
        return { id, source, restoredCheckpoint, options, emit in
            let relay = UploadPhaseRelay(emit: emit)
            defer { relay.stop() }
            guard let client = await client() else {
                throw GPMCError(kind: .credentialRejected, message: "No Google account is connected. Connect one and try again.")
            }
            var checkpoint = restoredCheckpoint
            if let restored = restoredCheckpoint,
               !FileManager.default.fileExists(atPath: restored.filePath)
                || (restored.companionFilePath.map { !FileManager.default.fileExists(atPath: $0) } ?? false) {
                checkpoint = nil
                await emit(.checkpoint(nil))
                DiagnosticEventLog.shared.record(
                    "upload",
                    "A saved upload copy was missing, so the item is being prepared again",
                    level: .warning
                )
            }
            if checkpoint == nil {
                await emit(.state(.exporting))
                let media: ExportedMedia
                do {
                    media = try await exporter.export(
                        source,
                        allowsNetworkAccess: options.allowsICloudDownload,
                        incompleteLivePhotos: options.incompleteLivePhotos
                    )
                } catch MediaExporter.Failure.incompleteLivePhoto {
                    return .skipped
                }
                if media.totalByteCount >= largeItemThreshold {
                    DiagnosticEventLog.shared.record(
                        "upload",
                        "Prepared a large item (\(DiagnosticProcessInfo.bytes(media.totalByteCount))) for upload; \(DiagnosticProcessInfo.memoryDescription())"
                    )
                }
                if media.isLivePhoto, media.companion == nil, options.incompleteLivePhotos == .skip {
                    await exporter.discard(media)
                    return .skipped
                }
                checkpoint = UploadCheckpoint(
                    filePath: media.url.standardizedFileURL.path,
                    filename: media.filename,
                    modified: media.modified,
                    byteCount: media.byteCount,
                    temporary: media.temporary,
                    prepared: nil,
                    continuesAfterProcessExit: await client.usesBackgroundFileTransfers,
                    companionFilePath: media.companion?.url.standardizedFileURL.path,
                    companionFilename: media.companion?.filename,
                    companionByteCount: media.companion?.byteCount
                )
                let name = media.companion.map { "\(media.filename) + \($0.filename)" } ?? media.filename
                await emit(.described(name: name, byteCount: media.totalByteCount))
                await emit(.checkpoint(checkpoint))
            }
            guard var checkpoint else {
                throw GPMCError(message: "Could not stage the upload.")
            }
            try Task.checkCancellation()

            if checkpoint.isLivePhoto {
                return try await Self.uploadLivePhoto(
                    id: id, checkpoint: &checkpoint, client: client, exporter: exporter,
                    options: options, relay: relay, emit: emit
                )
            }

            return try await Self.uploadSingle(
                id: id, checkpoint: &checkpoint, client: client, exporter: exporter,
                options: options, relay: relay, emit: emit
            )
        }
    }

    func checkpointCleaner() -> UploadCheckpointCleaner {
        let exporter = self.exporter
        let client = self.client
        return { id, checkpoint in
            if let client = await client() {
                await client.cancelTransfer(id)
                if let companionID = checkpoint.companionTransferID {
                    await client.cancelTransfer(companionID)
                }
            } else {
                await BackgroundFileUploadTransport.shared.cancel(transferID: id)
                if let companionID = checkpoint.companionTransferID {
                    await BackgroundFileUploadTransport.shared.cancel(transferID: companionID)
                }
            }
            await exporter.discard(checkpoint.exportedMedia)
        }
    }

    private static func uploadSingle(
        id: UUID, checkpoint: inout UploadCheckpoint, client: GPMCClient, exporter: MediaExporter,
        options: UploadOptions, relay: UploadPhaseRelay, emit: UploadEventSink
    ) async throws -> UploadOutcome {
        if checkpoint.prepared == nil {
            let preparation = try await client.prepareUpload(
                file: checkpoint.fileURL,
                filename: checkpoint.filename,
                modified: checkpoint.modified
            ) { phase in
                relay.report(phase.itemState)
            }
            await relay.flush()
            switch preparation {
            case .alreadyBackedUp(let mediaKey):
                await exporter.discard(checkpoint.exportedMedia)
                await emit(.checkpoint(nil))
                return .alreadyBackedUp(mediaKey: mediaKey)
            case .ready(let prepared):
                checkpoint.prepared = prepared
                await emit(.checkpoint(checkpoint))
            }
        }

        guard let prepared = checkpoint.prepared else {
            throw GPMCError(message: "Could not prepare the upload.")
        }
        let completed: PreparedUpload
        do {
            completed = try await client.transfer(prepared, file: checkpoint.fileURL, transferID: id,
                                                  foreground: checkpoint.continuesAfterProcessExit == false) { phase in
                relay.report(phase.itemState)
            }
            await relay.flush()
        } catch {
            await client.forgetTransfer(id)
            checkpoint.prepared = nil
            if (error as? GPMCError)?.kind == .invalidUploadReceipt {
                checkpoint.continuesAfterProcessExit = false
                checkpoint.retriedAfterInvalidReceipt = true
                DiagnosticEventLog.shared.record(
                    "upload",
                    "Google returned an unusable upload receipt; this item will retry as a foreground upload, which only runs while the app is open",
                    level: .warning
                )
            }
            await emit(.checkpoint(checkpoint))
            throw error
        }
        checkpoint.prepared = completed
        await emit(.checkpoint(checkpoint))

        let outcome: UploadOutcome
        do {
            outcome = try await client.commit(completed,
                                              useQuota: options.useQuota,
                                              saver: options.storageSaver) { phase in
                relay.report(phase.itemState)
            }
        } catch let error as GPMCError where error.kind == .invalidUploadReceipt {
            await client.forgetTransfer(id)
            checkpoint.prepared = nil
            checkpoint.continuesAfterProcessExit = false
            guard checkpoint.retriedAfterInvalidReceipt != true else {
                await emit(.checkpoint(checkpoint))
                DiagnosticEventLog.shared.record(
                    "upload",
                    "Google rejected an upload's finalization again after a fresh transfer, so the item was not retried further",
                    level: .error
                )
                throw GPMCError(kind: .malformed, message: error.message, status: error.status)
            }
            DiagnosticEventLog.shared.record(
                "upload",
                "Google rejected an upload's receipt at finalization; transferring the item again while the app is open",
                level: .warning
            )
            checkpoint.retriedAfterInvalidReceipt = true
            await emit(.checkpoint(checkpoint))
            throw error
        }
        await relay.flush()
        await client.forgetTransfer(id)
        await exporter.discard(checkpoint.exportedMedia)
        await emit(.checkpoint(nil))
        return outcome
    }

    private static func uploadLivePhoto(
        id: UUID, checkpoint: inout UploadCheckpoint, client: GPMCClient, exporter: MediaExporter,
        options: UploadOptions, relay: UploadPhaseRelay, emit: UploadEventSink
    ) async throws -> UploadOutcome {
        guard let videoPath = checkpoint.companionFilePath,
              let videoFilename = checkpoint.companionFilename else {
            if options.incompleteLivePhotos == .skip {
                await exporter.discard(checkpoint.exportedMedia)
                await emit(.checkpoint(nil))
                return .skipped
            }
            return try await uploadSingle(
                id: id, checkpoint: &checkpoint, client: client, exporter: exporter,
                options: options, relay: relay, emit: emit
            )
        }
        let videoURL = URL(fileURLWithPath: videoPath)

        if checkpoint.liveKind == nil {
            let preparation = try await client.prepareLivePhoto(
                photo: checkpoint.fileURL,
                video: videoURL,
                photoFilename: checkpoint.filename,
                videoFilename: videoFilename,
                modified: checkpoint.modified,
                updateExisting: options.updateExistingPhotosToLive
            ) { phase in
                relay.report(phase.itemState)
            }
            await relay.flush()
            switch preparation {
            case .alreadyBackedUp(let mediaKey):
                await exporter.discard(checkpoint.exportedMedia)
                await emit(.checkpoint(nil))
                return .alreadyBackedUp(mediaKey: mediaKey)
            case .skippedRemoteVideo:
                await exporter.discard(checkpoint.exportedMedia)
                await emit(.checkpoint(nil))
                return .skipped
            case .create(let photo, let video):
                checkpoint.liveKind = .create
                checkpoint.prepared = photo
                checkpoint.companionPrepared = video
                checkpoint.companionTransferID = UUID()
                await emit(.checkpoint(checkpoint))
            case .reconcile(let video, let photoSHA1):
                checkpoint.liveKind = .reconcile
                checkpoint.companionPrepared = video
                checkpoint.companionTransferID = UUID()
                checkpoint.reconcilePhotoSHA1 = photoSHA1
                await emit(.checkpoint(checkpoint))
            }
        }

        let foreground = checkpoint.continuesAfterProcessExit == false
        let stillTotal = checkpoint.byteCount
        let motionTotal = checkpoint.companionByteCount ?? 0
        let pairTotal = max(1, stillTotal + motionTotal)

        if checkpoint.liveKind == .create, let prepared = checkpoint.prepared, prepared.receipt == nil {
            do {
                let completed = try await client.transfer(
                    prepared, file: checkpoint.fileURL, transferID: id, foreground: foreground
                ) { phase in
                    if case .sending(let sent, _) = phase {
                        relay.report(.uploading(fraction: Double(sent) / Double(pairTotal)))
                    } else {
                        relay.report(phase.itemState)
                    }
                }
                await relay.flush()
                checkpoint.prepared = completed
                await emit(.checkpoint(checkpoint))
            } catch {
                await client.forgetTransfer(id)
                Self.resetLiveReceipts(&checkpoint, error: error)
                await emit(.checkpoint(checkpoint))
                throw error
            }
        }

        if let companionID = checkpoint.companionTransferID,
           let prepared = checkpoint.companionPrepared, prepared.receipt == nil {
            let stillSent = checkpoint.liveKind == .create ? stillTotal : 0
            do {
                let completed = try await client.transfer(
                    prepared, file: videoURL, transferID: companionID, foreground: foreground
                ) { phase in
                    if case .sending(let sent, _) = phase {
                        relay.report(.uploading(fraction: Double(stillSent + sent) / Double(pairTotal)))
                    } else {
                        relay.report(phase.itemState)
                    }
                }
                await relay.flush()
                checkpoint.companionPrepared = completed
                await emit(.checkpoint(checkpoint))
            } catch {
                await client.forgetTransfer(companionID)
                Self.resetLiveReceipts(&checkpoint, error: error)
                await emit(.checkpoint(checkpoint))
                throw error
            }
        }

        let outcome: UploadOutcome
        do {
            switch checkpoint.liveKind {
            case .create:
                guard let photo = checkpoint.prepared, let video = checkpoint.companionPrepared else {
                    throw GPMCError(message: "Could not prepare the Live Photo upload.")
                }
                outcome = try await client.commitLivePhoto(
                    photo: photo, video: video, useQuota: options.useQuota, saver: options.storageSaver
                ) { phase in
                    relay.report(phase.itemState)
                }
            case .reconcile:
                guard let video = checkpoint.companionPrepared,
                      let photoSHA1 = checkpoint.reconcilePhotoSHA1 else {
                    throw GPMCError(message: "Could not prepare the Live Photo update.")
                }
                outcome = try await client.reconcileLivePhoto(
                    video: video, photoSHA1: photoSHA1, useQuota: options.useQuota, saver: options.storageSaver
                ) { phase in
                    relay.report(phase.itemState)
                }
            case nil:
                throw GPMCError(message: "Could not prepare the Live Photo upload.")
            }
        } catch let error as GPMCError where error.kind == .invalidUploadReceipt {
            await client.forgetTransfer(id)
            if let companionID = checkpoint.companionTransferID {
                await client.forgetTransfer(companionID)
            }
            let alreadyRetried = checkpoint.retriedAfterInvalidReceipt == true
            Self.resetLiveReceipts(&checkpoint, error: error)
            guard !alreadyRetried else {
                await emit(.checkpoint(checkpoint))
                DiagnosticEventLog.shared.record(
                    "upload",
                    "Google rejected an upload's finalization again after a fresh transfer, so the item was not retried further",
                    level: .error
                )
                throw GPMCError(kind: .malformed, message: error.message, status: error.status)
            }
            DiagnosticEventLog.shared.record(
                "upload",
                "Google rejected an upload's receipt at finalization; transferring the item again while the app is open",
                level: .warning
            )
            checkpoint.retriedAfterInvalidReceipt = true
            await emit(.checkpoint(checkpoint))
            throw error
        }
        await relay.flush()
        await client.forgetTransfer(id)
        if let companionID = checkpoint.companionTransferID {
            await client.forgetTransfer(companionID)
        }
        await exporter.discard(checkpoint.exportedMedia)
        await emit(.checkpoint(nil))
        return outcome
    }

    private static func resetLiveReceipts(_ checkpoint: inout UploadCheckpoint, error: Error) {
        checkpoint.prepared = nil
        checkpoint.companionPrepared = nil
        checkpoint.liveKind = nil
        checkpoint.reconcilePhotoSHA1 = nil
        if (error as? GPMCError)?.kind == .invalidUploadReceipt {
            checkpoint.continuesAfterProcessExit = false
            checkpoint.retriedAfterInvalidReceipt = true
            DiagnosticEventLog.shared.record(
                "upload",
                "Google returned an unusable upload receipt; this item will retry as a foreground upload, which only runs while the app is open",
                level: .warning
            )
        }
    }
}

private extension UploadCheckpoint {
    var exportedMedia: ExportedMedia {
        ExportedMedia(url: fileURL, filename: filename, modified: modified,
                      byteCount: byteCount, temporary: temporary)
    }
}

extension UploadPhase {
    /// Byte-level client progress mapped onto the row states the activity list shows.
    var itemState: UploadItem.State {
        switch self {
        case .hashing(let fraction): return .hashing(fraction: fraction)
        case .checkingDuplicate: return .checkingDuplicate
        case .preparing: return .uploading(fraction: 0)
        case .sending(let sent, let total): return .uploading(fraction: total > 0 ? min(1, Double(sent) / Double(total)) : 0)
        case .finalizing: return .finalizing
        }
    }
}
