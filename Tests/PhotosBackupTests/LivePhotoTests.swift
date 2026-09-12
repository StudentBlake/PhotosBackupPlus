import XCTest
import Photos
import CryptoKit
@testable import PhotosBackup

final class LivePhotoTests: XCTestCase {

    func testResourcePlanPrefersPhotoAndPairedVideo() {
        let plan = MediaExporter.resourcePlan(
            types: [.photo, .pairedVideo, .fullSizePhoto, .fullSizePairedVideo],
            isLivePhoto: true
        )
        XCTAssertEqual(plan, .livePair(still: .photo, motion: .pairedVideo))
    }

    func testResourcePlanFallsBackToFullSizePair() {
        let plan = MediaExporter.resourcePlan(types: [.fullSizePhoto, .fullSizePairedVideo], isLivePhoto: true)
        XCTAssertEqual(plan, .livePair(still: .fullSizePhoto, motion: .fullSizePairedVideo))
    }

    func testResourcePlanTreatsMissingMotionAsStillOnly() {
        XCTAssertEqual(
            MediaExporter.resourcePlan(types: [.photo], isLivePhoto: true),
            .liveStillOnly(.photo)
        )
    }

    func testResourcePlanTreatsMotionOnlyAsMotionOnly() {
        XCTAssertEqual(
            MediaExporter.resourcePlan(types: [.pairedVideo], isLivePhoto: true),
            .motionOnly
        )
    }

    func testResourcePlanKeepsOrdinaryPhotosSingle() {
        XCTAssertEqual(
            MediaExporter.resourcePlan(types: [.photo, .video], isLivePhoto: false),
            .single(.photo)
        )
    }

    func testDecisionTable() {
        XCTAssertEqual(
            GPMCClient.livePhotoDecision(photoRemoteKey: "STILL", videoRemoteKey: nil, updateExisting: false),
            .alreadyBackedUp(mediaKey: "STILL")
        )
        XCTAssertEqual(
            GPMCClient.livePhotoDecision(photoRemoteKey: "STILL", videoRemoteKey: nil, updateExisting: true),
            .reconcile
        )
        XCTAssertEqual(
            GPMCClient.livePhotoDecision(photoRemoteKey: nil, videoRemoteKey: "MOV", updateExisting: true),
            .skipRemoteVideo
        )
        XCTAssertEqual(
            GPMCClient.livePhotoDecision(photoRemoteKey: nil, videoRemoteKey: nil, updateExisting: false),
            .create
        )
    }

    func testOldCheckpointJSONWithoutCompanionFieldsStillDecodes() throws {
        let json = """
        {"filePath":"/tmp/IMG.HEIC","filename":"IMG.HEIC","modified":0,"byteCount":12,"temporary":true}
        """.data(using: .utf8)!
        let checkpoint = try JSONDecoder().decode(UploadCheckpoint.self, from: json)
        XCTAssertEqual(checkpoint.filename, "IMG.HEIC")
        XCTAssertNil(checkpoint.companionFilePath)
        XCTAssertNil(checkpoint.liveKind)
        XCTAssertFalse(checkpoint.isLivePhoto)
    }

    func testCompanionCheckpointRoundTrips() throws {
        let checkpoint = UploadCheckpoint(
            filePath: "/tmp/a/IMG.HEIC",
            filename: "IMG.HEIC",
            modified: Date(timeIntervalSince1970: 1_600_000_000),
            byteCount: 100,
            temporary: true,
            prepared: nil,
            companionFilePath: "/tmp/a/IMG.MOV",
            companionFilename: "IMG.MOV",
            companionByteCount: 200,
            companionTransferID: UUID(),
            liveKind: .create
        )
        let restored = try JSONDecoder().decode(UploadCheckpoint.self, from: JSONEncoder().encode(checkpoint))
        XCTAssertEqual(restored.companionFilename, "IMG.MOV")
        XCTAssertEqual(restored.companionByteCount, 200)
        XCTAssertEqual(restored.liveKind, .create)
        XCTAssertTrue(restored.isLivePhoto)
    }

    func testPurgeKeepsCompanionDirectoryWhenEitherFileIsRetained() async throws {
        let still = try scratch(Data(repeating: 1, count: 32), named: "IMG.HEIC")
        let motion = try scratch(Data(repeating: 2, count: 48), named: "IMG.MOV")
        let pair = try MediaExporter.adoptPair(still: still, motion: motion)
        let exporter = MediaExporter()
        await exporter.purge(excluding: [pair.companion!.url])
        XCTAssertTrue(FileManager.default.fileExists(atPath: pair.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pair.companion!.url.path))
        await exporter.discard(pair)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pair.url.path))
    }

    func testCreateCommitBodyHasLivePhotoInfoAndMaskAndNoField3() throws {
        let photoReceipt = Proto.string(2, "photo-token")
        let videoReceipt = Proto.string(2, "video-token")
        let photoHash = Data(repeating: 1, count: 20)
        let videoHash = Data(repeating: 2, count: 20)
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let body = GPMCClient.livePhotoCreateBody(
            photoReceipt: photoReceipt, videoReceipt: videoReceipt, filename: "IMG.HEIC",
            photoSHA1: photoHash, videoSHA1: videoHash, createdAt: date, modifiedAt: date,
            useQuota: false, saver: false
        )
        let fields = try Proto.fields(body)
        XCTAssertNil(fields[3], "Live Photo create must not send the single-file field 3")
        XCTAssertEqual(fields[5]?.first, GPMCClient.livePhotoResultItemMask)
        let blueprint = try XCTUnwrap(fields[1]?.first)
        let item = try Proto.fields(blueprint)
        XCTAssertEqual(item[2]?.first.flatMap { String(data: $0, encoding: .utf8) }, "IMG.HEIC")
        XCTAssertEqual(item[3]?.first, photoHash)
        XCTAssertEqual(Self.varint(7, in: blueprint), 3)
        XCTAssertEqual(Self.varint(10, in: blueprint), 1)
        let live = try Proto.fields(try XCTUnwrap(item[24]?.first))
        XCTAssertEqual(live[1]?.first, videoReceipt)
        XCTAssertEqual(live[2]?.first, videoHash)
        let device = try XCTUnwrap(fields[2]?.first)
        XCTAssertTrue(String(decoding: device, as: UTF8.self).contains("Pixel XL"))
    }

    func testReconcileCommitBodyHasPhodeoAndNoLivePhotoInfo() throws {
        let videoReceipt = Proto.string(2, "video-token")
        let photoHash = Data(repeating: 3, count: 20)
        let videoHash = Data(repeating: 4, count: 20)
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let body = GPMCClient.livePhotoReconcileBody(
            videoReceipt: videoReceipt, filename: "IMG.MOV",
            photoSHA1: photoHash, videoSHA1: videoHash, createdAt: date, modifiedAt: date,
            useQuota: false, saver: true
        )
        let fields = try Proto.fields(body)
        XCTAssertNil(fields[3])
        let blueprint = try XCTUnwrap(fields[1]?.first)
        let item = try Proto.fields(blueprint)
        XCTAssertNil(item[24])
        XCTAssertEqual(Self.varint(7, in: blueprint), 1)
        XCTAssertEqual(Self.varint(10, in: blueprint), 1)
        let reconcile = try Proto.fields(try XCTUnwrap(item[9]?.first))
        XCTAssertEqual(Self.varint(2, in: try XCTUnwrap(item[9]?.first)), 1)
        XCTAssertEqual(reconcile[3]?.first, photoHash)
        let device = try XCTUnwrap(fields[2]?.first)
        XCTAssertTrue(String(decoding: device, as: UTF8.self).contains("Pixel 2"))
    }

    func testLivePhotoCreateUploadsBothFilesAndCommitsOnce() async throws {
        StubProtocol.handler = Self.photosHandler()
        let still = try scratch(Data((0..<64).map { UInt8($0) }), named: "IMG.HEIC")
        let motion = try scratch(Data((0..<96).map { UInt8($0 &+ 3) }), named: "IMG.MOV")
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        let worker = PhotosUploader(exporter: MediaExporter()) { client }.worker()
        let checkpoint = UploadCheckpoint(
            filePath: still.path, filename: "IMG.HEIC",
            modified: Date(timeIntervalSince1970: 1_600_000_000),
            byteCount: 64, temporary: false, prepared: nil,
            companionFilePath: motion.path, companionFilename: "IMG.MOV", companionByteCount: 96
        )
        let outcome = try await worker(UUID(), .file(still), checkpoint, UploadOptions()) { _ in }
        XCTAssertEqual(outcome, .uploaded(mediaKey: "MEDIAKEY"))
        XCTAssertEqual(StubProtocol.seen.filter { $0.httpMethod == "PUT" }.count, 2)
        XCTAssertEqual(StubProtocol.seen.filter { $0.stubPath.hasSuffix("/16538846908252377752") }.count, 1)
        let commit = try XCTUnwrap(StubProtocol.seen.first { $0.stubPath.hasSuffix("/16538846908252377752") })
        let fields = try Proto.fields(Self.body(of: commit))
        XCTAssertNotNil(try Proto.fields(try XCTUnwrap(fields[1]?.first))[24])
        XCTAssertNil(fields[3])
    }

    func testStillAlreadyRemoteSkipsWhenUpdateExistingIsOff() async throws {
        StubProtocol.handler = Self.photosHandler(existingKey: "OLD")
        let still = try scratch(Data(repeating: 9, count: 32), named: "IMG.HEIC")
        let motion = try scratch(Data(repeating: 8, count: 32), named: "IMG.MOV")
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        let worker = PhotosUploader(exporter: MediaExporter()) { client }.worker()
        var options = UploadOptions()
        options.updateExistingPhotosToLive = false
        let checkpoint = UploadCheckpoint(
            filePath: still.path, filename: "IMG.HEIC", modified: Date(),
            byteCount: 32, temporary: false, prepared: nil,
            companionFilePath: motion.path, companionFilename: "IMG.MOV", companionByteCount: 32
        )
        let outcome = try await worker(UUID(), .file(still), checkpoint, options) { _ in }
        XCTAssertEqual(outcome, .alreadyBackedUp(mediaKey: "OLD"))
        XCTAssertFalse(StubProtocol.seen.contains { $0.httpMethod == "PUT" })
    }

    func testStillAlreadyRemoteReconcilesWhenUpdateExistingIsOn() async throws {
        var hashLookups = 0
        let handler = Self.photosHandler()
        StubProtocol.handler = { request in
            if request.stubPath.hasSuffix("/5084965799730810217") {
                hashLookups += 1
                if hashLookups == 1 {
                    return .ok(Proto.bytes(1, Proto.bytes(2, Proto.bytes(2, Proto.string(1, "STILL")))))
                }
                return .ok(Data())
            }
            return handler(request)
        }
        let still = try scratch(Data(repeating: 5, count: 32), named: "IMG.HEIC")
        let motion = try scratch(Data(repeating: 6, count: 40), named: "IMG.MOV")
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        let worker = PhotosUploader(exporter: MediaExporter()) { client }.worker()
        var options = UploadOptions()
        options.updateExistingPhotosToLive = true
        let checkpoint = UploadCheckpoint(
            filePath: still.path, filename: "IMG.HEIC", modified: Date(),
            byteCount: 32, temporary: false, prepared: nil,
            companionFilePath: motion.path, companionFilename: "IMG.MOV", companionByteCount: 40
        )
        let outcome = try await worker(UUID(), .file(still), checkpoint, options) { _ in }
        XCTAssertEqual(outcome, .uploaded(mediaKey: "MEDIAKEY"))
        XCTAssertEqual(StubProtocol.seen.filter { $0.httpMethod == "PUT" }.count, 1)
        let commit = try XCTUnwrap(StubProtocol.seen.first { $0.stubPath.hasSuffix("/16538846908252377752") })
        let blueprint = try Proto.fields(try XCTUnwrap(try Proto.fields(Self.body(of: commit))[1]?.first))
        XCTAssertNotNil(blueprint[9])
        XCTAssertNil(blueprint[24])
    }

    func testRemoteVideoAloneIsSkippedRatherThanPaired() async throws {
        var hashLookups = 0
        let handler = Self.photosHandler()
        StubProtocol.handler = { request in
            if request.stubPath.hasSuffix("/5084965799730810217") {
                hashLookups += 1
                if hashLookups == 2 {
                    return .ok(Proto.bytes(1, Proto.bytes(2, Proto.bytes(2, Proto.string(1, "MOV")))))
                }
                return .ok(Data())
            }
            return handler(request)
        }
        let still = try scratch(Data(repeating: 1, count: 16), named: "IMG.HEIC")
        let motion = try scratch(Data(repeating: 2, count: 16), named: "IMG.MOV")
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        let worker = PhotosUploader(exporter: MediaExporter()) { client }.worker()
        let checkpoint = UploadCheckpoint(
            filePath: still.path, filename: "IMG.HEIC", modified: Date(),
            byteCount: 16, temporary: false, prepared: nil,
            companionFilePath: motion.path, companionFilename: "IMG.MOV", companionByteCount: 16
        )
        let outcome = try await worker(UUID(), .file(still), checkpoint, UploadOptions()) { _ in }
        XCTAssertEqual(outcome, .skipped)
        XCTAssertFalse(StubProtocol.seen.contains { $0.httpMethod == "PUT" })
    }

    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    private static let credential = TokenExchange.googlePhotosCredentialBody(
        androidId: "0123456789abcdef", email: "person@gmail.com", masterToken: "aas_et/master+token")
    private static let farFuture = String(Int(Date().addingTimeInterval(3600).timeIntervalSince1970))

    private static func photosHandler(existingKey: String? = nil,
                                      committedKey: String = "MEDIAKEY") -> (URLRequest) -> StubProtocol.Reply {
        { request in
            let path = request.stubPath
            if path == "/auth" { return .text("Auth=ya29.token\nExpiry=\(farFuture)\n") }
            if path.hasSuffix("/5084965799730810217") {
                guard let existingKey else { return .ok(Data()) }
                return .ok(Proto.bytes(1, Proto.bytes(2, Proto.bytes(2, Proto.string(1, existingKey)))))
            }
            if path.hasSuffix("/16538846908252377752") {
                return .ok(Proto.bytes(1, Proto.bytes(3, Proto.string(1, committedKey))))
            }
            if request.httpMethod == "PUT" { return .ok(Proto.int(1, 1) + Proto.bytes(2, Data("receipt".utf8))) }
            return .ok(Data(), headers: ["X-GUploader-UploadID": "upload-123"])
        }
    }

    private func scratch(_ contents: Data, named name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    static func body(of request: URLRequest) -> Data {
        GPMCClientTests.body(of: request)
    }

    private static func varint(_ field: Int, in data: Data) -> UInt64? {
        let bytes = [UInt8](data)
        var index = 0
        func read() -> UInt64? {
            var value: UInt64 = 0
            var shift = 0
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                value |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return value }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while index < bytes.count {
            guard let tag = read() else { return nil }
            let number = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                guard let value = read() else { return nil }
                if number == field { return value }
            case 1: index += 8
            case 5: index += 4
            case 2:
                guard let length = read(), index + Int(length) <= bytes.count else { return nil }
                index += Int(length)
            default: return nil
            }
        }
        return nil
    }
}
