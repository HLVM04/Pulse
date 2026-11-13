import Foundation

/// A minimal MCP client over Streamable HTTP: initialize once, then `tools/call`.
/// Responses may come back as plain JSON or as a short SSE stream.
public actor MCPClient {
    public let endpoint: URL
    private let token: String
    private var sessionId: String?
    private var protocolVersion = "2025-06-18"
    private var initialized = false
    private var nextId = 1
    private let session: URLSession

    public init(endpoint: URL, token: String) {
        self.endpoint = endpoint
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: configuration)
    }

    /// Calls a tool and returns its result payload as JSON data: the structured
    /// content when present, otherwise the first text block.
    public func callTool(_ name: String, argumentsJSON: Data) async throws -> Data {
        let arguments = (try? J.parse(argumentsJSON)) ?? [String: Any]()
        let result = try await withSessionRetry {
            try await self.request(method: "tools/call", params: ["name": name, "arguments": arguments])
        }
        let content = J.arr(result["content"]).compactMap(J.obj)
        let text = content.first { J.str($0["type"]) == "text" }.map { J.str($0["text"]) } ?? ""
        if J.bool(result["isError"]) {
            throw SourceError.invalidResponse(text.isEmpty ? "\(name) failed." : text)
        }
        if let structured = result["structuredContent"], JSONSerialization.isValidJSONObject(structured) {
            return try JSONSerialization.data(withJSONObject: structured)
        }
        return Data(text.utf8)
    }

    private func withSessionRetry(_ body: () async throws -> [String: Any]) async throws -> [String: Any] {
        try await ensureInitialized()
        do {
            return try await body()
        } catch SessionExpired.expired {
            initialized = false
            sessionId = nil
            try await ensureInitialized()
            return try await body()
        }
    }

    private enum SessionExpired: Error { case expired }

    private func ensureInitialized() async throws {
        guard !initialized else { return }
        let result = try await request(method: "initialize", params: [
            "protocolVersion": protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Pulse", "version": "0.1.0"],
        ])
        let negotiated = J.str(result["protocolVersion"])
        if !negotiated.isEmpty { protocolVersion = negotiated }
        initialized = true
        _ = try await post(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextId
        nextId += 1
        let (data, response) = try await post(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        let messages: [[String: Any]]
        if contentType.contains("text/event-stream") {
            messages = Self.sseMessages(data)
        } else if let object = J.obj(try? J.parse(data)) {
            messages = [object]
        } else {
            messages = J.arr(try? J.parse(data)).compactMap(J.obj)
        }
        guard let message = messages.first(where: { J.num($0["id"]).map(Int.init) == id }) else {
            throw SourceError.invalidResponse("T3 Code sent an empty MCP reply to \(method).")
        }
        if let error = J.obj(message["error"]) {
            throw SourceError.invalidResponse(J.str(error["message"]).isEmpty ? "MCP error." : J.str(error["message"]))
        }
        return J.obj(message["result"]) ?? [:]
    }

    private func post(_ body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let sessionId { request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
        if initialized { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await session.data(for: request)
        } catch {
            throw SourceError.unreachable("T3 Code isn't running.")
        }
        guard let response = urlResponse as? HTTPURLResponse else { throw SourceError.http(0) }
        if response.statusCode == 401 || response.statusCode == 403 { throw SourceError.unauthorized }
        if response.statusCode == 404, sessionId != nil { throw SessionExpired.expired }
        guard (200..<300).contains(response.statusCode) else { throw SourceError.http(response.statusCode) }
        if let id = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !id.isEmpty { sessionId = id }
        return (data, response)
    }

    static func sseMessages(_ data: Data) -> [[String: Any]] {
        let text = String(decoding: data, as: UTF8.self)
        var messages: [[String: Any]] = []
        var buffer: [String] = []
        func flush() {
            guard !buffer.isEmpty else { return }
            let payload = buffer.joined(separator: "\n")
            buffer.removeAll()
            if let object = J.obj(try? J.parse(Data(payload.utf8))) { messages.append(object) }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = line.hasSuffix("\r") ? line.dropLast() : line
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("data:") {
                buffer.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        flush()
        return messages
    }
}
