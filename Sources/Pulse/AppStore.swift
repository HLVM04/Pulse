import AppKit
import Observation
import PulseCore
import ServiceManagement

enum SourceStatus: Equatable {
    case notConfigured
    case loading
    case ok
    case expired
    case error(String)
}

enum PanelRoute: Hashable {
    case main
    case quota(String)
}

/// App state and polling. Quota refreshes every minute (like the management
/// page); threads every 4 s while the panel is open and every 15 s otherwise.
@MainActor
@Observable
final class AppStore {
    static let shared = AppStore()

    // MARK: Settings

    var cliproxyURL: String = UserDefaults.standard.string(forKey: "cliproxyURL") ?? "" {
        didSet { UserDefaults.standard.set(cliproxyURL, forKey: "cliproxyURL") }
    }
    var burnWindowHours: Int = UserDefaults.standard.object(forKey: "burnWindowHours") as? Int ?? 1 {
        didSet {
            UserDefaults.standard.set(burnWindowHours, forKey: "burnWindowHours")
            rebuildPools()
        }
    }
    /// Alert when the first pool drops under this share of its capacity.
    var lowThreshold: Double = UserDefaults.standard.object(forKey: "lowThreshold") as? Double ?? 0.2 {
        didSet { UserDefaults.standard.set(lowThreshold, forKey: "lowThreshold") }
    }
    var notifyFinished: Bool = UserDefaults.standard.object(forKey: "notifyFinished") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyFinished, forKey: "notifyFinished") }
    }
    var notifyWaiting: Bool = UserDefaults.standard.object(forKey: "notifyWaiting") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyWaiting, forKey: "notifyWaiting") }
    }
    var notifyLowPool: Bool = UserDefaults.standard.object(forKey: "notifyLowPool") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyLowPool, forKey: "notifyLowPool") }
    }
    var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
    private(set) var hasCLIProxyKey = Keychain.read(Keychain.Account.cliproxyKey) != nil

    // MARK: Data

    private(set) var pools: [PoolSummary] = []
    private(set) var quotaStatus: SourceStatus = .notConfigured
    private(set) var quotaUpdatedAt: Date?
    private(set) var activeThreads: [T3Thread] = []
    private(set) var recentThreads: [T3Thread] = []
    /// T3 Code servers, "This Mac" first. Persisted in UserDefaults; tokens live in the Keychain.
    private(set) var t3Servers: [T3ServerConfig] = AppStore.loadServers()
    private(set) var t3ServerStatus: [String: SourceStatus] = [:]
    private(set) var t3ConnectingId: String?
    private(set) var now = Date()
    var route: PanelRoute = .main

    private var history: QuotaHistory?
    private var t3Clients: [String: T3Client] = [:]
    private var panelOpen = false
    private var lastThreadPoll = Date.distantPast
    private var lastQuotaPoll = Date.distantPast
    private var knownStatuses: [String: String]?
    private var lowPoolNotified = false
    private var started = false

    // MARK: Derived

    var waitingThreads: [T3Thread] { activeThreads.filter(\.isWaiting) }
    var runningThreads: [T3Thread] { activeThreads.filter { !$0.isWaiting } }
    /// Finished in the last two hours, newest first.
    var recentlyFinished: [T3Thread] {
        recentThreads.filter { ($0.updatedAt ?? .distantPast) > now.addingTimeInterval(-2 * 3600) }
    }
    var primaryPool: PoolSummary? { pools.first }

    var t3Connecting: Bool { t3ConnectingId != nil }

    func status(of server: T3ServerConfig) -> SourceStatus { t3ServerStatus[server.id] ?? .notConfigured }

    /// Combined T3 state for the panel: fine if any server answers.
    var t3Status: SourceStatus {
        let statuses = t3Servers.map(status(of:))
        if statuses.contains(.ok) { return .ok }
        if statuses.contains(.loading) { return .loading }
        if statuses.allSatisfy({ $0 == .notConfigured }) { return .notConfigured }
        if let error = statuses.first(where: { if case .error = $0 { true } else { false } }) { return error }
        return statuses.contains(.expired) ? .expired : .notConfigured
    }

    /// Servers that need attention while others work: expired sign-ins and unreachable servers.
    var t3Problems: [(server: T3ServerConfig, status: SourceStatus)] {
        t3Servers.compactMap { server in
            switch status(of: server) {
            case .expired, .error: (server, status(of: server))
            default: nil
            }
        }
    }
    var isPoolLow: Bool {
        guard let pool = primaryPool else { return false }
        return pool.fractionLeft < lowThreshold
    }

    var statusImage: NSImage {
        StatusIcon.image(
            fraction: primaryPool?.fractionLeft,
            poolUnits: primaryPool?.remainingNow,
            activeCount: activeThreads.count,
            waiting: !waitingThreads.isEmpty,
            low: isPoolLow,
            stale: quotaStatus != .ok && primaryPool != nil
        )
    }

    var cliproxyClient: CLIProxyClient? {
        guard let url = URL(string: cliproxyURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil,
              let key = Keychain.read(Keychain.Account.cliproxyKey), !key.isEmpty
        else { return nil }
        return CLIProxyClient(baseURL: url, managementKey: key)
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        if DemoData.isEnabled {
            loadDemo()
            return
        }
        setUpT3Clients()
        Task { await self.loop() }
        DebugSnapshot.runIfRequested(self)
    }

    private func loadDemo() {
        DemoData.applyAppearance()
        let now = Date()
        history = DemoData.history(now: now)
        rebuildPools()
        (activeThreads, recentThreads) = DemoData.threads(now: now)
        quotaStatus = .ok
        quotaUpdatedAt = now
        t3ServerStatus[T3ServerConfig.thisMacId] = .ok
        route = DemoData.route
    }

    func panelDidOpen() {
        if DemoData.isEnabled {
            route = DemoData.route
            return
        }
        panelOpen = true
        now = Date()
        Task {
            if Date().timeIntervalSince(lastThreadPoll) > 3 { await refreshThreads() }
            if Date().timeIntervalSince(lastQuotaPoll) > 20 { await refreshQuota() }
        }
    }

    func panelDidClose() {
        panelOpen = false
        route = .main
    }

    private func loop() async {
        while true {
            now = Date()
            if Date().timeIntervalSince(lastQuotaPoll) >= 60 { await refreshQuota() }
            let threadInterval: TimeInterval = panelOpen ? 4 : 15
            if Date().timeIntervalSince(lastThreadPoll) >= threadInterval { await refreshThreads() }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func refreshAll() {
        Task {
            await refreshQuota()
            await refreshThreads()
        }
    }

    // MARK: Quota

    func saveCLIProxyKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(Keychain.Account.cliproxyKey)
        } else {
            Keychain.write(trimmed, account: Keychain.Account.cliproxyKey)
        }
        hasCLIProxyKey = !trimmed.isEmpty
        Task { await refreshQuota() }
    }

    func refreshQuota() async {
        lastQuotaPoll = Date()
        guard let client = cliproxyClient else {
            quotaStatus = .notConfigured
            pools = []
            return
        }
        if pools.isEmpty { quotaStatus = .loading }
        let range = PoolMath.visibleRange(nowMs: Date().timeIntervalSince1970 * 1000)
        let since = Date(timeIntervalSince1970: min(range.fromMs / 1000, Date().timeIntervalSince1970 - 86_400))
        do {
            history = try await client.quotaHistory(since: since)
            quotaUpdatedAt = Date()
            quotaStatus = .ok
            rebuildPools()
            checkLowPool()
        } catch SourceError.unauthorized {
            quotaStatus = .error("CLIProxyAPI rejected the management key.")
        } catch {
            quotaStatus = .error(error.localizedDescription)
        }
    }

    private func rebuildPools() {
        guard let history else { return }
        pools = PoolSummary.buildAll(history, nowMs: Date().timeIntervalSince1970 * 1000, burnWindowHours: Double(burnWindowHours))
    }

    private func checkLowPool() {
        guard let pool = primaryPool else { return }
        if pool.fractionLeft >= lowThreshold {
            lowPoolNotified = false
            return
        }
        guard notifyLowPool, !lowPoolNotified else { return }
        lowPoolNotified = true
        let empty = pool.projection.poolEmptyAt.map { "At this pace it runs dry \(Format.when($0, now: pool.nowMs))." }
            ?? "It lasts past \(Format.date(pool.projection.horizonMs)) at this pace."
        Notifier.post(
            id: "pool-low-\(pool.provider)",
            title: "\(pool.displayName) pool at \(Format.percent(pool.remainingNow))",
            body: empty,
            url: cliproxyClient?.quotaPageURL
        )
    }

    // MARK: T3 Code

    private static let serversKey = "t3Servers"

    private static func loadServers() -> [T3ServerConfig] {
        var servers: [T3ServerConfig] = []
        if let data = UserDefaults.standard.data(forKey: serversKey),
           let saved = try? JSONDecoder().decode([T3ServerConfig].self, from: data) {
            servers = saved
        }
        if !servers.contains(where: \.isThisMac) { servers.insert(.thisMac, at: 0) }
        return servers
    }

    private func saveServers() {
        if let data = try? JSONEncoder().encode(t3Servers) {
            UserDefaults.standard.set(data, forKey: Self.serversKey)
        }
    }

    private func setUpT3Clients() {
        for server in t3Servers { setUpClient(for: server) }
    }

    private func setUpClient(for server: T3ServerConfig) {
        guard let token = Keychain.readT3Token(account: server.keychainAccount) else {
            t3Clients[server.id] = nil
            t3ServerStatus[server.id] = .notConfigured
            return
        }
        if token.isExpired {
            t3Clients[server.id] = nil
            t3ServerStatus[server.id] = .expired
            return
        }
        t3Clients[server.id] = T3Client(
            origin: server.origin, token: token.accessToken, label: server.threadLabel, isThisMac: server.isThisMac
        )
        t3ServerStatus[server.id] = .loading
    }

    /// Adds a T3 Code server by address and starts its sign-in.
    func addT3Server(address: String) async throws {
        guard let origin = T3ServerConfig.normalizeAddress(address) else {
            throw SourceError.invalidResponse("Enter an address like 100.64.0.1 or https://host.")
        }
        let info = try await T3Server.environment(at: origin)
        if let existing = t3Servers.first(where: { $0.environmentId == info.id || $0.address == origin }) {
            throw SourceError.invalidResponse("\(existing.name) is already in the list.")
        }
        if info.id == t3Servers.first(where: \.isThisMac)?.environmentId {
            throw SourceError.invalidResponse("That's this Mac's own T3 Code.")
        }
        let name = info.label.isEmpty ? (origin.host() ?? "Server") : info.label
        let server = T3ServerConfig(id: UUID().uuidString, name: name, address: origin, environmentId: info.id)
        t3Servers.append(server)
        saveServers()
        t3ServerStatus[server.id] = .notConfigured
        connectT3(server.id)
    }

    func renameT3Server(_ id: String, to name: String) {
        guard let index = t3Servers.firstIndex(where: { $0.id == id }), !t3Servers[index].isThisMac else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != t3Servers[index].name else { return }
        t3Servers[index].name = trimmed
        saveServers()
        if t3Clients[id] != nil { setUpClient(for: t3Servers[index]) }
        Task { await refreshThreads() }
    }

    func removeT3Server(_ id: String) {
        guard let server = t3Servers.first(where: { $0.id == id }), !server.isThisMac else { return }
        Keychain.delete(server.keychainAccount)
        t3Servers.removeAll { $0.id == id }
        t3Clients[id] = nil
        t3ServerStatus[id] = nil
        saveServers()
        Task { await refreshThreads() }
    }

    func connectT3(_ id: String = T3ServerConfig.thisMacId) {
        guard t3ConnectingId == nil, let server = t3Servers.first(where: { $0.id == id }) else { return }
        t3ConnectingId = id
        Task {
            defer { t3ConnectingId = nil }
            do {
                let token = try await T3OAuth.signIn(origin: server.origin) { url in
                    NSWorkspace.shared.open(url)
                }
                Keychain.writeT3Token(token, account: server.keychainAccount)
                setUpClient(for: server)
                await refreshThreads()
                NSApp.activate()
            } catch is CancellationError {
                return
            } catch {
                t3ServerStatus[id] = .error(error.localizedDescription)
            }
        }
    }

    func disconnectT3(_ id: String = T3ServerConfig.thisMacId) {
        guard let server = t3Servers.first(where: { $0.id == id }) else { return }
        Keychain.delete(server.keychainAccount)
        t3Clients[id] = nil
        t3ServerStatus[id] = .notConfigured
        Task { await refreshThreads() }
    }

    func refreshThreads() async {
        lastThreadPoll = Date()
        let clients = t3Clients
        guard !clients.isEmpty else {
            activeThreads = []
            recentThreads = []
            return
        }
        let results = await withTaskGroup(of: (String, Result<T3Snapshot, Error>).self) { group in
            for (id, client) in clients {
                group.addTask {
                    do { return (id, .success(try await client.snapshot())) } catch { return (id, .failure(error)) }
                }
            }
            var collected: [(String, Result<T3Snapshot, Error>)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        var snapshots: [T3Snapshot] = []
        for (id, result) in results {
            // The server may have been removed or signed out while we waited.
            guard t3Clients[id] != nil else { continue }
            switch result {
            case .success(let snapshot):
                t3ServerStatus[id] = .ok
                snapshots.append(snapshot)
                if let index = t3Servers.firstIndex(where: { $0.id == id }), t3Servers[index].environmentId != snapshot.environmentId {
                    t3Servers[index].environmentId = snapshot.environmentId
                    saveServers()
                }
            case .failure(SourceError.unauthorized):
                t3ServerStatus[id] = .expired
                t3Clients[id] = nil
            case .failure(let error):
                t3ServerStatus[id] = .error(error.localizedDescription)
            }
        }

        // A machine can show up twice: directly, and as a machine linked to another server.
        // Keep the direct copy, which carries the name chosen in Settings.
        func merge(_ pick: (T3Snapshot) -> [T3Thread]) -> [T3Thread] {
            var seen = Set<String>()
            var merged: [T3Thread] = []
            let ordered = snapshots.flatMap { snapshot in
                pick(snapshot).map { (thread: $0, direct: $0.environmentId == snapshot.environmentId) }
            }
            // Direct copies first (Swift's sort is stable), then drop later duplicates.
            for item in ordered.sorted(by: { $0.direct && !$1.direct }) where seen.insert(item.thread.key).inserted {
                merged.append(item.thread)
            }
            return merged.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        }
        let active = merge(\.active)
        let recent = merge(\.recent)
        activeThreads = active.filter { !$0.snoozed }
        recentThreads = recent
        notifyTransitions(active: active, recent: recent)
    }

    private func notifyTransitions(active: [T3Thread], recent: [T3Thread]) {
        let threads = active + recent
        let previous = knownStatuses
        var next: [String: String] = [:]
        for thread in threads { next[thread.key] = thread.status }
        // Keep threads that dropped out of both lists so they are not re-announced.
        for (key, status) in previous ?? [:] where next[key] == nil { next[key] = status }
        knownStatuses = next
        guard let previous else { return }

        for thread in threads {
            guard let before = previous[thread.key], before != thread.status else { continue }
            if thread.isWaiting, notifyWaiting {
                Notifier.post(
                    id: "waiting-\(thread.key)",
                    title: thread.title,
                    body: "Waiting for you\(thread.projectTitle.map { " in \($0)" } ?? "").",
                    url: thread.deepLink
                )
            } else if thread.isFinished, T3Thread.activeStatuses.contains(before), notifyFinished {
                let verb = switch thread.status {
                case "failed": "Failed"
                case "interrupted": "Stopped"
                default: "Finished"
                }
                Notifier.post(
                    id: "finished-\(thread.key)",
                    title: thread.title,
                    body: "\(verb)\(thread.projectTitle.map { " in \($0)" } ?? "") on \(thread.environmentLabel).",
                    url: thread.deepLink
                )
            }
        }
    }

    // MARK: Actions

    func open(_ thread: T3Thread) {
        NSWorkspace.shared.open(thread.deepLink)
    }

    func openT3() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.t3tools.t3code")
            ?? NSWorkspace.shared.urlForApplication(toOpen: URL(string: "t3code://app/")!) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func openCLIProxy() {
        if let url = cliproxyClient?.quotaPageURL ?? URL(string: cliproxyURL) {
            NSWorkspace.shared.open(url)
        }
    }
}
