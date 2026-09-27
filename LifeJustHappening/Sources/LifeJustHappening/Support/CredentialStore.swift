import Foundation

/// Google OAuth client + refresh token in an owner-only (0600) file.
///
/// Why not the Keychain: builds signed with a self-signed certificate have no Team ID, so the
/// Keychain ties access to the binary's hash and asks for your password after every rebuild.
/// Proper Keychain sharing needs a paid Developer ID. For one refresh token that can only
/// append photos to one album, a private file (like gcloud and gh use) is the sane trade.
struct CredentialStore {
    struct Contents: Codable, Equatable {
        var client: OAuthClient?
        var refreshToken: String?
        var email: String?
    }

    let fileURL: URL

    func load() -> Contents {
        guard let data = try? Data(contentsOf: fileURL) else { return Contents() }
        return (try? JSONDecoder().decode(Contents.self, from: data)) ?? Contents()
    }

    func update(_ change: (inout Contents) -> Void) {
        var contents = load()
        change(&contents)
        save(contents)
    }

    private func save(_ contents: Contents) {
        let manager = FileManager.default
        try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard contents != Contents() else {
            try? manager.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder().encode(contents) else { return }
        // Create with 0600 before writing so the secret is never briefly world-readable.
        if !manager.fileExists(atPath: fileURL.path) {
            manager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? data.write(to: fileURL, options: .atomic)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
