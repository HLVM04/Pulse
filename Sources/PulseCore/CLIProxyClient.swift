import Foundation

public enum SourceError: Error, LocalizedError, Equatable {
    case unauthorized
    case http(Int)
    case unreachable(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "The key was rejected."
        case .http(let status): "The server answered HTTP \(status)."
        case .unreachable(let detail): detail
        case .invalidResponse(let detail): detail
        }
    }
}

/// Read-only client for the CLIProxyAPI management API.
public struct CLIProxyClient: Sendable {
    public var baseURL: URL
    public var managementKey: String

    public init(baseURL: URL, managementKey: String) {
        self.baseURL = baseURL
        self.managementKey = managementKey
    }

    /// Recorded quota history since `since` (the backend keeps 14 days).
    public func quotaHistory(since: Date) async throws -> QuotaHistory {
        var components = URLComponents(
            url: baseURL.appending(path: "v8/management/observability/quota"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "since", value: String(Int(since.timeIntervalSince1970 * 1000)))]
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SourceError.unreachable("Can't reach CLIProxyAPI. Is Tailscale connected?")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw SourceError.unauthorized }
        guard (200..<300).contains(status) else { throw SourceError.http(status) }
        do {
            return try QuotaHistory.decode(data)
        } catch {
            throw SourceError.invalidResponse("CLIProxyAPI sent quota data Pulse can't read.")
        }
    }

    /// The management page, opened on its quota view.
    public var quotaPageURL: URL {
        var components = URLComponents(url: baseURL.appending(path: "management.html"), resolvingAgainstBaseURL: false)!
        components.fragment = "/quota"
        return components.url!
    }
}
