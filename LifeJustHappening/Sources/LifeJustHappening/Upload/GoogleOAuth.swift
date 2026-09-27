import CryptoKit
import Foundation

/// The "Desktop app" OAuth client you create in Google Cloud Console.
/// Google treats desktop client secrets as non-confidential, so it's fine on disk/in Keychain.
struct OAuthClient: Codable, Equatable {
    let clientID: String
    let clientSecret: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
    }

    /// Parses the JSON file Google Cloud Console lets you download (`{"installed": {...}}`).
    static func parse(downloadedJSON data: Data) throws -> OAuthClient {
        struct Wrapper: Decodable { let installed: OAuthClient? }
        if let wrapped = try? JSONDecoder().decode(Wrapper.self, from: data), let client = wrapped.installed {
            return client
        }
        if let bare = try? JSONDecoder().decode(OAuthClient.self, from: data) {
            return bare
        }
        throw GoogleAuthError.invalidClientFile
    }
}

enum GoogleAuthError: LocalizedError {
    case invalidClientFile
    case noClient
    case notSignedIn
    case reauthRequired
    case denied(String)
    case stateMismatch
    case tokenRequestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidClientFile: return "That's not a Google \"Desktop app\" OAuth client JSON"
        case .noClient: return "Import your Google OAuth client first"
        case .notSignedIn: return "Not signed in to Google"
        case .reauthRequired: return "Google access expired or was revoked. Sign in again."
        case .denied(let reason): return "Google sign-in was cancelled (\(reason))"
        case .stateMismatch: return "Sign-in response didn't match the request"
        case .tokenRequestFailed(let reason): return "Google token request failed: \(reason)"
        }
    }
}

struct TokenResponse: Decodable {
    let accessToken: String
    let expiresIn: TimeInterval
    let refreshToken: String?
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
    }
}

/// Protocol plumbing for Google's installed-app flow (loopback redirect + PKCE).
enum GoogleOAuth {
    static let scopes = [
        "openid",
        "email",
        "https://www.googleapis.com/auth/photoslibrary.appendonly",
        // Only to find our own album again after a reinstall; can't see anything else.
        "https://www.googleapis.com/auth/photoslibrary.readonly.appcreateddata",
    ]

    struct PKCE {
        let verifier: String
        let challenge: String

        static func make() -> PKCE {
            let verifier = randomURLSafeString(bytes: 48)
            let digest = SHA256.hash(data: Data(verifier.utf8))
            return PKCE(verifier: verifier, challenge: Data(digest).base64URLEncoded())
        }
    }

    static func authorizationURL(client: OAuthClient, redirectURI: String, pkce: PKCE, state: String) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    static func exchangeRequest(client: OAuthClient, code: String, redirectURI: String, verifier: String) -> URLRequest {
        tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
            "client_id": client.clientID,
            "client_secret": client.clientSecret,
        ])
    }

    static func refreshRequest(client: OAuthClient, refreshToken: String) -> URLRequest {
        tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": client.clientID,
            "client_secret": client.clientSecret,
        ])
    }

    /// Email claim from an ID token. Display only, so the signature isn't checked.
    static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let payload = Data(base64URLEncoded: String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        return json["email"] as? String
    }

    static func randomURLSafeString(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func tokenRequest(_ form: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+/?")
        request.httpBody = Data(
            form.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
                .joined(separator: "&")
                .utf8
        )
        return request
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
