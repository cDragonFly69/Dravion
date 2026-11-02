import Foundation

/// What the desktop widget draws, written where the widget can read it.
///
/// The widget runs sandboxed in its own process and cannot reach Pulse's
/// settings, keys or readings. So after every committed reading Pulse writes
/// the **figures already on its own rail** — names, percentages, balances,
/// reset times — to a JSON file in the shared App Group container, and asks
/// WidgetKit to redraw. No key, token or raw reply is ever written there.
///
/// The App Group is Team-prefixed (`<TEAM>.local.api-use.pulse`), which on
/// macOS needs no provisioning profile, only both bundles signed with the
/// same Apple Development identity and carrying the entitlement. The group is
/// read from the `PulseAppGroup` Info.plist key that `Scripts/bundle.sh`
/// writes, so a build without a widget writes nothing.
@MainActor
enum WidgetSnapshotPublisher {
    struct Snapshot: Codable {
        var schemaVersion = 4
        var generatedAt: Date
        var accounts: [Account]
        /// Agents working on this Mac right now, as the rail's spinning mark
        /// shows them, each with when Pulse first saw it working.
        var running: [Running] = []
    }

    struct Running: Codable {
        var provider: String
        var name: String
        var icon: String
        var since: Date
        /// `working`, or `waiting` when the session is stopped on a question
        /// for the user.
        var state = "working"
    }

    struct Account: Codable {
        var id: String
        var name: String
        var provider: String
        /// 0...1 of the headline limit, or nil for a balance-only reading.
        var usedFraction: Double?
        var limitName: String?
        var resetsAt: Date?
        var balance: String?
        var isStale: Bool
        var isExhausted: Bool
        /// Why there is no figure, already in the user's language.
        var message: String?
        /// Every limit the reading carries — a subscription's five-hour and
        /// weekly windows side by side — in the provider's own order.
        var windows: [Window] = []
        var isSubscription = false
        var icon: String = ""
        var isRunning = false
        /// The plan's name — Pro, Max, Plus — where the provider names one.
        var plan: String?
        /// The kind of the headline window — pinned in settings, or the
        /// fullest — which `usedFraction`, `limitName` and `resetsAt` describe.
        var headlineKind: String?
    }

    struct Window: Codable {
        /// `fiveHour`, `weekly`, `daily`, `monthly` or `other`.
        var kind: String
        var name: String
        var usedFraction: Double
        var resetsAt: Date?
        var isExhausted: Bool
    }

    static var appGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "PulseAppGroup") as? String
    }

    static var snapshotURL: URL? {
        guard let appGroup else { return nil }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("snapshot.json")
    }

    private static var pending: Task<Void, Never>?
    private weak static var store: UsageStore?
    private static var settings: AppSettings?
    private static var runningSince: [Provider: Date] = [:]
    private static var waiting: [Provider: Date] = [:]

    /// Starts writing: after every pass (`schedule`), and **at once** whenever
    /// an agent starts or stops working, so the widget's running mark follows
    /// the rail's as closely as WidgetKit allows.
    static func follow(store: UsageStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        observeActivity()
    }

    private static func observeActivity() {
        guard let store else { return }
        let (running, waiting) = withObservationTracking {
            (store.activity.running, store.activity.waitingSince)
        } onChange: {
            Task { @MainActor in observeActivity() }
        }
        let now = Date()
        runningSince = running.reduce(into: [:]) { $0[$1] = runningSince[$1] ?? now }
        self.waiting = waiting
        if let settings { publish(settings: settings, usage: store.usage) }
    }

    private static func kindName(_ kind: UsageWindow.Kind) -> String {
        switch kind {
        case .fiveHour: "fiveHour"
        case .weekly: "weekly"
        case .daily: "daily"
        case .monthly: "monthly"
        default: "other"
        }
    }

    /// Coalesces a pass's worth of commits into one write.
    static func schedule(settings: AppSettings, usage: @escaping @MainActor () -> [String: ProviderUsage]) {
        guard snapshotURL != nil else { return }
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            publish(settings: settings, usage: usage())
        }
    }

    static func publish(settings: AppSettings, usage: [String: ProviderUsage]) {
        guard let url = snapshotURL else { return }
        let accounts = settings.shownAccounts.compactMap { key -> Account? in
            guard let reading = usage[key.id] else { return nil }
            let pinned = settings.pinnedWindows[key.id]
            let headline = reading.headlineWindow(preferring: pinned)
            var message: String?
            var isStale = false
            switch reading.state {
            case .live: break
            case .stale: isStale = true
            case .unavailable(let reason): message = reason.message
            }
            return Account(
                id: key.id,
                name: settings.label(for: key),
                provider: key.provider.rawValue,
                usedFraction: headline?.usedFraction,
                limitName: headline?.name,
                resetsAt: headline?.resetsAt,
                balance: reading.creditBalance,
                isStale: isStale,
                isExhausted: headline?.isExhausted ?? false,
                message: message,
                windows: reading.windows.map { window in
                    Window(
                        kind: Self.kindName(window.kind),
                        name: window.name,
                        usedFraction: window.usedFraction,
                        resetsAt: window.resetsAt,
                        isExhausted: window.isExhausted
                    )
                },
                isSubscription: key.provider.billing == .subscription,
                icon: key.provider.iconResource,
                isRunning: runningSince[key.provider] != nil,
                plan: reading.plan,
                headlineKind: headline.map { Self.kindName($0.kind) }
            )
        }
        let running = waiting.sorted { $0.value < $1.value }.map {
            Running(provider: $0.key.rawValue, name: $0.key.displayName, icon: $0.key.iconResource,
                    since: $0.value, state: "waiting")
        } + runningSince.sorted { $0.value < $1.value }.map {
            Running(provider: $0.key.rawValue, name: $0.key.displayName, icon: $0.key.iconResource, since: $0.value)
        }
        let snapshot = Snapshot(generatedAt: Date(), accounts: accounts, running: running)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
        WidgetReloader.reloadAll()
    }
}
