import CoreGraphics
import CoreLocation
import ImageIO
import XCTest

@testable import LifeJustHappening

/// Scripted uploader: each batch call pops one step. A step either throws for the whole
/// batch or rejects the named files.
private actor FakeUploader: PhotoUploading {
    enum Step {
        case fail(Error)
        case reject(Set<String>)
    }

    var script: [Step]
    private(set) var uploadedNames: [String] = []
    private(set) var batchSizes: [Int] = []

    init(script: [Step]) {
        self.script = script
    }

    func upload(_ items: [UploadItem]) async throws -> [UploadItemResult] {
        batchSizes.append(items.count)
        let step = script.isEmpty ? nil : script.removeFirst()
        if case .fail(let error) = step { throw error }
        let rejected: Set<String> = { if case .reject(let names) = step { return names }; return [] }()
        return items.map { item in
            if rejected.contains(item.fileName) { return .rejected("bad image") }
            uploadedNames.append(item.fileName)
            return .uploaded(mediaItemID: "m-\(item.fileName)")
        }
    }
}

final class UploadQueueTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ljh-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testUploadsOldestFirstAndDeletesLocalCopies() async throws {
        let uploader = FakeUploader(script: [])
        let queue = UploadQueue(root: root, uploader: uploader)
        try await queue.enqueue(Data([1]), fileName: "ljh_2026-01-02_10-00-00.jpg")
        try await queue.enqueue(Data([2]), fileName: "ljh_2026-01-01_10-00-00.jpg")

        let report = await queue.drain()
        XCTAssertEqual(report.uploaded, 2)
        XCTAssertEqual(report.pending, 0)
        let names = await uploader.uploadedNames
        XCTAssertEqual(names, ["ljh_2026-01-01_10-00-00.jpg", "ljh_2026-01-02_10-00-00.jpg"])
    }

    func testTransientFailureStopsAndKeepsEverything() async throws {
        let uploader = FakeUploader(script: [.fail(UploadError.transient("offline"))])
        let queue = UploadQueue(root: root, uploader: uploader)
        try await queue.enqueue(Data([1]), fileName: "a.jpg")
        try await queue.enqueue(Data([2]), fileName: "b.jpg")

        let report = await queue.drain()
        XCTAssertEqual(report.uploaded, 0)
        XCTAssertEqual(report.pending, 2)
        XCTAssertEqual(report.failure, "offline")

        let retry = await queue.drain()
        XCTAssertEqual(retry.uploaded, 2)
        XCTAssertEqual(retry.pending, 0)
    }

    func testRejectedPhotoIsSetAsideAndQueueContinues() async throws {
        let uploader = FakeUploader(script: [.reject(["a.jpg"])])
        let queue = UploadQueue(root: root, uploader: uploader)
        try await queue.enqueue(Data([1]), fileName: "a.jpg")
        try await queue.enqueue(Data([2]), fileName: "b.jpg")

        let report = await queue.drain()
        XCTAssertEqual(report.uploaded, 1)
        XCTAssertEqual(report.rejected, 1)
        XCTAssertEqual(report.pending, 0)
    }

    func testDrainBatches() async throws {
        let uploader = FakeUploader(script: [])
        let queue = UploadQueue(root: root, uploader: uploader)
        for index in 0..<23 {
            try await queue.enqueue(Data([UInt8(index)]), fileName: String(format: "p%02d.jpg", index))
        }
        let report = await queue.drain(batchSize: 10)
        XCTAssertEqual(report.uploaded, 23)
        let sizes = await uploader.batchSizes
        XCTAssertEqual(sizes, [10, 10, 3])
    }

    func testSameSecondCapturesDontOverwrite() async throws {
        let queue = UploadQueue(root: root, uploader: FakeUploader(script: []))
        try await queue.enqueue(Data([1]), fileName: "a.jpg")
        try await queue.enqueue(Data([2]), fileName: "a.jpg")
        let counts = await queue.counts()
        XCTAssertEqual(counts.pending, 2)
    }
}

final class GoogleProtocolTests: XCTestCase {
    func testParsesDownloadedDesktopClientJSON() throws {
        let json = #"{"installed":{"client_id":"abc.apps.googleusercontent.com","project_id":"x","client_secret":"shh","redirect_uris":["http://localhost"]}}"#
        let client = try OAuthClient.parse(downloadedJSON: Data(json.utf8))
        XCTAssertEqual(client, OAuthClient(clientID: "abc.apps.googleusercontent.com", clientSecret: "shh"))
    }

    func testRejectsWebClientJSON() {
        let json = #"{"web":{"client_id":"abc"}}"#
        XCTAssertThrowsError(try OAuthClient.parse(downloadedJSON: Data(json.utf8)))
    }

    func testAuthorizationURLCarriesPKCEAndOfflineAccess() throws {
        let pkce = GoogleOAuth.PKCE.make()
        XCTAssertGreaterThanOrEqual(pkce.verifier.count, 43)
        let url = GoogleOAuth.authorizationURL(
            client: OAuthClient(clientID: "id", clientSecret: "s"),
            redirectURI: "http://127.0.0.1:5555",
            pkce: pkce,
            state: "st"
        )
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["code_challenge"], pkce.challenge)
        XCTAssertEqual(items["access_type"], "offline")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:5555")
        XCTAssertTrue(items["scope"]!.contains("photoslibrary.appendonly"))
    }

    func testRefreshRequestIsFormEncoded() throws {
        let request = GoogleOAuth.refreshRequest(client: OAuthClient(clientID: "id", clientSecret: "a+b/c"), refreshToken: "1//tok")
        let body = String(data: request.httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("client_secret=a%2Bb%2Fc"))
        XCTAssertTrue(body.contains("refresh_token=1%2F%2Ftok"))
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
    }

    func testEmailFromIDToken() {
        let payload = Data(#"{"email":"me@example.com"}"#.utf8).base64URLEncoded()
        XCTAssertEqual(GoogleOAuth.email(fromIDToken: "h.\(payload).sig"), "me@example.com")
        XCTAssertNil(GoogleOAuth.email(fromIDToken: "garbage"))
    }

    func testLoopbackParsesRedirect() {
        let request = "GET /?state=xyz&code=4%2F0Ab&scope=email HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let params = LoopbackReceiver.queryParameters(fromRequest: Data(request.utf8))
        XCTAssertEqual(params?["code"], "4/0Ab")
        XCTAssertEqual(params?["state"], "xyz")
    }

    func testBatchCreateResultsMapPerItem() throws {
        let body = #"{"newMediaItemResults":[{"uploadToken":"t2","status":{"code":3,"message":"Failed: There was an error while trying to create this media item."}},{"uploadToken":"t1","status":{"message":"Success"},"mediaItem":{"id":"m"}}]}"#
        let results = try GooglePhotosUploader.batchCreateResults(Data(body.utf8), uploadTokens: ["t1", "t2", "t3"])
        XCTAssertEqual(results[0], .uploaded(mediaItemID: "m"))
        guard case .rejected = results[1] else { return XCTFail("t2 should be rejected") }
        XCTAssertEqual(results[2], .rejected("missing from Google's response"))
    }

    func testRecentMediaKeepsNewestByCaptureDate() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let existing = [RecentMedia(id: "new-capture", date: base + 1000)]
        let legacy = (0..<6).map { RecentMedia(id: "old\($0)", date: base - Double($0) * 100) }
        let merged = RecentMedia.merge(existing, with: legacy + [RecentMedia(id: "new-capture", date: base + 1000)], limit: 4)
        XCTAssertEqual(merged.map(\.id), ["new-capture", "old0", "old1", "old2"])
        XCTAssertEqual(
            RecentMedia.date(fromFileName: "ljh_2026-09-27_16-54-41-1.jpg", timeZone: TimeZone(identifier: "UTC")!),
            ISO8601DateFormatter().date(from: "2026-09-27T16:54:41Z")
        )
        XCTAssertNil(RecentMedia.date(fromFileName: "Moment 01-01-2025 at 02-33.jpg"))
    }

    func testBatchCreateAlbumProblemIsAlbumGone() {
        let body = #"{"newMediaItemResults":[{"uploadToken":"t","status":{"code":3,"message":"Invalid album id"}}]}"#
        XCTAssertThrowsError(try GooglePhotosUploader.batchCreateResults(Data(body.utf8), uploadTokens: ["t"])) { error in
            guard case UploadError.albumGone = error else { return XCTFail("expected albumGone, got \(error)") }
        }
    }

    func testScopesCanFindOurAlbumButNotYourLibrary() {
        XCTAssertTrue(GoogleOAuth.scopes.contains("https://www.googleapis.com/auth/photoslibrary.readonly.appcreateddata"))
        XCTAssertFalse(GoogleOAuth.scopes.contains("https://www.googleapis.com/auth/photoslibrary.readonly"))
    }
}

final class PhotoEncoderTests: XCTestCase {
    private func solidImage(gray: CGFloat, size: Int = 64) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    private func properties(of data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    func testJPEGCarriesTimePlaceAndCamera() throws {
        let zurich = TimeZone(identifier: "Europe/Zurich")!
        let date = ISO8601DateFormatter().date(from: "2026-07-01T12:34:56Z")!
        let place = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 47.3769, longitude: -8.5417),
            altitude: 408, horizontalAccuracy: 35, verticalAccuracy: 10, timestamp: date
        )
        let metadata = PhotoMetadata(capturedAt: date, timeZone: zurich, location: place, cameraName: "PC-LM1E Camera")
        let props = try properties(of: XCTUnwrap(PhotoEncoder.jpeg(solidImage(gray: 0.5), metadata: metadata)))

        let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2026:07:01 14:34:56")
        XCTAssertEqual(exif[kCGImagePropertyExifOffsetTimeOriginal] as? String, "+02:00")

        let gps = try XCTUnwrap(props[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        XCTAssertEqual(try XCTUnwrap(gps[kCGImagePropertyGPSLatitude] as? Double), 47.3769, accuracy: 0.0001)
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitudeRef] as? String, "N")
        XCTAssertEqual(try XCTUnwrap(gps[kCGImagePropertyGPSLongitude] as? Double), 8.5417, accuracy: 0.0001)
        XCTAssertEqual(gps[kCGImagePropertyGPSLongitudeRef] as? String, "W")
        XCTAssertEqual(gps[kCGImagePropertyGPSDateStamp] as? String, "2026:07:01")

        let tiff = try XCTUnwrap(props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel] as? String, "PC-LM1E Camera")
    }

    func testNoLocationMeansNoGPSBlock() throws {
        let props = try properties(of: XCTUnwrap(PhotoEncoder.jpeg(solidImage(gray: 0.5), metadata: PhotoMetadata(capturedAt: Date()))))
        XCTAssertNil(props[kCGImagePropertyGPSDictionary])
    }

    func testStampAddsDateWithoutReencoding() throws {
        let original = try XCTUnwrap(PhotoEncoder.jpeg(solidImage(gray: 0.3, size: 256), metadata: PhotoMetadata(capturedAt: Date(timeIntervalSince1970: 0)), quality: 0.5))
        let date = ISO8601DateFormatter().date(from: "2024-03-10T08:00:00Z")!
        let stamped = try XCTUnwrap(PhotoEncoder.stamp(jpeg: original, metadata: PhotoMetadata(capturedAt: date, timeZone: TimeZone(identifier: "UTC")!)))
        let exif = try XCTUnwrap(properties(of: stamped)[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2024:03:10 08:00:00")
        // Lossless: decoded pixels are byte-identical to the original.
        func pixels(_ data: Data) throws -> Data {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            return try XCTUnwrap(image.dataProvider?.data) as Data
        }
        XCTAssertEqual(try pixels(stamped), try pixels(original))
    }

    func testBlankDetection() {
        XCTAssertTrue(PhotoEncoder.isBlank(solidImage(gray: 0)))
        XCTAssertFalse(PhotoEncoder.isBlank(solidImage(gray: 0.08)), "a dim room is still a photo")
        XCTAssertFalse(PhotoEncoder.isBlank(solidImage(gray: 0.1)), "screen-lit night shot")
    }

    func testThumbnailIsSmall() throws {
        let thumb = try XCTUnwrap(PhotoEncoder.thumbnail(solidImage(gray: 0.5, size: 1920), maxPixelSize: 320))
        XCTAssertEqual(max(thumb.width, thumb.height), 320)
    }

    func testFileNameIsSortable() {
        let date = ISO8601DateFormatter().date(from: "2026-07-01T08:05:09Z")!
        XCTAssertEqual(PhotoEncoder.fileName(for: date, timeZone: TimeZone(identifier: "UTC")!), "ljh_2026-07-01_08-05-09.jpg")
    }
}

final class LegacyImporterTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ljh-legacy-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("old"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testNetworkBlipIsRetriedNotAbandoned() async throws {
        let folder = root.appendingPathComponent("old")
        let jpeg = try XCTUnwrap(PhotoEncoder.jpeg(
            CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!,
            metadata: PhotoMetadata(capturedAt: Date())
        ))
        for day in 1...3 {
            try jpeg.write(to: folder.appendingPathComponent(String(format: "Moment %02d-02-2025 at 10-00.jpg", day)))
        }
        let blip = FakeUploader(script: [.fail(UploadError.transient("network connection lost")), .fail(UploadError.transient("HTTP 503"))])
        let importer = LegacyImporter(folder: folder, ledgerURL: root.appendingPathComponent("l.json"), uploader: blip)
        await importer.setRetryDelays([0, 0, 0])
        let result = await importer.run(batchSize: 50) { _ in }
        XCTAssertEqual(result.done, 3)
        XCTAssertNil(result.failure)
    }

    func testParsesOldFileNames() {
        let zurich = TimeZone(identifier: "Europe/Zurich")!
        let date = LegacyImporter.captureDate(of: URL(fileURLWithPath: "/x/Moment 01-01-2025 at 02-33.jpg"), timeZone: zurich)
        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2025-01-01T01:33:00Z"))
    }

    func testCreationTimeRefinesTheMinuteOnlyWhenItFits() {
        let named = ISO8601DateFormatter().date(from: "2025-01-01T01:33:00Z")!
        XCTAssertEqual(LegacyImporter.refine(named: named, created: named + 29), named + 29, "written 29s later: exact second")
        XCTAssertEqual(LegacyImporter.refine(named: named, created: named + 11 * 86400), named, "copied days later: keep the filename")
        XCTAssertEqual(LegacyImporter.refine(named: named, created: named - 60), named, "created before the shot can't be right")
        XCTAssertEqual(LegacyImporter.refine(named: named, created: nil), named)
    }

    func testImportIsResumableAndNeverTouchesOriginals() async throws {
        let folder = root.appendingPathComponent("old")
        let jpeg = try XCTUnwrap(PhotoEncoder.jpeg(
            CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!,
            metadata: PhotoMetadata(capturedAt: Date())
        ))
        for day in 1...5 {
            try jpeg.write(to: folder.appendingPathComponent(String(format: "Moment %02d-01-2025 at 10-00.jpg", day)))
        }
        let ledger = root.appendingPathComponent("ledger.json")

        let limited = FakeUploader(script: [.reject([]), .fail(UploadError.rateLimited("quota"))])
        let first = await LegacyImporter(folder: folder, ledgerURL: ledger, uploader: limited).run(batchSize: 2) { _ in }
        XCTAssertEqual(first.done, 2)
        XCTAssertTrue(first.isRateLimited)
        XCTAssertNotNil(first.failure)

        let steady = FakeUploader(script: [])
        let second = await LegacyImporter(folder: folder, ledgerURL: ledger, uploader: steady).run(batchSize: 2) { _ in }
        XCTAssertEqual(second.done, 5)
        XCTAssertEqual(second.remaining, 0)
        let names = await steady.uploadedNames
        XCTAssertEqual(names.count, 3, "the first two aren't uploaded twice")
        XCTAssertEqual(names.first, PhotoEncoder.fileName(for: LegacyImporter.captureDate(of: folder.appendingPathComponent("Moment 03-01-2025 at 10-00.jpg"))!))

        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(left.count, 5, "originals stay put")
    }
}

final class CredentialStoreTests: XCTestCase {
    func testRoundTripIsOwnerOnlyAndEmptyMeansNoFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ljh-cred-\(UUID().uuidString)/google-credentials.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = CredentialStore(fileURL: url)
        XCTAssertEqual(store.load(), CredentialStore.Contents())

        store.update {
            $0.client = OAuthClient(clientID: "id", clientSecret: "s")
            $0.refreshToken = "1//tok"
        }
        XCTAssertEqual(store.load().refreshToken, "1//tok")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        store.update { $0 = CredentialStore.Contents() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
