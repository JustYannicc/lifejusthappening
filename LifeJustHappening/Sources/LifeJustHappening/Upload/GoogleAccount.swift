import AppKit
import Foundation

/// Owns the Google sign-in state and hands out fresh access tokens.
@MainActor
final class GoogleAccount: ObservableObject {
    enum State: Equatable {
        case needsClient
        case signedOut
        case signingIn
        case signedIn(email: String?)
    }

    @Published private(set) var state: State = .needsClient
    @Published private(set) var lastError: String?

    private let store: CredentialStore
    private let session: URLSession
    private var accessToken: (value: String, expiresAt: Date)?
    private var refreshTask: Task<String, Error>?
    private var receiver: LoopbackReceiver?

    init(store: CredentialStore, legacyKeychain: Keychain? = nil, session: URLSession = .shared) {
        self.store = store
        self.session = session
        if let legacyKeychain { migrate(from: legacyKeychain) }
        recomputeState()
    }

    /// One-time move out of the Keychain used by earlier builds. This is the last Keychain
    /// prompt you'll see; afterwards the items are deleted.
    private func migrate(from keychain: Keychain) {
        guard store.load().refreshToken == nil,
              let tokenData = keychain.data(for: "google-refresh-token") else { return }
        let client = keychain.data(for: "google-oauth-client").flatMap { try? JSONDecoder().decode(OAuthClient.self, from: $0) }
        store.update {
            $0.client = $0.client ?? client
            $0.refreshToken = String(data: tokenData, encoding: .utf8)
            $0.email = UserDefaults.standard.string(forKey: "googleAccountEmail")
        }
        keychain.set(nil as Data?, for: "google-refresh-token")
        keychain.set(nil as Data?, for: "google-oauth-client")
        UserDefaults.standard.removeObject(forKey: "googleAccountEmail")
    }

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    /// Picks up a client JSON dropped into the support folder (e.g. by a setup script) and
    /// moves it into the private credentials file.
    func importDroppedClient(in directory: URL) {
        let file = directory.appendingPathComponent("google-oauth-client.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        importClient(from: file)
        if client != nil { try? FileManager.default.removeItem(at: file) }
    }

    func importClient(from url: URL) {
        do {
            let client = try OAuthClient.parse(downloadedJSON: Data(contentsOf: url))
            store.update { $0.client = client }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        recomputeState()
    }

    func signIn() async {
        guard let client else {
            lastError = GoogleAuthError.noClient.localizedDescription
            return
        }
        receiver?.cancel()
        let receiver = LoopbackReceiver()
        self.receiver = receiver
        state = .signingIn
        lastError = nil
        defer {
            receiver.cancel()
            if self.receiver === receiver { self.receiver = nil }
            recomputeState()
        }

        do {
            let port = try await receiver.start()
            let redirectURI = "http://127.0.0.1:\(port)"
            let pkce = GoogleOAuth.PKCE.make()
            let expectedState = GoogleOAuth.randomURLSafeString(bytes: 16)
            NSWorkspace.shared.open(
                GoogleOAuth.authorizationURL(client: client, redirectURI: redirectURI, pkce: pkce, state: expectedState)
            )

            let params = try await receiver.waitForCallback()
            if let error = params["error"] { throw GoogleAuthError.denied(error) }
            guard params["state"] == expectedState else { throw GoogleAuthError.stateMismatch }
            guard let code = params["code"] else { throw GoogleAuthError.denied("no code") }

            let tokens = try await requestTokens(
                GoogleOAuth.exchangeRequest(client: client, code: code, redirectURI: redirectURI, verifier: pkce.verifier)
            )
            guard let refreshToken = tokens.refreshToken else {
                throw GoogleAuthError.tokenRequestFailed("Google didn't return a refresh token")
            }
            store.update {
                $0.refreshToken = refreshToken
                $0.email = tokens.idToken.flatMap(GoogleOAuth.email(fromIDToken:))
            }
            accessToken = (tokens.accessToken, Date().addingTimeInterval(tokens.expiresIn))
        } catch is CancellationError {
            // Superseded by another sign-in attempt or cancelled.
        } catch {
            lastError = error.localizedDescription
        }
    }

    func cancelSignIn() {
        receiver?.cancel()
    }

    func signOut() {
        store.update {
            $0.refreshToken = nil
            $0.email = nil
        }
        accessToken = nil
        refreshTask?.cancel()
        refreshTask = nil
        recomputeState()
    }

    func removeClient() {
        signOut()
        store.update { $0.client = nil }
        recomputeState()
    }

    /// A valid access token, refreshing if it's close to expiry.
    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let accessToken, accessToken.expiresAt.timeIntervalSinceNow > 60 {
            return accessToken.value
        }
        if let refreshTask { return try await refreshTask.value }

        let task = Task { try await self.refresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func refresh() async throws -> String {
        guard let client else { throw GoogleAuthError.noClient }
        guard let refreshToken = store.load().refreshToken else { throw GoogleAuthError.notSignedIn }
        do {
            let tokens = try await requestTokens(GoogleOAuth.refreshRequest(client: client, refreshToken: refreshToken))
            accessToken = (tokens.accessToken, Date().addingTimeInterval(tokens.expiresIn))
            return tokens.accessToken
        } catch GoogleAuthError.reauthRequired {
            signOut()
            lastError = GoogleAuthError.reauthRequired.localizedDescription
            throw GoogleAuthError.reauthRequired
        }
    }

    private func requestTokens(_ request: URLRequest) async throws -> TokenResponse {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let code = body["error"] as? String ?? "HTTP \(status)"
            if code == "invalid_grant" { throw GoogleAuthError.reauthRequired }
            throw GoogleAuthError.tokenRequestFailed(body["error_description"] as? String ?? code)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private var client: OAuthClient? {
        store.load().client
    }

    private func recomputeState() {
        if case .signingIn = state, receiver != nil { return }
        if client == nil {
            state = .needsClient
        } else if store.load().refreshToken == nil {
            state = .signedOut
        } else {
            state = .signedIn(email: store.load().email)
        }
    }
}
