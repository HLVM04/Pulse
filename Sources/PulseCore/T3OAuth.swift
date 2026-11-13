import CryptoKit
import Foundation
import Network

public struct T3Token: Codable, Sendable, Equatable {
    public var accessToken: String
    public var expiresAt: Date
    public var origin: URL

    public var isExpired: Bool { expiresAt <= Date().addingTimeInterval(60) }
}

/// Signs Pulse in to T3 Code's MCP endpoint with OAuth 2.1 (PKCE, dynamic client
/// registration, loopback redirect). T3 issues a 30-day token and no refresh
/// token, so this runs again when the token expires.
public enum T3OAuth {
    public static func signIn(
        origin: URL,
        openURL: @escaping @Sendable @MainActor (URL) -> Void
    ) async throws -> T3Token {
        let resourceMeta = try await getJSON(origin.appending(path: ".well-known/oauth-protected-resource"))
        let resource = J.str(resourceMeta["resource"]).isEmpty ? origin.appending(path: "mcp").absoluteString : J.str(resourceMeta["resource"])
        let issuer = J.arr(resourceMeta["authorization_servers"]).first.map { J.str($0) }.flatMap(URL.init(string:)) ?? origin
        let serverMeta = try await getJSON(issuer.appending(path: ".well-known/oauth-authorization-server"))
        guard let authorizeURL = URL(string: J.str(serverMeta["authorization_endpoint"])),
              let tokenURL = URL(string: J.str(serverMeta["token_endpoint"])),
              let registerURL = URL(string: J.str(serverMeta["registration_endpoint"]))
        else { throw SourceError.invalidResponse("T3 Code's sign-in metadata is incomplete.") }

        let receiver = try LoopbackReceiver()
        defer { receiver.stop() }
        let port = try await receiver.start()
        let redirectURI = "http://127.0.0.1:\(port)/callback"

        let registration = try await postJSON(registerURL, [
            "client_name": "Pulse",
            "redirect_uris": [redirectURI],
            "token_endpoint_auth_method": "none",
        ])
        let clientId = J.str(registration["client_id"])
        guard !clientId.isEmpty else { throw SourceError.invalidResponse("T3 Code didn't register Pulse.") }

        let verifier = randomURLSafe(bytes: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let state = randomURLSafe(bytes: 16)
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: "orchestration:read"),
            URLQueryItem(name: "resource", value: resource),
        ]
        await openURL(components.url!)

        let callback = try await receiver.waitForCallback(timeout: 300)
        let query = Dictionary(uniqueKeysWithValues: (callback.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if let error = query["error"], !error.isEmpty {
            throw SourceError.invalidResponse(query["error_description"].flatMap { $0.isEmpty ? nil : $0 } ?? "Sign-in was declined.")
        }
        guard query["state"] == state, let code = query["code"], !code.isEmpty else {
            throw SourceError.invalidResponse("T3 Code's sign-in reply didn't match.")
        }

        let token = try await postForm(tokenURL, [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientId,
            "code_verifier": verifier,
            "resource": resource,
        ])
        let accessToken = J.str(token["access_token"])
        guard !accessToken.isEmpty else {
            throw SourceError.invalidResponse(J.str(token["error_description"]).isEmpty ? "T3 Code didn't issue a token." : J.str(token["error_description"]))
        }
        let expiresIn = J.num(token["expires_in"]) ?? 30 * 86_400
        return T3Token(accessToken: accessToken, expiresAt: Date().addingTimeInterval(expiresIn), origin: origin)
    }

    private static func getJSON(_ url: URL) async throws -> [String: Any] {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return J.obj(try J.parse(data)) ?? [:]
        } catch {
            throw SourceError.unreachable("T3 Code isn't running.")
        }
    }

    private static func postJSON(_ url: URL, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: request)
        return J.obj(try? J.parse(data)) ?? [:]
    }

    private static func postForm(_ url: URL, _ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: request)
        return J.obj(try? J.parse(data)) ?? [:]
    }

    static func randomURLSafe(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64URLEncoded()
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A one-shot HTTP listener on 127.0.0.1 that catches the OAuth redirect.
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "pulse.oauth.loopback")
    private let lock = NSLock()
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<URLComponents, Error>?
    private var receivedCallback: URLComponents?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { readyContinuation = continuation }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let port = self.listener.port?.rawValue ?? 0
                    self.lock.withLock { self.readyContinuation.take() }?.resume(returning: port)
                case .failed(let error):
                    self.lock.withLock { self.readyContinuation.take() }?.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> URLComponents {
        try await withThrowingTaskGroup(of: URLComponents.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let early: URLComponents? = self.lock.withLock {
                        if let received = self.receivedCallback { return received }
                        self.callbackContinuation = continuation
                        return nil
                    }
                    if let early { continuation.resume(returning: early) }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw SourceError.invalidResponse("Sign-in timed out.")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    func stop() {
        listener.cancel()
        let pending = lock.withLock { callbackContinuation.take() }
        pending?.resume(throwing: CancellationError())
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let components = URLComponents(string: "http://127.0.0.1\(target)")
            let isCallback = components?.path == "/callback"
            let body = isCallback
                ? "<!doctype html><meta charset=utf-8><title>Pulse</title><body style=\"font:15px -apple-system;padding:48px;text-align:center\"><h2>Pulse is connected to T3 Code</h2><p>You can close this tab.</p>"
                : "Not found"
            let response = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            guard isCallback, let components else { return }
            let waiter: CheckedContinuation<URLComponents, Error>? = self.lock.withLock {
                if self.receivedCallback == nil { self.receivedCallback = components }
                return self.callbackContinuation.take()
            }
            waiter?.resume(returning: components)
        }
    }
}
