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
    private(set) var t3Status: SourceStatus = .notConfigured
    private(set) var t3Connecting = false
    private(set) var now = Date()
    var route: PanelRoute = .main

    private var history: QuotaHistory?
    private var t3Client: T3Client?
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
        setUpT3Client()
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
        t3Status = .ok
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

    private func setUpT3Client() {
        guard let token = Keychain.readT3Token() else {
            t3Status = .notConfigured
            t3Client = nil
            return
        }
        if token.isExpired {
            t3Status = .expired
            t3Client = nil
            return
        }
        t3Client = T3Client(origin: T3Server.localOrigin(), token: token.accessToken)
        t3Status = .loading
    }

    func connectT3() {
        guard !t3Connecting else { return }
        t3Connecting = true
        Task {
            defer { t3Connecting = false }
            do {
                let token = try await T3OAuth.signIn(origin: T3Server.localOrigin()) { url in
                    NSWorkspace.shared.open(url)
                }
                Keychain.writeT3Token(token)
                knownStatuses = nil
                setUpT3Client()
                await refreshThreads()
                NSApp.activate()
            } catch is CancellationError {
                return
            } catch {
                t3Status = .error(error.localizedDescription)
            }
        }
    }

    func disconnectT3() {
        Keychain.delete(Keychain.Account.t3Token)
        t3Client = nil
        activeThreads = []
        recentThreads = []
        t3Status = .notConfigured
    }

    func refreshThreads() async {
        lastThreadPoll = Date()
        guard let client = t3Client else { return }
        do {
            let snapshot = try await client.snapshot()
            activeThreads = snapshot.active.filter { !$0.snoozed }
            recentThreads = snapshot.recent
            t3Status = .ok
            notifyTransitions(snapshot)
        } catch SourceError.unauthorized {
            t3Status = .expired
            t3Client = nil
        } catch {
            t3Status = .error(error.localizedDescription)
        }
    }

    private func notifyTransitions(_ snapshot: T3Snapshot) {
        let threads = snapshot.active + snapshot.recent
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
