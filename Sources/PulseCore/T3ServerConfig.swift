import Foundation

/// A T3 Code server Pulse signs in to. "This Mac" follows the local server's
/// port; other servers (a VPS on the tailnet, say) have a fixed address.
public struct T3ServerConfig: Codable, Identifiable, Hashable, Sendable {
    public static let thisMacId = "local"
    public static let defaultPort = 3773

    public var id: String
    public var name: String
    /// nil for this Mac's own server.
    public var address: URL?
    /// Filled in once the server has answered.
    public var environmentId: String?

    public init(id: String, name: String, address: URL?, environmentId: String? = nil) {
        self.id = id
        self.name = name
        self.address = address
        self.environmentId = environmentId
    }

    public static let thisMac = T3ServerConfig(id: thisMacId, name: "This Mac", address: nil)

    public var isThisMac: Bool { address == nil }
    public var origin: URL { address ?? T3Server.localOrigin() }

    /// Label shown next to this server's threads.
    public var threadLabel: String { isThisMac ? "Mac" : name }

    /// This Mac keeps the account name Pulse 1.0 used, so its sign-in carries over.
    public var keychainAccount: String {
        isThisMac ? Keychain.Account.t3Token : "\(Keychain.Account.t3Token).\(id)"
    }

    /// Turns what someone types ("100.64.0.1", "vps:3773", "https://t3.example.ts.net")
    /// into a server origin. Without a scheme it assumes http and T3's default port.
    public static func normalizeAddress(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let hasScheme = text.contains("://")
        if !hasScheme { text = "http://" + text }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty,
              components.scheme == "http" || components.scheme == "https"
        else { return nil }
        if !hasScheme, components.port == nil { components.port = defaultPort }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

public struct T3EnvironmentInfo: Sendable, Equatable {
    public var id: String
    public var label: String
    public var os: String
    public var machine: String
}

extension T3Server {
    /// Asks a T3 server who it is (`/.well-known/t3/environment`, no sign-in needed).
    public static func environment(at origin: URL) async throws -> T3EnvironmentInfo {
        var request = URLRequest(url: origin.appending(path: ".well-known/t3/environment"), timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SourceError.unreachable("No T3 Code server answered at \(origin.host() ?? origin.absoluteString).")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = J.obj(try? J.parse(data)), !J.str(object["environmentId"]).isEmpty
        else { throw SourceError.invalidResponse("That address isn't a T3 Code server.") }
        let platform = J.obj(object["platform"]) ?? [:]
        return T3EnvironmentInfo(
            id: J.str(object["environmentId"]),
            label: J.str(object["label"]),
            os: J.str(platform["os"]),
            machine: J.str(platform["machine"])
        )
    }
}
