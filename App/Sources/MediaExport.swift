import Foundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Where one queued item came from. Everything reaches `GPMCClient.upload` as a
/// plain file on disk, so this is only ever a recipe for producing that file.
enum MediaSource: Equatable, Sendable {
    /// A `PHAsset` local identifier. Preferred: it carries the original
    /// filename and capture date, which a picker copy loses.
    case asset(localIdentifier: String)
    /// A picker selection we could not resolve to an asset (no library
    /// permission, or a cloud-only item chosen through the limited picker).
    /// Carries the item provider so the file is copied lazily at export time.
    case picked(PickedItem)
    /// An existing file. Used by tests and by anything that already staged one.
    case file(URL)
}

/// A picked item with no resolvable asset id. Wraps the provider so the file
/// can be copied lazily at export time. Reference identity is enough for the
/// queue's dedup, and picked items are never persisted.
final class PickedItem: @unchecked Sendable, Equatable {
    let provider: NSItemProvider
    init(_ provider: NSItemProvider) { self.provider = provider }
    static func == (lhs: PickedItem, rhs: PickedItem) -> Bool { lhs === rhs }
}

struct ExportedCompanion: Equatable, Sendable {
    let url: URL
    let filename: String
    let byteCount: Int64
}

struct ExportedMedia: Equatable, Sendable {
    let url: URL
    let filename: String
    let modified: Date
    let byteCount: Int64
    /// False for `.file` sources, which the exporter does not own and must not delete.
    let temporary: Bool
    /// True when PhotoKit (or the picker) identified this as a Live Photo.
    var isLivePhoto = false
    /// Motion track staged next to a Live Photo still. Nil for ordinary items.
    var companion: ExportedCompanion? = nil

    var totalByteCount: Int64 { byteCount + (companion?.byteCount ?? 0) }
}

/// Turns a `MediaSource` into a file `GPMCClient.upload` can read, and cleans
/// up after itself. Owned files live in protected, backup-excluded Application
/// Support so iOS cannot evict a body that its background session still needs.
actor MediaExporter {
    enum Failure: LocalizedError, Equatable {
        case missingAsset
        case noResource
        case unreadable(String)
        case liveOnly
        case incompleteLivePhoto
        case iCloudDownloadRequired
        var errorDescription: String? {
            switch self {
            case .missingAsset: return "That item is no longer in your photo library."
            case .noResource: return "That item has no file to upload."
            case .liveOnly: return "That item is a Live Photo motion track, which this release does not upload."
            case .incompleteLivePhoto: return "That Live Photo has no motion file, so it was skipped."
            case .iCloudDownloadRequired: return "That item is only in iCloud. It will continue when the app is open."
            case .unreadable(let detail): return "Could not read that item: \(detail)"
            }
        }
    }

    static let directoryName = "gpmc-uploads"

    static var root: URL {
        // Background URLSession upload bodies must not live in Caches: iOS may
        // evict that directory while a multi-hour task still owns the file.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Moves a system-owned temp file into our staging directory. Static so the
    /// `Transferable` closure, which runs wherever the system pleases, can use it.
    static func adopt(_ file: URL) throws -> URL {
        let destination = try stage(named: file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    /// Copy a picked item provider's file into staging. `loadFileRepresentation`
    /// hands back a URL valid only inside its closure, so the copy happens there.
    static func copyToStaging(
        from provider: NSItemProvider,
        incompleteLivePhotos: IncompleteLivePhotosPolicy = .uploadStill
    ) async throws -> ExportedMedia {
        let movie = UTType.movie.identifier
        let image = UTType.image.identifier
        let live = UTType.livePhoto.identifier
        let hasImage = provider.hasItemConformingToTypeIdentifier(image)
        let hasMovie = provider.hasItemConformingToTypeIdentifier(movie)
        let isLive = provider.hasItemConformingToTypeIdentifier(live) || (hasImage && hasMovie)
        if isLive, hasImage, hasMovie {
            let still = try await loadFile(from: provider, typeIdentifier: image)
            do {
                let motion = try await loadFile(from: provider, typeIdentifier: movie)
                return try adoptPair(still: still, motion: motion)
            } catch {
                if incompleteLivePhotos == .skip { throw Failure.incompleteLivePhoto }
                let url = try adopt(still)
                return try Self.describe(url, filename: url.lastPathComponent, modified: nil,
                                    temporary: true, isLivePhoto: true)
            }
        }
        if isLive, incompleteLivePhotos == .skip, !hasMovie {
            throw Failure.incompleteLivePhoto
        }
        let typeID: String
        if hasImage { typeID = image }
        else if hasMovie { typeID = movie }
        else { throw Failure.noResource }
        let url = try await loadFile(from: provider, typeIdentifier: typeID)
        let staged = try adopt(url)
        return try Self.describe(staged, filename: staged.lastPathComponent, modified: nil,
                            temporary: true, isLivePhoto: isLive)
    }

    private static func loadFile(from provider: NSItemProvider, typeIdentifier: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? Failure.noResource)
                }
            }
        }
    }

    /// Which PhotoKit resources to export. Prefer a consistent still+motion pair.
    static func resourcePlan(types: [PHAssetResourceType], isLivePhoto: Bool) -> ResourcePlan {
        let set = Set(types)
        let hasPhoto = set.contains(.photo)
        let hasFullPhoto = set.contains(.fullSizePhoto)
        let hasPaired = set.contains(.pairedVideo)
        let hasFullPaired = set.contains(.fullSizePairedVideo)
        if hasPhoto, hasPaired { return .livePair(still: .photo, motion: .pairedVideo) }
        if hasFullPhoto, hasFullPaired { return .livePair(still: .fullSizePhoto, motion: .fullSizePairedVideo) }
        if hasPhoto, hasFullPaired { return .livePair(still: .photo, motion: .fullSizePairedVideo) }
        if hasFullPhoto, hasPaired { return .livePair(still: .fullSizePhoto, motion: .pairedVideo) }
        let live = isLivePhoto || hasPaired || hasFullPaired
        if live {
            if let still = ([PHAssetResourceType.photo, .fullSizePhoto].first { set.contains($0) }) {
                return .liveStillOnly(still)
            }
            if hasPaired || hasFullPaired { return .motionOnly }
        }
        let preferred: [PHAssetResourceType] = [.photo, .video, .fullSizePhoto, .fullSizeVideo]
        if let type = preferred.first(where: { set.contains($0) }) { return .single(type) }
        return .none
    }

    enum ResourcePlan: Equatable {
        case single(PHAssetResourceType)
        case livePair(still: PHAssetResourceType, motion: PHAssetResourceType)
        case liveStillOnly(PHAssetResourceType)
        case motionOnly
        case none
    }

    static func stageDirectory() throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        try? (directory as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        return directory
    }

    static func stage(named name: String) throws -> URL {
        let safe = name.isEmpty ? "item" : name
        return try stageDirectory().appendingPathComponent(safe)
    }

    static func adopt(_ file: URL, into directory: URL) throws -> URL {
        let safe = file.lastPathComponent.isEmpty ? "item" : file.lastPathComponent
        let destination = directory.appendingPathComponent(safe)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    static func adoptPair(still: URL, motion: URL) throws -> ExportedMedia {
        let directory = try stageDirectory()
        let stillURL = try adopt(still, into: directory)
        let motionURL = try adopt(motion, into: directory)
        var media = try Self.describe(stillURL, filename: stillURL.lastPathComponent, modified: nil,
                                 temporary: true, isLivePhoto: true)
        let companionValues = try motionURL.resourceValues(forKeys: [.fileSizeKey])
        let companionSize = Int64(companionValues.fileSize ?? 0)
        guard companionSize > 0 else { throw Failure.unreadable("the file is empty") }
        media.companion = ExportedCompanion(
            url: motionURL, filename: motionURL.lastPathComponent, byteCount: companionSize
        )
        return media
    }

    /// Remove only orphaned staging directories. Files named by restored queue
    /// checkpoints may still be feeding an iOS-owned background upload.
    func purge(excluding retainedFiles: Set<URL> = []) {
        let retainedDirectories = Set(retainedFiles.map { $0.standardizedFileURL.deletingLastPathComponent() })
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: Self.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for child in children where !retainedDirectories.contains(child.standardizedFileURL) {
            try? FileManager.default.removeItem(at: child)
        }
    }

    func export(
        _ source: MediaSource,
        allowsNetworkAccess: Bool = true,
        incompleteLivePhotos: IncompleteLivePhotosPolicy = .uploadStill
    ) async throws -> ExportedMedia {
        switch source {
        case .file(let url):
            return try Self.describe(url, filename: url.lastPathComponent, modified: nil, temporary: false)
        case .asset(let identifier):
            return try await exportAsset(
                identifier,
                allowsNetworkAccess: allowsNetworkAccess,
                incompleteLivePhotos: incompleteLivePhotos
            )
        case .picked(let picked):
            return try await Self.copyToStaging(from: picked.provider, incompleteLivePhotos: incompleteLivePhotos)
        }
    }

    /// Remove a staged file once the queue is finished with it.
    func discard(_ media: ExportedMedia) {
        guard media.temporary else { return }
        try? FileManager.default.removeItem(at: media.url.deletingLastPathComponent())
    }

    private func exportAsset(
        _ identifier: String,
        allowsNetworkAccess: Bool,
        incompleteLivePhotos: IncompleteLivePhotosPolicy
    ) async throws -> ExportedMedia {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw Failure.missingAsset
        }
        let resources = PHAssetResource.assetResources(for: asset)
        let isLivePhoto = asset.mediaSubtypes.contains(.photoLive)
            || resources.contains { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo }
        let plan = Self.resourcePlan(types: resources.map(\.type), isLivePhoto: isLivePhoto)
        switch plan {
        case .none:
            throw Failure.noResource
        case .motionOnly:
            throw Failure.liveOnly
        case .liveStillOnly:
            if incompleteLivePhotos == .skip { throw Failure.incompleteLivePhoto }
            fallthrough
        case .single:
            let preferred: [PHAssetResourceType]
            if case .liveStillOnly(let still) = plan { preferred = [still] }
            else if case .single(let type) = plan { preferred = [type] }
            else { preferred = [.photo, .video, .fullSizePhoto, .fullSizeVideo] }
            guard let resource = preferred.compactMap({ type in resources.first { $0.type == type } }).first else {
                throw Failure.noResource
            }
            return try await writeResource(
                resource,
                modified: asset.creationDate ?? asset.modificationDate,
                allowsNetworkAccess: allowsNetworkAccess,
                isLivePhoto: isLivePhoto
            )
        case .livePair(let stillType, let motionType):
            guard let still = resources.first(where: { $0.type == stillType }),
                  let motion = resources.first(where: { $0.type == motionType }) else {
                throw Failure.noResource
            }
            return try await writeLivePair(
                still: still,
                motion: motion,
                modified: asset.creationDate ?? asset.modificationDate,
                allowsNetworkAccess: allowsNetworkAccess
            )
        }
    }

    private func writeResource(
        _ resource: PHAssetResource,
        modified: Date?,
        allowsNetworkAccess: Bool,
        isLivePhoto: Bool
    ) async throws -> ExportedMedia {
        let destination = try Self.stage(named: resource.originalFilename)
        do {
            try await write(resource, to: destination, allowsNetworkAccess: allowsNetworkAccess)
            return try Self.describe(destination, filename: resource.originalFilename,
                                     modified: modified, temporary: true, isLivePhoto: isLivePhoto)
        } catch {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            throw error
        }
    }

    private func writeLivePair(
        still: PHAssetResource,
        motion: PHAssetResource,
        modified: Date?,
        allowsNetworkAccess: Bool
    ) async throws -> ExportedMedia {
        let directory = try Self.stageDirectory()
        let stillURL = directory.appendingPathComponent(
            still.originalFilename.isEmpty ? "still" : still.originalFilename
        )
        let motionName = motion.originalFilename.isEmpty ? "motion.mov" : motion.originalFilename
        let motionURL = directory.appendingPathComponent(
            motionName == stillURL.lastPathComponent ? "motion-\(motionName)" : motionName
        )
        do {
            try await write(still, to: stillURL, allowsNetworkAccess: allowsNetworkAccess)
            try await write(motion, to: motionURL, allowsNetworkAccess: allowsNetworkAccess)
            var media = try Self.describe(stillURL, filename: still.originalFilename,
                                          modified: modified, temporary: true, isLivePhoto: true)
            let companion = try Self.describe(motionURL, filename: motion.originalFilename,
                                              modified: modified, temporary: true)
            media.companion = ExportedCompanion(
                url: companion.url, filename: companion.filename, byteCount: companion.byteCount
            )
            return media
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func write(
        _ resource: PHAssetResource,
        to destination: URL,
        allowsNetworkAccess: Bool
    ) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowsNetworkAccess
        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            let nsError = error as NSError
            if !allowsNetworkAccess,
               nsError.domain == PHPhotosErrorDomain,
               nsError.code == 3164 {
                throw Failure.iCloudDownloadRequired
            }
            throw Failure.unreadable(error.localizedDescription)
        }
    }

    private static func describe(
        _ url: URL,
        filename: String,
        modified: Date?,
        temporary: Bool,
        isLivePhoto: Bool = false
    ) throws -> ExportedMedia {
        if temporary {
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values?.fileSize ?? 0)
        guard size > 0 else { throw Failure.unreadable("the file is empty") }
        return ExportedMedia(url: url, filename: filename.isEmpty ? url.lastPathComponent : filename,
                             modified: modified ?? values?.contentModificationDate ?? Date(),
                             byteCount: size, temporary: temporary, isLivePhoto: isLivePhoto)
    }
}

/// Photo library permission, kept separate so the picker can be used without it
/// and the asset path can simply be skipped when it is not granted.
enum MediaLibrary {
    static var isReadable: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    @discardableResult
    static func requestReadAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Prefer asset identifiers so filenames and capture dates survive; fall
    /// back to the item provider for a lazy copy when the library is off limits.
    static func sources(forPickerResults results: [PHPickerResult]) -> [MediaSource] {
        let readable = isReadable
        return results.map { result in
            if readable, let identifier = result.assetIdentifier { return .asset(localIdentifier: identifier) }
            return .picked(PickedItem(result.itemProvider))
        }
    }
}

extension PHAssetResourceManager {
    func writeData(for resource: PHAssetResource, toFile url: URL, options: PHAssetResourceRequestOptions) async throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let writeFailure = PhotoResourceWriteFailure()
        let cancellation = PhotoResourceRequestCancellation(manager: self)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let requestID = self.requestData(for: resource, options: options) { data in
                    do { try handle.write(contentsOf: data) }
                    catch { writeFailure.record(error); cancellation.cancel() }
                } completionHandler: { error in
                    if let failure = writeFailure.error { continuation.resume(throwing: failure) }
                    else if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
                cancellation.setRequestID(requestID)
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
    }
}

private final class PhotoResourceWriteFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    var error: Error? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func record(_ error: Error) {
        lock.lock()
        if stored == nil { stored = error }
        lock.unlock()
    }
}

private final class PhotoResourceRequestCancellation: @unchecked Sendable {
    private let manager: PHAssetResourceManager
    private let lock = NSLock()
    private var requestID: PHAssetResourceDataRequestID?
    private var cancelled = false

    init(manager: PHAssetResourceManager) { self.manager = manager }

    func setRequestID(_ requestID: PHAssetResourceDataRequestID) {
        lock.lock()
        self.requestID = requestID
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { manager.cancelDataRequest(requestID) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let requestID = requestID
        lock.unlock()
        if let requestID { manager.cancelDataRequest(requestID) }
    }
}
