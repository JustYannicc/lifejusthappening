import Foundation

struct GooglePhotosAlbum: Codable, Equatable {
    let id: String
    let title: String
    let productURL: URL?
}

enum UploadError: LocalizedError {
    /// Worth retrying later: offline, 5xx, rate limits, auth hiccups, config problems.
    case transient(String)
    /// Google's quota or rate limit. Back off for a while, not seconds.
    case rateLimited(String)
    /// Google accepted the bytes but refused the photo. Retrying won't help.
    case rejected(String)
    case albumGone

    var errorDescription: String? {
        switch self {
        case .transient(let reason): return reason
        case .rateLimited(let reason): return "Google's upload limit: \(reason)"
        case .rejected(let reason): return "Google Photos rejected the photo: \(reason)"
        case .albumGone: return "The Google Photos album disappeared"
        }
    }
}

struct UploadItem {
    let data: Data
    let fileName: String
}

enum UploadItemResult: Equatable {
    case uploaded(mediaItemID: String?)
    case rejected(String)
}

protocol PhotoUploading: Sendable {
    /// Uploads up to `maxBatch` items into the album. Throws for batch-wide problems;
    /// per-photo refusals come back as `.rejected`.
    func upload(_ items: [UploadItem]) async throws -> [UploadItemResult]
}

/// Uploads into one app-created album. Since April 2025 the Library API only lets apps add
/// to albums they created, which is exactly what we want: one album with every photo.
struct GooglePhotosUploader: PhotoUploading {
    static let albumTitle = "lifejusthappening"
    static let maxBatch = 50

    let tokens: @Sendable (_ forceRefresh: Bool) async throws -> String
    let loadAlbum: @Sendable () async -> GooglePhotosAlbum?
    let saveAlbum: @Sendable (GooglePhotosAlbum?) async -> Void
    /// Told about every photo Google accepted: (media item id, upload file name).
    var didCreate: @Sendable ([(id: String, fileName: String)]) async -> Void = { _ in }
    var session: URLSession = .shared

    private static let api = URL(string: "https://photoslibrary.googleapis.com/v1/")!

    func upload(_ items: [UploadItem]) async throws -> [UploadItemResult] {
        precondition(items.count <= Self.maxBatch)
        guard !items.isEmpty else { return [] }
        var tokens: [(token: String, fileName: String)] = []
        for item in items {
            tokens.append((try await uploadBytes(item.data, fileName: item.fileName), item.fileName))
        }
        let results: [UploadItemResult]
        do {
            results = try await createMediaItems(tokens, albumID: ensureAlbum().id)
        } catch UploadError.albumGone {
            await saveAlbum(nil)
            results = try await createMediaItems(tokens, albumID: ensureAlbum().id)
        }
        let created = zip(items, results).compactMap { item, result -> (id: String, fileName: String)? in
            if case .uploaded(let id?) = result { return (id, item.fileName) }
            return nil
        }
        if !created.isEmpty { await didCreate(created) }
        return results
    }

    /// Reuses our album if it exists (after a reinstall or on a second Mac), otherwise creates it.
    func ensureAlbum() async throws -> GooglePhotosAlbum {
        if let album = await loadAlbum() { return album }
        if let existing = try await findExistingAlbum() {
            await saveAlbum(existing)
            return existing
        }
        var request = URLRequest(url: Self.api.appendingPathComponent("albums"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["album": ["title": Self.albumTitle]])
        guard let album = Self.album(from: try JSONSerialization.jsonObject(with: try await sendMapped(request))) else {
            throw UploadError.transient("Album creation returned garbage")
        }
        await saveAlbum(album)
        return album
    }

    struct RemotePhoto: Equatable {
        let id: String
        let baseURL: URL
        let createdAt: Date?
    }

    /// Newest app-created photos from the last `days` days. Filtered search walks your whole
    /// library and returns sparse pages, so only use it on a short window.
    func recentPhotos(days: Int = 30, limit: Int) async throws -> [RemotePhoto] {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.dateComponents([.year, .month, .day], from: Date().addingTimeInterval(-Double(days) * 86400))
        let end = calendar.dateComponents([.year, .month, .day], from: Date().addingTimeInterval(86400))
        var photos: [RemotePhoto] = []
        var pageToken: String?
        for _ in 0..<5 {
            var body: [String: Any] = [
                "pageSize": 100,
                "filters": ["dateFilter": ["ranges": [[
                    "startDate": ["year": start.year!, "month": start.month!, "day": start.day!],
                    "endDate": ["year": end.year!, "month": end.month!, "day": end.day!],
                ]]]],
                "orderBy": "MediaMetadata.creation_time desc",
            ]
            if let pageToken { body["pageToken"] = pageToken }
            var request = URLRequest(url: Self.api.appendingPathComponent("mediaItems:search"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let json = try JSONSerialization.jsonObject(with: try await sendMapped(request)) as? [String: Any]
            photos += (json?["mediaItems"] as? [[String: Any]] ?? []).compactMap(Self.remotePhoto(from:))
            pageToken = json?["nextPageToken"] as? String
            if photos.count >= limit || pageToken == nil { break }
        }
        return Array(photos.prefix(limit))
    }

    /// Fresh base URLs for known media items, in the order given.
    func photos(ids: [String]) async throws -> [RemotePhoto] {
        guard !ids.isEmpty else { return [] }
        var components = URLComponents(url: Self.api.appendingPathComponent("mediaItems:batchGet"), resolvingAgainstBaseURL: false)!
        components.queryItems = ids.map { URLQueryItem(name: "mediaItemIds", value: $0) }
        let json = try JSONSerialization.jsonObject(with: try await sendMapped(URLRequest(url: components.url!))) as? [String: Any]
        let found = (json?["mediaItemResults"] as? [[String: Any]] ?? []).compactMap { ($0["mediaItem"] as? [String: Any]).flatMap(Self.remotePhoto(from:)) }
        return ids.compactMap { id in found.first { $0.id == id } }
    }

    private static func remotePhoto(from item: [String: Any]) -> RemotePhoto? {
        guard let id = item["id"] as? String,
              let base = (item["baseUrl"] as? String).flatMap(URL.init(string:)) else { return nil }
        let created = ((item["mediaMetadata"] as? [String: Any])?["creationTime"] as? String)
            .flatMap(ISO8601DateFormatter().date(from:))
        return RemotePhoto(id: id, baseURL: base, createdAt: created)
    }

    /// How many photos are in our album, straight from Google.
    func albumCount() async throws -> Int? {
        let album = try await ensureAlbum()
        let json = try JSONSerialization.jsonObject(with: try await sendMapped(URLRequest(url: Self.api.appendingPathComponent("albums/\(album.id)")))) as? [String: Any]
        return (json?["mediaItemsCount"] as? String).flatMap(Int.init)
    }

    /// Diagnostics: what Google actually parsed for the newest items in our album.
    func albumItems(limit: Int = 10) async throws -> [[String: Any]] {
        let album = try await ensureAlbum()
        var request = URLRequest(url: Self.api.appendingPathComponent("mediaItems:search"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["albumId": album.id, "pageSize": min(100, limit)])
        let json = try JSONSerialization.jsonObject(with: try await sendMapped(request)) as? [String: Any]
        return json?["mediaItems"] as? [[String: Any]] ?? []
    }

    private func findExistingAlbum() async throws -> GooglePhotosAlbum? {
        var pageToken: String?
        repeat {
            var components = URLComponents(url: Self.api.appendingPathComponent("albums"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "pageSize", value: "50"),
                URLQueryItem(name: "excludeNonAppCreatedData", value: "true"),
            ] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let json = try JSONSerialization.jsonObject(with: try await sendMapped(URLRequest(url: components.url!))) as? [String: Any]
            let albums = (json?["albums"] as? [[String: Any]] ?? []).compactMap(Self.album(from:))
            if let match = albums.first(where: { $0.title == Self.albumTitle }) { return match }
            pageToken = json?["nextPageToken"] as? String
        } while pageToken != nil
        return nil
    }

    private static func album(from json: Any?) -> GooglePhotosAlbum? {
        guard let json = json as? [String: Any], let id = json["id"] as? String else { return nil }
        return GooglePhotosAlbum(
            id: id,
            title: json["title"] as? String ?? albumTitle,
            productURL: (json["productUrl"] as? String).flatMap(URL.init(string:))
        )
    }

    private func uploadBytes(_ data: Data, fileName: String) async throws -> String {
        var request = URLRequest(url: Self.api.appendingPathComponent("uploads"))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("image/jpeg", forHTTPHeaderField: "X-Goog-Upload-Content-Type")
        request.setValue("raw", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        request.setValue(fileName, forHTTPHeaderField: "X-Goog-Upload-File-Name")
        request.httpBody = data
        let token = String(decoding: try await sendMapped(request), as: UTF8.self)
        guard !token.isEmpty else { throw UploadError.transient("Upload returned no token") }
        return token
    }

    private func createMediaItems(_ tokens: [(token: String, fileName: String)], albumID: String) async throws -> [UploadItemResult] {
        var request = URLRequest(url: Self.api.appendingPathComponent("mediaItems:batchCreate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "albumId": albumID,
            "newMediaItems": tokens.map { ["simpleMediaItem": ["uploadToken": $0.token, "fileName": $0.fileName]] },
        ])
        let data: Data
        do {
            data = try await send(request)
        } catch let HTTPFailure.status(code, body) {
            if body.localizedCaseInsensitiveContains("album") { throw UploadError.albumGone }
            throw UploadError.transient("batchCreate failed with HTTP \(code): \(body.prefix(200))")
        }
        return try Self.batchCreateResults(data, uploadTokens: tokens.map(\.token))
    }

    /// Maps Google's per-item statuses back onto our items, in order.
    static func batchCreateResults(_ data: Data, uploadTokens: [String]) throws -> [UploadItemResult] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["newMediaItemResults"] as? [[String: Any]] else {
            throw UploadError.transient("batchCreate returned no results")
        }
        var byToken: [String: UploadItemResult] = [:]
        for (index, result) in results.enumerated() {
            let status = result["status"] as? [String: Any]
            let code = status?["code"] as? Int ?? 0
            let message = status?["message"] as? String ?? "code \(code)"
            if code != 0, message.localizedCaseInsensitiveContains("album") { throw UploadError.albumGone }
            let token = result["uploadToken"] as? String ?? (index < uploadTokens.count ? uploadTokens[index] : "")
            let mediaItemID = (result["mediaItem"] as? [String: Any])?["id"] as? String
            byToken[token] = code == 0 ? .uploaded(mediaItemID: mediaItemID) : .rejected(message)
        }
        return uploadTokens.map { byToken[$0] ?? .rejected("missing from Google's response") }
    }

    private enum HTTPFailure: Error {
        case status(Int, String)
    }

    private func sendMapped(_ request: URLRequest) async throws -> Data {
        do {
            return try await send(request)
        } catch let HTTPFailure.status(code, body) {
            Log.upload.error("HTTP \(code, privacy: .public): \(body.prefix(300), privacy: .public)")
            throw UploadError.transient("Google Photos said HTTP \(code): \(body.prefix(200))")
        }
    }

    /// Authorized request with one forced token refresh on 401.
    private func send(_ request: URLRequest, retryingAuth: Bool = true) async throws -> Data {
        var request = request
        let token: String
        do {
            token = try await tokens(!retryingAuth)
        } catch {
            throw UploadError.transient(error.localizedDescription)
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UploadError.transient(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            return data
        case 401 where retryingAuth:
            return try await send(request, retryingAuth: false)
        case 429:
            throw UploadError.rateLimited(Self.message(from: data) ?? "too many requests")
        default:
            let body = String(decoding: data, as: UTF8.self)
            if status == 400 || status == 404 { throw HTTPFailure.status(status, body) }
            throw UploadError.transient("Google Photos said HTTP \(status): \(Self.message(from: data) ?? String(body.prefix(200)))")
        }
    }

    private static func message(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}
