import Foundation
import Combine
import ServiceManagement

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var gauge: GaugeSnapshot?
    @Published private(set) var gaugeError: String?
    @Published private(set) var stats: TranscriptStats = .empty
    @Published private(set) var rtk: RTKStats?
    let rtkInstalled = RTKGain.isInstalled
    let jevInstalled = JevDetector.isInstalled
    @Published private(set) var isRefreshing = false
    /// Ticks every 30 s so relative labels ("read 0.3 min ago") stay honest.
    @Published private(set) var now = Date()
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet { applyLaunchAtLogin() }
    }

    /// Panel tick: transcripts are cheap to rescan, the gauge is not.
    static let refreshInterval: TimeInterval = 60
    /// Minimum delay between two calls to Anthropic's gauge (it rate-limits hard).
    static let gaugeInterval: TimeInterval = 180
    private static let maxBackoff: TimeInterval = 15 * 60

    private let scanner = TranscriptScanner()
    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    /// Next moment the gauge may be called again (pushed back on 429).
    private var nextGaugeFetch = Date.distantPast
    private var lastGaugeFetch = Date.distantPast
    private var backoff: TimeInterval = 0

    init() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        Task { await refresh() }
    }

    /// Menu bar text: the weekly `all` meter, the one that actually runs out.
    var menuBarTitle: String {
        guard let week = gauge?.week else { return gaugeError == nil ? "…" : "!" }
        return "\(Int(week.utilization.rounded()))%"
    }

    /// `force` is the refresh button: it ignores the gauge interval but not an active backoff.
    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        now = Date()

        // The button may jump the 3-minute interval, but never the backoff nor a 10 s floor.
        let allowed = force
            ? backoff == 0 && now.timeIntervalSince(lastGaugeFetch) >= 10 || now >= nextGaugeFetch
            : now >= nextGaugeFetch
        if allowed { await refreshGauge() }
        let weekStart = UsageMath.weekStart(gauge: gauge, now: now)
        let todayStart = Calendar.current.startOfDay(for: now)
        async let scanned = scanner.stats(weekStart: weekStart, todayStart: todayStart, now: now)
        async let gain = Task.detached(priority: .utility) { [now] in
            RTKGain.read(weekStart: weekStart, todayStart: todayStart, now: now)
        }.value
        stats = await scanned
        rtk = await gain
        now = Date()
    }

    private func refreshGauge() async {
        lastGaugeFetch = Date()
        do {
            let token = try CredentialStore.accessToken()
            gauge = try await UsageAPI.fetch(token: token)
            gaugeError = nil
            backoff = 0
            nextGaugeFetch = Date().addingTimeInterval(Self.gaugeInterval)
        } catch {
            // Keep the last good snapshot on screen; only the freshness note changes.
            gaugeError = error.localizedDescription
            if case UsageAPIError.http(429) = error {
                backoff = backoff == 0 ? Self.gaugeInterval : min(backoff * 2, Self.maxBackoff)
            } else {
                backoff = Self.gaugeInterval
            }
            nextGaugeFetch = Date().addingTimeInterval(backoff)
        }
    }

    /// When the gauge will be read again, for the refresh row subtitle.
    var nextGaugeAttempt: Date? { nextGaugeFetch > now ? nextGaugeFetch : nil }

    private func applyLaunchAtLogin() {
        let enabled = SMAppService.mainApp.status == .enabled
        guard launchAtLogin != enabled else { return }
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            // Revert silently; the toggle reflects the real state on next read.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// The fast-jev-compaction Claude Code plugin has no binary; it is "installed" when its
/// plugin cache directory exists.
enum JevDetector {
    static var isInstalled: Bool {
        let dir = ClaudePaths.configDir.appendingPathComponent("plugins/cache/fast-jev-compaction")
        return FileManager.default.fileExists(atPath: dir.path)
    }
}
