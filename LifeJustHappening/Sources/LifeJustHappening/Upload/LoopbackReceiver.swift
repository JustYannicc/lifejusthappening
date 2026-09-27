import Foundation
import Network

/// Tiny one-request HTTP server on 127.0.0.1 that catches the OAuth redirect.
final class LoopbackReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lifejusthappening.oauth-loopback")
    private var listener: NWListener?
    private var callback: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?

    /// Starts listening and returns the chosen port.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            // Handlers all run on `queue`, so a plain box is enough to resume exactly once.
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            listener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    once.done = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    /// Query parameters of the first redirect that carries `code` or `error`.
    func waitForCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let pending = self.pending {
                    continuation.resume(with: pending)
                } else {
                    self.callback = continuation
                }
            }
        }
    }

    func cancel() {
        queue.async {
            self.deliver(.failure(CancellationError()))
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return connection.cancel() }
            let params = data.flatMap(Self.queryParameters(fromRequest:))
            let isCallback = params.map { $0["code"] != nil || $0["error"] != nil } ?? false
            let body = isCallback
                ? "<html><body style=\"font:16px -apple-system;padding:40px\"><h2>lifejusthappening is connected.</h2><p>You can close this tab.</p></body></html>"
                : "Not found"
            let status = isCallback ? "200 OK" : "404 Not Found"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if isCallback, let params { self.deliver(.success(params)) }
        }
    }

    private func deliver(_ result: Result<[String: String], Error>) {
        guard pending == nil else { return }
        pending = result
        callback?.resume(with: result)
        callback = nil
    }

    static func queryParameters(fromRequest data: Data) -> [String: String]? {
        guard let request = String(data: data, encoding: .utf8),
              let firstLine = request.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1\(parts[1])") else { return nil }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            result[item.name] = item.value ?? ""
        }
        return result
    }
}
