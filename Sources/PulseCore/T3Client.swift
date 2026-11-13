import Foundation

public struct T3Thread: Sendable, Identifiable, Hashable {
    public var id: String
    public var projectId: String
    public var title: String
    public var status: String
    public var model: String
    public var createdAt: Date?
    public var updatedAt: Date?
    public var environmentId: String
    public var environmentLabel: String
    public var isLocalEnvironment: Bool
    public var projectTitle: String?
    public var snoozed: Bool

    public init(
        id: String, projectId: String, title: String, status: String, model: String,
        createdAt: Date?, updatedAt: Date?, environmentId: String, environmentLabel: String,
        isLocalEnvironment: Bool, projectTitle: String?, snoozed: Bool
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.status = status
        self.model = model
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.environmentId = environmentId
        self.environmentLabel = environmentLabel
        self.isLocalEnvironment = isLocalEnvironment
        self.projectTitle = projectTitle
        self.snoozed = snoozed
    }

    public static let activeStatuses = ["preparing", "queued", "starting", "running", "waiting"]
    public static let finishedStatuses = ["completed", "failed", "interrupted"]

    public var key: String { "\(environmentId)/\(id)" }
    public var isWaiting: Bool { status == "waiting" }
    public var isActive: Bool { Self.activeStatuses.contains(status) }
    public var isFinished: Bool { Self.finishedStatuses.contains(status) }

    /// Opens the thread in the T3 Code desktop app.
    public var deepLink: URL { URL(string: "t3code://threads/\(environmentId)/\(id)")! }

    /// "claude-opus-5-5" → "Opus 5.5", "gpt-6-luna" → "GPT-6 Luna".
    public var modelDisplay: String {
        let raw = model.lowercased()
        if raw.hasPrefix("claude-") {
            let parts = raw.dropFirst(7).split(separator: "-")
            guard let family = parts.first else { return model }
            let version = parts.dropFirst().joined(separator: ".")
            return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
        }
        if raw.hasPrefix("gpt-") {
            let parts = raw.dropFirst(4).split(separator: "-")
            guard let version = parts.first else { return model }
            let rest = parts.dropFirst().map { $0.capitalized }.joined(separator: " ")
            return rest.isEmpty ? "GPT-\(version)" : "GPT-\(version) \(rest)"
        }
        return model
    }
}

public struct T3Snapshot: Sendable, Equatable {
    public var active: [T3Thread]
    public var recent: [T3Thread]
    public var fetchedAt: Date
}

/// Where the local T3 Code server listens, from `~/.t3/userdata/server-runtime.json`.
public enum T3Server {
    public static let fallbackOrigin = URL(string: "http://127.0.0.1:3773")!

    public static func localOrigin(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let file = home.appending(path: ".t3/userdata/server-runtime.json")
        guard let data = try? Data(contentsOf: file),
              let object = J.obj(try? J.parse(data)),
              let origin = URL(string: J.str(object["origin"])), origin.scheme != nil
        else { return fallbackOrigin }
        return origin
    }
}

/// Reads thread state from T3 Code through its MCP endpoint (read-only scope).
public actor T3Client {
    public let origin: URL
    private let mcp: MCPClient
    private var localEnvironment: (id: String, label: String)?
    private var projectTitles: [String: String] = [:]
    private var projectsFetchedAt: [String: Date] = [:]

    public init(origin: URL, token: String) {
        self.origin = origin
        self.mcp = MCPClient(endpoint: origin.appending(path: "mcp"), token: token)
    }

    public func snapshot() async throws -> T3Snapshot {
        let local = try await localEnvironmentInfo()
        var environments: [(id: String, label: String, isLocal: Bool)] = [(local.id, local.label, true)]
        if let links = try? await call("t3_environment_links", [:]) {
            for link in J.arr(links["links"]).compactMap(J.obj) where J.str(link["status"]) == "reachable" {
                let id = J.str(link["environmentId"])
                if !id.isEmpty, id != local.id { environments.append((id, J.str(link["label"]), false)) }
            }
        }

        var active: [T3Thread] = []
        var recent: [T3Thread] = []
        for environment in environments {
            do {
                try await refreshProjects(environmentId: environment.id, isLocal: environment.isLocal)
                active += try await threads(environment, statuses: T3Thread.activeStatuses, limit: 50)
                recent += try await threads(environment, statuses: T3Thread.finishedStatuses, limit: 6)
            } catch where !environment.isLocal {
                // A linked machine that drops out should not hide the local threads.
                continue
            }
        }
        let byUpdate: (T3Thread, T3Thread) -> Bool = { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        return T3Snapshot(active: active.sorted(by: byUpdate), recent: recent.sorted(by: byUpdate), fetchedAt: Date())
    }

    private func threads(
        _ environment: (id: String, label: String, isLocal: Bool),
        statuses: [String],
        limit: Int
    ) async throws -> [T3Thread] {
        var arguments: [String: Any] = ["allProjects": true, "statuses": statuses, "limit": limit]
        if !environment.isLocal { arguments["environmentId"] = environment.id }
        let result = try await call("t3_thread_list", arguments)
        return J.arr(result["threads"]).compactMap(J.obj).compactMap { raw in
            let id = J.str(raw["threadId"])
            guard !id.isEmpty else { return nil }
            let projectId = J.str(raw["projectId"])
            return T3Thread(
                id: id,
                projectId: projectId,
                title: J.str(raw["title"]).isEmpty ? "Untitled thread" : J.str(raw["title"]),
                status: J.str(raw["status"]),
                model: J.str(raw["model"]),
                createdAt: J.date(raw["createdAt"]),
                updatedAt: J.date(raw["updatedAt"]),
                environmentId: environment.id,
                environmentLabel: environment.label,
                isLocalEnvironment: environment.isLocal,
                projectTitle: projectTitles["\(environment.id)/\(projectId)"],
                snoozed: J.bool(raw["snoozed"])
            )
        }
    }

    private func refreshProjects(environmentId: String, isLocal: Bool) async throws {
        if let fetched = projectsFetchedAt[environmentId], Date().timeIntervalSince(fetched) < 600 { return }
        var cursor: Int? = 0
        var pages = 0
        while let current = cursor, pages < 5 {
            pages += 1
            var arguments: [String: Any] = ["limit": 100, "cursor": current]
            if !isLocal { arguments["environmentId"] = environmentId }
            let result = try await call("t3_project_list", arguments)
            for project in J.arr(result["projects"]).compactMap(J.obj) {
                projectTitles["\(environmentId)/\(J.str(project["id"]))"] = J.str(project["title"])
            }
            cursor = J.num(result["nextCursor"]).map(Int.init)
        }
        projectsFetchedAt[environmentId] = Date()
    }

    private func localEnvironmentInfo() async throws -> (id: String, label: String) {
        if let localEnvironment { return localEnvironment }
        let url = origin.appending(path: ".well-known/t3/environment")
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(from: url)
        } catch {
            throw SourceError.unreachable("T3 Code isn't running.")
        }
        let object = J.obj(try? J.parse(data)) ?? [:]
        let id = J.str(object["environmentId"])
        guard !id.isEmpty else { throw SourceError.invalidResponse("T3 Code didn't say which machine this is.") }
        let platform = J.obj(object["platform"]) ?? [:]
        let label = J.str(platform["machine"]) == "laptop" || J.str(platform["os"]) == "darwin" ? "Mac" : J.str(object["label"])
        localEnvironment = (id, label)
        return (id, label)
    }

    private func call(_ tool: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: arguments)
        let result = try await mcp.callTool(tool, argumentsJSON: data)
        return J.obj(try J.parse(result)) ?? [:]
    }
}
