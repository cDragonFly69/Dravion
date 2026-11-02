import AppKit
import SwiftUI
import WidgetKit

// MARK: - Data written by the app (WidgetSnapshotPublisher / WidgetSpendPublisher)

struct Snapshot: Codable {
    var generatedAt: Date
    var accounts: [Account]
    var running: [Running]?

    struct Account: Codable, Identifiable {
        var id: String
        var name: String
        var provider: String
        var usedFraction: Double?
        var limitName: String?
        var resetsAt: Date?
        var balance: String?
        var isStale: Bool
        var isExhausted: Bool
        var message: String?
        var windows: [Window]?
        var isSubscription: Bool?
        var icon: String?
        var isRunning: Bool?
        var plan: String?
        /// The kind of the headline window — the one the ring is pinned to in
        /// settings, or the fullest when nothing is pinned. `usedFraction`,
        /// `limitName` and `resetsAt` all describe that one window, so this is
        /// what tells it apart from the others: "5h" from "Week".
        var headlineKind: String?
    }

    struct Running: Codable {
        var provider: String
        var name: String
        var icon: String
        var since: Date
        var state: String?

        var isWaiting: Bool { state == "waiting" }
    }

    struct Window: Codable {
        var kind: String
        var name: String
        var usedFraction: Double
        var resetsAt: Date?
        var isExhausted: Bool
    }
}

struct Spend: Codable {
    var generatedAt: Date
    var source: String
    var today: Totals
    var last5h: Totals
    var week: Totals
    var days: [Day]
    var modelsToday: [Model]
    var modelsWeek: [Model]
    /// Everything on record and the models it went to.
    var all: Totals?
    var modelsAll: [Model]?
    var appModels: [String: [Model]]?
    var apps: [AppCost]?

    struct Totals: Codable { var tokens: Int; var requests: Int?; var cost: Double; var cacheHitRate: Double? }
    struct Day: Codable { var date: Date; var tokens: Int }
    struct Model: Codable {
        var name: String; var tokens: Int; var requests: Int?; var cost: Double?; var cacheHitRate: Double?
        /// The part of `tokens` read from the prompt cache.
        var cacheRead: Int?
    }

    /// The model doing most of today's work, or the week's on a quiet day.
    var mainModel: Model? { modelsToday.first ?? modelsWeek.first }
}

struct AppCost: Codable, Identifiable {
    var id: String
    var name: String
    var icon: String
    var currency: String?
    var today: Amount
    var week: Amount
    var month: Amount
    var all: Amount
    var lastRecord: Date?
    var since: Date?
    var models: [Spend.Model]?
    /// The part of `all.tokens` read from the prompt cache.
    var cacheRead: Int?

    struct Amount: Codable { var cost: Double; var tokens: Int }

    /// Whether this tool's records stopped more than a day and a half ago:
    /// the figures are then old, not small.
    var isBehind: Bool { lastRecord.map { $0 < Date().addingTimeInterval(-36 * 3600) } ?? false }
}

struct LocalCosts: Codable {
    var generatedAt: Date
    var agents: [AppCost]
}

/// The newest session of each agent the app reads (`WidgetSessionPublisher`).
struct Sessions: Codable {
    var generatedAt: Date
    var isReading: Bool
    var sessions: [Session]

    struct Session: Codable, Identifiable {
        var id: String
        var name: String?
        var provider: String
        var agent: String
        var icon: String
        var model: String?
        var startedAt: Date?
        var lastActivity: Date
        var state: String
        var stateSince: Date?
        var input: Int
        var cacheWrite: Int
        var cacheRead: Int
        var output: Int
        var total: Int
        var cacheHitRate: Double?
        var tokensPerSecond: Double?

        /// False for an agent that keeps no token count (Doubao).
        var countsTokens: Bool?

        var isWorking: Bool { state == "working" }
        var isWaiting: Bool { state == "waiting" }
        var reportsTokens: Bool { countsTokens != false }
        /// Its tokens, or that the agent does not count them; never a zero
        /// it did not report.
        var tokenText: String { reportsTokens ? tokens(total) : L("No tokens", "不提供 Token") }
        /// The first block of the UUID: enough to tell sessions apart and to
        /// find the one meant with `claude --resume` or `codex resume`.
        var shortID: String { String(id.prefix(8)) }
    }
}

extension Substring {
    var nonEmpty: Substring? { isEmpty ? nil : self }
}

func percent(_ rate: Double?) -> String {
    guard let rate else { return "—" }
    return String(format: "%.1f%%", rate * 100)
}

/// A provider mark from the asset catalog, or a neutral symbol.
struct Mark: View {
    let icon: String?
    var size: CGFloat = 12

    var body: some View {
        if let icon, !icon.isEmpty, NSImage(named: icon) != nil {
            Image(icon).resizable().renderingMode(.template).scaledToFit().frame(width: size, height: size)
        } else {
            Image(systemName: "sparkle").font(.system(size: size * 0.8)).frame(width: size, height: size)
        }
    }
}

/// The closest a widget comes to the rail's spinning mark. WidgetKit runs no
/// animation, and a timer-driven `ProgressView` is not the way round it: its
/// interval is over almost at once and macOS then draws a finished ring with a
/// slash through it, which is what a working agent looked like. So the ring is
/// an open arc that never claims to be complete, and the elapsed time beside
/// it is the part that moves.
struct RunningMark: View {
    let icon: String?
    let since: Date
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(Palette.caution, style: StrokeStyle(lineWidth: max(1.5, size * 0.09), lineCap: .round))
                .rotationEffect(.degrees(-90))
            Mark(icon: icon, size: size * 0.5).foregroundStyle(Palette.caution)
        }
        .frame(width: size, height: size)
    }
}

enum Store {
    static var directory: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PulseAppGroup") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    static func load<T: Decodable>(_ type: T.Type, _ file: String) -> T? {
        guard let url = directory?.appendingPathComponent(file), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }
}

/// Chinese when the system prefers it, English otherwise.
func L(_ en: String, _ zh: String) -> String {
    (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? zh : en
}

/// A token count, short: 万 and 亿 in Chinese, as the app counts them
/// (`TokenCount.short`), K, M and B otherwise.
func tokens(_ value: Int) -> String {
    let v = Double(value)
    if (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") {
        switch v {
        case 100_000_000...: return String(format: v >= 10_000_000_000 ? "%.0f亿" : "%.2f亿", v / 100_000_000)
        case 10_000...: return String(format: v >= 10_000_000 ? "%.0f万" : "%.1f万", v / 10_000)
        default: return "\(value)"
        }
    }
    switch v {
    case 1_000_000_000...: return String(format: "%.2fB", v / 1_000_000_000)
    case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
    case 1_000...: return String(format: "%.1fK", v / 1_000)
    default: return "\(value)"
    }
}

func until(_ date: Date?) -> String? {
    guard let date else { return nil }
    let seconds = date.timeIntervalSinceNow
    guard seconds > 0 else { return L("now", "即将") }
    let hours = Int(seconds) / 3600, minutes = (Int(seconds) % 3600) / 60
    if hours >= 48 { return L("\(hours / 24)d", "\(hours / 24)天") }
    if hours >= 24 { return L("\(hours / 24)d \(hours % 24)h", "\(hours / 24)天\(hours % 24)时") }
    if hours > 0 { return L("\(hours)h \(minutes)m", "\(hours)时\(minutes)分") }
    return L("\(minutes)m", "\(minutes)分")
}

// MARK: - Timeline

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot?
    let spend: Spend?
    var localCosts: LocalCosts? = nil
    var sessions: Sessions? = nil
}

struct Provider: TimelineProvider {
    /// The session widgets' clocks take turns (`SessionClockKind`), so their
    /// timeline holds an entry every `SessionClockKind.interval` seconds.
    var carousel = false

    func placeholder(in context: Context) -> Entry { .preview }

    private func current() -> Entry {
        Entry(date: Date(), snapshot: Store.load(Snapshot.self, "snapshot.json"),
              spend: Store.load(Spend.self, "spend.json"),
              localCosts: Store.load(LocalCosts.self, "local-costs.json"),
              sessions: Store.load(Sessions.self, "sessions.json"))
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        let entry = current()
        completion(context.isPreview && entry.snapshot == nil ? .preview : entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // The app asks for a reload whenever it writes; this is only the
        // fallback so reset countdowns keep moving while it is quiet.
        let entry = current(), end = Date().addingTimeInterval(10 * 60)
        guard carousel, entry.sessions?.sessions.isEmpty == false else {
            completion(Timeline(entries: [entry], policy: .after(end)))
            return
        }
        // Entries on the turns' boundaries, so every clock changes together,
        // for one minute only. WidgetKit draws every entry ahead of time, each
        // through all its `ViewThatFits` rungs: ten minutes of turns took the
        // extension 16 s at full CPU, past the system's limit, and the widget
        // was left blank. The app reloads on every change it writes anyway.
        let step = SessionClockKind.interval, until = entry.date.addingTimeInterval(SessionClockKind.ahead)
        let first = (entry.date.timeIntervalSince1970 / step).rounded(.up) * step
        let turns = stride(from: first, to: until.timeIntervalSince1970, by: step).map {
            Entry(date: Date(timeIntervalSince1970: $0), snapshot: entry.snapshot, spend: entry.spend,
                  localCosts: entry.localCosts, sessions: entry.sessions)
        }
        completion(Timeline(entries: [entry] + turns, policy: .after(until)))
    }
}

// MARK: - Pieces

/// DragonFly API's colours: its ember for the brand and for activity, and
/// the system's green, amber and red for how full a limit is, which read the
/// same on a light or a dark desktop.
enum Palette {
    static let ember = Color(red: 1.0, green: 0.478, blue: 0.239)       // #FF7A3D
    static let emberDeep = Color(red: 0.898, green: 0.188, blue: 0.310) // #E5304F
    static let good = Color(red: 0.204, green: 0.780, blue: 0.349)      // #34C759
    static let caution = Color(red: 1.0, green: 0.624, blue: 0.039)     // #FF9F0A
    static let critical = Color(red: 1.0, green: 0.271, blue: 0.227)    // #FF453A
    static let track = Color.primary.opacity(0.09)
    static let empty = Color.primary.opacity(0.07)
}

func usageTint(_ fraction: Double?, exhausted: Bool = false) -> Color {
    if exhausted { return Palette.critical }
    guard let fraction else { return Palette.ember }
    switch fraction {
    case ..<0.6: return Palette.good
    case ..<0.85: return Palette.caution
    default: return Palette.critical
    }
}

extension Snapshot.Account {
    var hasFigure: Bool { message == nil && (usedFraction != nil || balance != nil) }

    var urgency: Double { message != nil ? -1 : (usedFraction ?? -0.5) }

    var shortName: String { name.replacingOccurrences(of: " · Claude Code", with: "").replacingOccurrences(of: " · Codex", with: "") }

    /// The name without the account after it — "Claude Code", not "Claude
    /// Code · max@example.com" — for a strip where the mark and the figures
    /// are what is read.
    var productName: String {
        name.components(separatedBy: " · ").first ?? name
    }

    /// The one window the app is showing for this account — the ring's pin, or
    /// the fullest limit when nothing is pinned. The reading already carries it
    /// split into `usedFraction`, `limitName` and `resetsAt`; this puts it back
    /// together so the same names and formatting serve every widget.
    ///
    /// An account that is not a subscription and holds money has no headline:
    /// its ring is a balance (`BalanceRing`), and the money is the reading.
    var headline: Snapshot.Window? {
        guard let usedFraction, isSubscription == true || balance == nil else { return nil }
        return Snapshot.Window(kind: headlineKind ?? "", name: limitName ?? "",
                               usedFraction: usedFraction, resetsAt: resetsAt, isExhausted: isExhausted)
    }

    /// A subscription whose window is worth a bar: it has a limit that resets.
    var isTicking: Bool { isSubscription == true && usedFraction != nil }
}

struct Bar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(color).frame(width: max(3, proxy.size.width * min(fraction, 1)))
            }
        }
        .frame(height: 5)
    }
}

/// What a limit is called in the little space beside its bar.
func windowName(_ window: Snapshot.Window) -> String {
    switch window.kind {
    case "fiveHour": return "5h"
    case "weekly": return L("Week", "周")
    case "daily": return L("Day", "日")
    case "monthly": return L("Month", "月")
    default:
        let name = window.name.replacingOccurrences(of: " ", with: "")
        if name.localizedCaseInsensitiveContains("balance") || name.contains("余额") { return L("Left", "余额") }
        // "30 天" / "30-day" → "30天" / "30d": the length is the useful part.
        if let days = name.prefix(while: \.isNumber).nonEmpty { return L("\(days)d", "\(days)天") }
        return String(name.prefix(3))
    }
}

func percentText(_ window: Snapshot.Window) -> String {
    "\(Int((window.usedFraction * 100).rounded()))%"
}

func resetText(_ window: Snapshot.Window) -> String? {
    until(window.resetsAt).map { "↻\($0)" }
}

/// The windows an account's lines show: the five-hour and the weekly limit
/// (or whatever two it has, shortest first), each as **how much is used**
/// and when it turns over. An account that holds money and is not a subscription
/// shows no window: its money is the reading.
func shownWindows(_ account: Snapshot.Account) -> [Snapshot.Window] {
    guard account.message == nil, account.isSubscription == true || account.balance == nil else { return [] }
    let order = ["fiveHour": 0, "daily": 1, "weekly": 2, "monthly": 3]
    let windows = (account.windows ?? []).isEmpty ? account.headline.map { [$0] } ?? [] : account.windows ?? []
    return Array(windows.enumerated()
        .sorted { (order[$0.element.kind] ?? 4, $0.offset) < (order[$1.element.kind] ?? 4, $1.offset) }
        .map(\.element).prefix(2))
}

func usedText(_ window: Snapshot.Window) -> String {
    L("\(Int((window.usedFraction * 100).rounded()))% used", "已用\(Int((window.usedFraction * 100).rounded()))%")
}

/// One account in a medium frame: its name, then each window — the five-hour
/// and the weekly — as how much is used and when it resets, side by side. Parts
/// give way in order: the plan badge, the resets, the second window; the
/// name is the flexible part and is cut last.
struct QuotaRow: View {
    let account: Snapshot.Account

    static let height: CGFloat = 17

    var body: some View {
        let windows = shownWindows(account)
        ViewThatFits(in: .horizontal) {
            line(windows, badge: true, reset: true)
            line(windows, badge: false, reset: true)
            line(Array(windows.prefix(2)), badge: false, reset: false)
            line(Array(windows.prefix(1)), badge: false, reset: true)
            line(Array(windows.prefix(1)), badge: false, reset: false)
        }
        .frame(height: Self.height)
    }

    private func line(_ windows: [Snapshot.Window], badge: Bool, reset: Bool) -> some View {
        HStack(spacing: 5) {
            Mark(icon: account.icon, size: 10).foregroundStyle(.secondary)
            Text(account.shortName).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                .layoutPriority(-1)
            if badge, let plan = account.plan { PlanBadge(text: plan).fixedSize() }
            Spacer(minLength: 4)
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                WindowFigure(window: window, reset: reset)
            }
            if let balance = account.balance {
                if !windows.isEmpty { Text(L("Left", "余额")).font(.system(size: 9)).foregroundStyle(.secondary).fixedSize() }
                Text(balance).font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit().fixedSize()
            } else if windows.isEmpty, let message = account.message {
                Text(message).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// "5h 已用50% ↻2时25分" — one window, compact, never cut.
struct WindowFigure: View {
    let window: Snapshot.Window
    var reset = true

    var body: some View {
        HStack(spacing: 3) {
            Text(windowName(window)).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(usedText(window)).font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(usageTint(window.usedFraction, exhausted: window.isExhausted))
            if reset, let text = resetText(window) {
                Text(text).font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .fixedSize()
        .padding(.leading, 3)
    }
}

/// An account on several lines: its name, then one line per window across
/// the full width — label, a bar of what is used, the share used and the
/// reset. Used where there is height to spare: small and large frames.
struct QuotaStack: View {
    let account: Snapshot.Account
    /// A large frame draws the same lines taller and larger.
    var roomy = false

    private var lineHeight: CGFloat { roomy ? 17 : 14 }
    private var nameHeight: CGFloat { roomy ? 18 : 15 }
    var height: CGFloat { nameHeight + CGFloat(shownWindows(account).count) * lineHeight + 3 }

    var body: some View {
        let windows = shownWindows(account)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Mark(icon: account.icon, size: roomy ? 12 : 10).foregroundStyle(.secondary)
                Text(account.shortName).font(.system(size: roomy ? 12 : 10, weight: .semibold)).lineLimit(1)
                if let plan = account.plan { PlanBadge(text: plan) }
                Spacer(minLength: 2)
                if let balance = account.balance {
                    if !windows.isEmpty {
                        Text(L("Left", "余额")).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Text(balance).font(.system(size: roomy ? 12 : 10, weight: .bold, design: .rounded))
                        .monospacedDigit().lineLimit(1).fixedSize()
                }
            }
            .frame(height: nameHeight)
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                let tint = usageTint(window.usedFraction, exhausted: window.isExhausted)
                HStack(spacing: 4) {
                    Text(windowName(window)).font(.system(size: roomy ? 10 : 9, weight: .semibold))
                        .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width: roomy ? 30 : 26, alignment: .leading)
                    Bar(fraction: window.usedFraction, color: tint).frame(minWidth: 12)
                    Text(usedText(window)).font(.system(size: roomy ? 12 : 10, weight: .bold, design: .rounded))
                        .monospacedDigit().foregroundStyle(tint).lineLimit(1).fixedSize()
                        .frame(minWidth: roomy ? 44 : nil, alignment: .trailing)
                    Text(resetText(window) ?? "—").font(.system(size: roomy ? 10 : 9)).foregroundStyle(.secondary)
                        .monospacedDigit().lineLimit(1).fixedSize()
                        .frame(minWidth: roomy ? 56 : 48, alignment: .trailing)
                }
                .frame(height: lineHeight)
            }
        }
        .frame(height: height, alignment: .top)
    }
}

/// The subscriptions' figures on one line, for the top of Token Activity:
/// the account, how much of its window is gone and when that window turns
/// over. Accounts are dropped first, then the name, and the reset last: the
/// percentage and its countdown are the two figures this strip is for, and a
/// countdown that is cut is worse than fewer accounts.
struct QuotaStrip: View {
    /// Every account with a window that resets, fullest first.
    let accounts: [Snapshot.Account]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(accounts, name: true, reset: true)
            line(Array(accounts.prefix(3)), name: true, reset: true)
            line(Array(accounts.prefix(3)), name: false, reset: true)
            line(Array(accounts.prefix(2)), name: true, reset: true)
            line(Array(accounts.prefix(2)), name: false, reset: true)
            line(Array(accounts.prefix(1)), name: true, reset: true)
            line(Array(accounts.prefix(1)), name: false, reset: true)
            line(Array(accounts.prefix(1)), name: false, reset: false)
        }
        .frame(height: 13, alignment: .leading)
    }

    private func line(_ accounts: [Snapshot.Account], name: Bool, reset: Bool) -> some View {
        HStack(spacing: 9) {
            ForEach(accounts) { account in
                HStack(spacing: 3) {
                    Mark(icon: account.icon, size: 9).foregroundStyle(.secondary)
                    if name {
                        Text(account.productName).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let headline = account.headline {
                        Text(percentText(headline)).font(.system(size: 9, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(usageTint(headline.usedFraction, exhausted: headline.isExhausted))
                        if reset, let text = resetText(headline) {
                            Text(text).font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

/// One tool's part of every token on record — Codex, Claude Code, WorkBuddy,
/// DeepSeek Harness… — with the models it used, biggest first.
struct ToolShare: Identifiable {
    let name: String
    let icon: String
    let tokens: Int
    let models: [(name: String, tokens: Int)]
    let color: Color
    var id: String { name }
}

/// Every token on record, tool by tool.
///
/// **CC Switch's records first, then the agents it does not see.** CC Switch
/// counts what goes through it — Claude Code, Codex, Gemini CLI, OpenCode —
/// and Pulse reads every agent's own logs. The two count the same requests
/// for the tools they share, so a tool CC Switch has records for is taken
/// from CC Switch alone, and only agents it has nothing for (WorkBuddy,
/// DeepSeek Harness, Copilot…) are added from Pulse's reading. The total is
/// the tools added up, so the lines always make the figure above them.
///
/// **Cache reads are counted apart.** Every request reads its whole cached
/// context again, so cache reads were nine tokens in ten of the old total —
/// the same context counted once per request, not work. The total and every
/// tool and model line are new input, output and cache writes; the cache
/// reads are one figure beside them.
struct UsageTotal {
    var tools: [ToolShare] = []
    var cacheRead = 0
    var tokens: Int { tools.reduce(0) { $0 + $1.tokens } }

    /// CC Switch's `app_type` → the agent Pulse reads the same tool as.
    static let ccSwitchAgents = ["claude": "claudeCode", "codex": "codex", "gemini": "gemini", "opencode": "openCode"]

    static func color(_ id: String, index: Int) -> Color {
        switch id {
        case "claude", "claudeCode": Color(red: 0.851, green: 0.467, blue: 0.341)    // #D97757
        case "codex": Color(red: 0.063, green: 0.639, blue: 0.498)                     // #10A37F
        case "workBuddy", "codeBuddy": Color(red: 0.0, green: 0.580, blue: 0.976)      // #0094F9
        case "dsh": Color(red: 0.302, green: 0.420, blue: 0.996)                        // #4D6BFE
        case "gemini": Color(red: 0.557, green: 0.459, blue: 0.698)                     // #8E75B2
        default: [Color(red: 0.902, green: 0.224, blue: 0.396), Color(red: 1.0, green: 0.624, blue: 0.039),
                  Color(red: 0.384, green: 0.286, blue: 0.890), Color.primary.opacity(0.45)][index % 4]
        }
    }

    static func of(_ entry: Entry) -> UsageTotal? {
        var tools: [(id: String, name: String, icon: String, tokens: Int, models: [(name: String, tokens: Int)])] = []
        var cacheRead = 0
        let local = entry.localCosts?.agents ?? []
        /// Each model's tokens without its cache reads, biggest first.
        func models(_ list: [Spend.Model]?) -> [(name: String, tokens: Int)] {
            (list ?? []).map { ($0.name, $0.tokens - ($0.cacheRead ?? 0)) }
                .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        }
        func addLocal(_ agent: AppCost) {
            let read = agent.cacheRead ?? 0
            let tokens = agent.all.tokens - read
            guard tokens > 0 else { return }
            cacheRead += read
            tools.append((agent.id, agent.name, agent.icon, tokens, models(agent.models)))
        }
        if let spend = entry.spend, spend.source == "ccSwitch" {
            var covered: Set<String> = []
            let apps = Dictionary((spend.apps ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (app, list) in spend.appModels ?? [:] {
                let lines = models(list)
                let tokens = lines.reduce(0) { $0 + $1.tokens }
                guard tokens > 0 else { continue }
                if let agent = ccSwitchAgents[app] { covered.insert(agent) }
                cacheRead += list.reduce(0) { $0 + ($1.cacheRead ?? 0) }
                tools.append((app, apps[app]?.name ?? app, apps[app]?.icon ?? "ccswitch", tokens, lines))
            }
            for agent in local where !covered.contains(agent.id) { addLocal(agent) }
        } else {
            for agent in local { addLocal(agent) }
        }
        let shares = tools.sorted { $0.tokens > $1.tokens }.enumerated().map { index, tool in
            ToolShare(name: tool.name, icon: tool.icon, tokens: tool.tokens, models: tool.models,
                      color: color(tool.id, index: index))
        }
        let total = UsageTotal(tools: shares, cacheRead: cacheRead)
        return total.tokens > 0 ? total : nil
    }
}

func totalTokens(_ entry: Entry) -> Int? { UsageTotal.of(entry)?.tokens }

/// The bottom of AI Quota: every token on record, and the tools and models
/// it went to, all as amounts. `.compact` is the total alone; `.legend` puts
/// every tool and its amount beside the total; `.list` gives each tool a line
/// with its total and the next line its models.
///
/// **Every tool with tokens is named**, never folded into an "other" share:
/// when room runs short the smaller tools give up their line of models
/// first, not their name and amount.
struct TotalsFooter: View {
    enum Style { case compact, legend, list }

    let entry: Entry
    let style: Style
    var roomy = false
    /// How many of the biggest tools `.list` gives a line of models to.
    var limit = 99

    var body: some View {
        if let usage = UsageTotal.of(entry) {
            if style == .legend {
                // The total on the left, every tool and its amount beside it.
                VStack(alignment: .leading, spacing: 5) {
                    Rule()
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(L("Total tokens", "累计 Token")).font(.system(size: 9)).foregroundStyle(.secondary)
                                .fixedSize()
                            Text(tokens(usage.tokens)).font(.system(size: 15, weight: .bold, design: .rounded))
                                .monospacedDigit().lineLimit(1).fixedSize()
                            cacheLine(usage)
                        }
                        legend(usage.tools)
                        Spacer(minLength: 0)
                    }
                }
            } else {
            VStack(alignment: .leading, spacing: roomy ? 5 : 4) {
                Rule()
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(L("Total tokens", "累计 Token")).font(.system(size: roomy ? 10 : 9)).foregroundStyle(.secondary)
                    Text(tokens(usage.tokens)).font(.system(size: roomy ? 16 : 13, weight: .bold, design: .rounded))
                        .monospacedDigit().lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                    if style == .list { cacheLine(usage) }
                }
                if style == .compact { cacheLine(usage) }
                switch style {
                case .compact:
                    // No room to name the tools, and an unnamed bar says
                    // nothing: the total stands alone.
                    EmptyView()
                case .legend:
                    EmptyView()
                case .list:
                    ForEach(Array(usage.tools.enumerated()), id: \.offset) { index, tool in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Circle().fill(tool.color).frame(width: 6, height: 6)
                                Mark(icon: tool.icon, size: 10).foregroundStyle(.secondary)
                                Text(tool.name).font(.system(size: roomy ? 11 : 10, weight: .semibold)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(tokens(tool.tokens)).font(.system(size: roomy ? 11 : 10, weight: .bold))
                                    .monospacedDigit()
                            }
                            .frame(height: 14)
                            if index < limit, !tool.models.isEmpty {
                                ViewThatFits(in: .horizontal) {
                                    models(tool, count: 3)
                                    models(tool, count: 2)
                                    models(tool, count: 1)
                                }
                                .padding(.leading, 11)
                                .frame(height: 12, alignment: .leading)
                            }
                        }
                    }
                }
            }
            }
        }
    }

    /// The cache reads, named, beside the total they are not part of.
    @ViewBuilder private func cacheLine(_ usage: UsageTotal) -> some View {
        if usage.cacheRead > 0 {
            Text(L("cache reads ", "缓存读取另计 ") + tokens(usage.cacheRead))
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
    }

    /// "deepseek-v4.1-flash 1.10B · hy4-preview 65.1M" — a tool's models.
    private func models(_ tool: ToolShare, count: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(tool.models.prefix(count).enumerated()), id: \.offset) { _, model in
                HStack(spacing: 3) {
                    Text(model.name).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    Text(tokens(model.tokens)).font(.system(size: 9, weight: .semibold)).monospacedDigit().fixedSize()
                }
            }
        }
    }

    /// Every tool with its amount: on one line where they fit, otherwise
    /// split over two, then three.
    private func legend(_ tools: [ToolShare]) -> some View {
        ViewThatFits(in: .horizontal) {
            grid(tools, columns: 3)
            grid(tools, columns: 2)
        }
    }

    /// The tools in rows of `columns`, each column as wide as its widest.
    private func grid(_ tools: [ToolShare], columns: Int) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 7, verticalSpacing: 2) {
            ForEach(Array(stride(from: 0, to: tools.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(tools[start..<min(start + columns, tools.count)]) { tool in
                        HStack(spacing: 3) {
                            Circle().fill(tool.color).frame(width: 5, height: 5)
                            Text(tool.name).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                            Text(tokens(tool.tokens)).font(.system(size: 9, weight: .semibold)).monospacedDigit()
                                .fixedSize()
                        }
                        .frame(height: 12)
                    }
                }
            }
        }
    }

    private func legendLine(_ tools: [ToolShare]) -> some View {
        HStack(spacing: 8) {
            ForEach(tools) { tool in
                HStack(spacing: 3) {
                    Circle().fill(tool.color).frame(width: 5, height: 5)
                    Text(tool.name).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    Text(tokens(tool.tokens)).font(.system(size: 9, weight: .semibold)).monospacedDigit().fixedSize()
                }
            }
        }
    }
}

/// A hairline between two regions of a widget.
struct Rule: View {
    var body: some View {
        Rectangle().fill(Palette.track).frame(height: 1)
    }
}

/// Days as a GitHub-style grid: one column per week, Monday on top.
///
/// The cell size comes from the height it is given and the grid takes as many
/// weeks as the width holds, so a wide widget shows more history instead of a
/// wider margin beside a narrow grid.
struct Heatmap: View {
    let days: [Spend.Day]
    /// Fixed when the caller wants a particular density; otherwise the width
    /// decides, which is what fills a column.
    var weeks: Int? = nil

    private static let gap: CGFloat = 2

    private func grid(weeks: Int) -> [[Spend.Day?]] {
        guard weeks > 0 else { return [] }
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let recent = Array(days.suffix(weeks * 7 + 6))
        guard let last = recent.last else { return [] }
        let lastWeekday = (calendar.component(.weekday, from: last.date) + 5) % 7  // Monday = 0
        var cells: [Spend.Day?] = recent
        cells.append(contentsOf: Array(repeating: nil, count: 6 - lastWeekday))
        cells = Array(cells.suffix(weeks * 7))
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
    }

    private var cuts: [Int] {
        let active = days.map(\.tokens).filter { $0 > 0 }.sorted()
        guard !active.isEmpty else { return [1, 1, 1] }
        return [0.25, 0.5, 0.75].map { active[min(active.count - 1, Int(Double(active.count) * $0))] }
    }

    private func color(_ day: Spend.Day?) -> Color {
        guard let day else { return .clear }
        guard day.tokens > 0 else { return Palette.empty }
        let step = cuts.filter { day.tokens > $0 }.count
        return Palette.ember.opacity([0.28, 0.5, 0.74, 1.0][step])
    }

    /// A cell as tall as seven of them allow, then as many weeks as the width
    /// takes at that size.
    private func plan(in space: CGSize) -> (size: CGFloat, columns: [[Spend.Day?]]) {
        let gap = Self.gap
        var size = max(3, (space.height - gap * 6) / 7)
        let available = days.count / 7 + 1
        var count = min(available, max(1, Int((space.width + gap) / (size + gap))))
        if let weeks { count = min(count, weeks) }
        if count == 1 { size = min(size, space.width) }
        return (size, grid(weeks: count))
    }

    var body: some View {
        GeometryReader { proxy in
            let plan = plan(in: proxy.size)
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(Array(plan.columns.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: Self.gap) {
                        ForEach(0..<7, id: \.self) { row in
                            RoundedRectangle(cornerRadius: plan.size * 0.25)
                                .fill(color(row < week.count ? week[row] : nil))
                                .frame(width: plan.size, height: plan.size)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct Stat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
    }
}

struct SpendStats: View {
    let spend: Spend

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Stat(title: L("Today", "今日 Token"), value: tokens(spend.today.tokens))
                Stat(title: L("Last 5h", "近 5 小时"), value: tokens(spend.last5h.tokens))
                Stat(title: L("7 days", "近 7 天"), value: tokens(spend.week.tokens))
                Stat(title: L("Cache hit", "缓存命中"), value: percent(spend.today.cacheHitRate))
                Stat(title: L("Today cost", "今日花费"), value: String(format: "$%.2f", spend.today.cost))
            }
            if let main = spend.mainModel {
                HStack(spacing: 4) {
                    Text(L("Main model", "主力模型")).font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(main.name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 2)
                    if let requests = spend.today.requests {
                        Text(L("\(requests) req", "\(requests) 次请求")).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Text(L("7d hit ", "7 天命中 ") + percent(spend.week.cacheHitRate)).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ModelList: View {
    let models: [Spend.Model]
    let limit: Int

    var body: some View {
        let shown = Array(models.prefix(limit))
        let top = Double(shown.first?.tokens ?? 1)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, model in
                HStack(spacing: 5) {
                    Text(model.name).font(.system(size: 10)).lineLimit(1).frame(width: 110, alignment: .leading)
                    Bar(fraction: Double(model.tokens) / max(top, 1), color: .blue.opacity(0.75))
                    Text(tokens(model.tokens)).font(.system(size: 10, weight: .semibold)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    Text(percent(model.cacheHitRate)).font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
        }
    }
}

struct PlanBadge: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 8, weight: .bold)).lineLimit(1)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Capsule().fill(Palette.ember.opacity(0.16)))
            .foregroundStyle(Palette.ember)
    }
}

/// DragonFly API's orange D, beside every widget's title, in its own colours
/// even when the desktop draws widgets tinted.
struct BrandMark: View {
    var size: CGFloat = 14

    var body: some View {
        Group {
            if NSImage(named: "brand") != nil {
                if #available(macOS 15.0, *) {
                    Image("brand").resizable().widgetAccentedRenderingMode(.fullColor)
                } else {
                    Image("brand").resizable()
                }
            } else {
                // Drawn outside the bundle (`widget-render.sh`): the letter.
                Text("D").font(.system(size: size * 0.7, weight: .heavy, design: .rounded))
                    .foregroundStyle(Palette.ember)
                    .frame(width: size, height: size)
                    .background(Color(red: 0.12, green: 0.11, blue: 0.13))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

struct Header: View {
    let title: String
    let date: Date?

    var body: some View {
        HStack(spacing: 5) {
            BrandMark()
            Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
            Spacer()
            if let date { Text(date, style: .time).font(.system(size: 9)).foregroundStyle(.tertiary) }
        }
    }
}

struct Hint: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

let needsApp = L("Open DragonFly API to start", "打开 DragonFly API 后显示额度")
let needsSpend = L("Waiting for CC Switch or Token spend records", "等待 CC Switch 或 Token 消耗记录")

func since(_ entry: Entry, _ account: Snapshot.Account) -> Date? {
    entry.snapshot?.running?.first { $0.provider == account.provider }?.since
}

func sortedAccounts(_ entry: Entry) -> [Snapshot.Account] {
    (entry.snapshot?.accounts ?? []).filter(\.hasFigure).sorted { $0.urgency > $1.urgency }
}

/// Subscriptions first (they have the 5h and weekly windows), then balances.
func quotaAccounts(_ entry: Entry) -> [Snapshot.Account] {
    let all = sortedAccounts(entry)
    return all.filter { $0.isSubscription == true && !($0.windows ?? []).isEmpty }
        + all.filter { !($0.isSubscription == true && !($0.windows ?? []).isEmpty) }
}

// MARK: - Widgets

/// Quota: one line per account — the window the app is showing for it, how
/// much of it is gone and when it turns over; or, for an account that holds
/// money rather than a limit, what is left. Then every token the records hold,
/// added up, as the one figure the widget exists to put beside those.
///
/// Nothing else: no second window, no spending table, no balance list. Those
/// are what made the old overview need a dozen rungs and still overflow.
struct QuotaView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    /// Set only when the view is drawn outside WidgetKit, which cannot be told
    /// a family: `Scripts/widget-render.sh` passes each size to check the
    /// layout. The widget itself leaves it nil.
    var familyOverride: WidgetFamily?
    let entry: Entry

    private var family: WidgetFamily { familyOverride ?? widgetFamily }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let accounts = quotaAccounts(entry)
            if accounts.isEmpty {
                Hint(text: needsApp)
            } else if family == .systemSmall {
                ViewThatFits(in: .vertical) {
                    stack(accounts, limit: 3)
                    stack(accounts, limit: 2)
                    stack(accounts, limit: 1)
                }
            } else if family == .systemLarge {
                ViewThatFits(in: .vertical) {
                    stack(accounts, limit: 6, roomy: true, footer: .list)
                    stack(accounts, limit: 5, roomy: true, footer: .list)
                    stack(accounts, limit: 4, roomy: true, footer: .list)
                    stack(accounts, limit: 4, roomy: true, footer: .list, tools: 4)
                    stack(accounts, limit: 4, roomy: true, footer: .list, tools: 3)
                    stack(accounts, limit: 3, roomy: true, footer: .list, tools: 3)
                    stack(accounts, limit: 3, roomy: true, footer: .list, tools: 2)
                    stack(accounts, limit: 3, roomy: true, footer: .list, tools: 0)
                    stack(accounts, limit: 6, roomy: true, footer: .legend)
                    stack(accounts, limit: 5, roomy: true, footer: .legend)
                    stack(accounts, limit: 4, roomy: true, footer: .legend)
                    stack(accounts, limit: 3, roomy: true, footer: .legend)
                }
            } else {
                ViewThatFits(in: .vertical) {
                    table(accounts, limit: 6)
                    table(accounts, limit: 5)
                    table(accounts, limit: 4)
                    table(accounts, limit: 3)
                    table(accounts, limit: 4, footer: .compact)
                    table(accounts, limit: 3, footer: .compact)
                    table(accounts, limit: 2, footer: .compact)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func stack(_ accounts: [Snapshot.Account], limit: Int, roomy: Bool = false,
                       footer: TotalsFooter.Style = .compact, tools: Int = 99) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: L("Quota", "额度"), date: entry.snapshot?.generatedAt)
                .padding(.bottom, roomy ? 7 : 5)
            ForEach(accounts.prefix(limit)) { QuotaStack(account: $0, roomy: roomy) }
            TotalsFooter(entry: entry, style: footer, roomy: roomy, limit: tools).padding(.top, roomy ? 8 : 5)
        }
    }

    private func table(_ accounts: [Snapshot.Account], limit: Int,
                       roomy: Bool = false, footer: TotalsFooter.Style = .legend) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: L("Quota", "额度"), date: entry.snapshot?.generatedAt)
                .padding(.bottom, roomy ? 6 : 4)
            ForEach(accounts.prefix(limit)) { QuotaRow(account: $0) }
            TotalsFooter(entry: entry, style: footer, roomy: roomy).padding(.top, roomy ? 7 : 5)
        }
    }
}

struct ActivityView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    var familyOverride: WidgetFamily?
    let entry: Entry

    private var family: WidgetFamily { familyOverride ?? widgetFamily }

    /// Subscriptions with a window that resets, fullest first: the figures that
    /// go above the running banner.
    private var ticking: [Snapshot.Account] { quotaAccounts(entry).filter(\.isTicking) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let spend = entry.spend {
                if family == .systemSmall {
                    VStack(alignment: .leading, spacing: 5) {
                        Header(title: L("Tokens today", "今日 Token"), date: nil)
                        Text(tokens(spend.today.tokens)).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                        if !ticking.isEmpty { QuotaStrip(accounts: ticking) }
                        Text(L("Hit ", "命中 ") + percent(spend.today.cacheHitRate) + " · " + (spend.mainModel?.name ?? "")).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        Heatmap(days: spend.days)
                    }
                } else {
                    // The limits and what is running are what this widget is
                    // glanced at for, so a rung gives up the models, then the
                    // heatmap, and keeps those two to the last.
                    ViewThatFits(in: .vertical) {
                        activity(spend, heatmap: 92, models: (6, 4))
                        activity(spend, heatmap: 72, models: (5, 0))
                        activity(spend, heatmap: 56, models: (3, 0))
                        activity(spend, heatmap: 56, models: (0, 0))
                        activity(spend, heatmap: 44, models: (0, 0))
                        activity(spend, heatmap: 28, models: (0, 0))
                        activity(spend, heatmap: 0, models: (0, 0))
                    }
                }
            } else {
                Hint(text: needsSpend)
            }
        }
        // Top-aligned like AI Quota, so the two titles sit on one line when
        // the widgets are placed side by side.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func activity(_ spend: Spend, heatmap: CGFloat, models: (today: Int, week: Int)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Header(title: L("Token activity", "Token 活动") + (spend.source == "ccSwitch" ? " · CC Switch" : ""), date: spend.generatedAt)
            // Each subscription's limit: how much is gone and when it turns
            // over. What is running is the Session Status widget's.
            if !ticking.isEmpty { QuotaStrip(accounts: ticking) }
            SpendStats(spend: spend)
            if heatmap > 0 {
                Heatmap(days: spend.days).frame(height: heatmap)
            }
            if models.today > 0 {
                Text(L("Models today", "今日模型用量")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ModelList(models: spend.modelsToday.isEmpty ? spend.modelsWeek : spend.modelsToday, limit: models.today)
            }
            if models.week > 0 {
                Text(L("Models, 7 days", "近 7 天模型用量")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ModelList(models: spend.modelsWeek, limit: models.week)
            }
        }
    }
}

/// Session Status: every open or recent session, a row each, working and
/// waiting first. Extra large lays them out in two columns.
struct SessionStatusView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    var familyOverride: WidgetFamily?
    let entry: Entry

    private var family: WidgetFamily { familyOverride ?? widgetFamily }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let sessions = entry.sessions?.sessions, !sessions.isEmpty {
                let columns = family == .systemExtraLarge ? 2 : 1
                ViewThatFits(in: .vertical) {
                    ForEach(Array(stride(from: min(sessions.count, 12 * columns), through: 1, by: -columns)), id: \.self) { count in
                        list(sessions, count: count, columns: columns)
                    }
                }
            } else if entry.sessions?.isReading == false {
                Hint(text: L("Turn on Settings → Token spend in DragonFly API to read sessions",
                             "在 DragonFly API 的设置 → Token 消耗中开启读取后显示会话"))
            } else {
                Hint(text: L("No session in the last three hours", "最近三小时没有会话"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func list(_ sessions: [Sessions.Session], count: Int, columns: Int) -> some View {
        let compact = family == .systemSmall
        let shown = Array(sessions.prefix(count))
        return VStack(alignment: .leading, spacing: compact ? 5 : 6) {
            SessionsHeader(title: L("Sessions", "会话状态"), sessions: sessions, compact: compact)
            if columns > 1 {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(0..<columns, id: \.self) { column in
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(stride(from: column, to: shown.count, by: columns)), id: \.self) { index in
                                SessionRow(session: shown[index])
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            } else {
                ForEach(shown) { SessionRow(session: $0, compact: compact) }
            }
            if sessions.count > count {
                Text(L("+\(sessions.count - count) more", "另有 \(sessions.count - count) 个会话"))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}

/// The brand, the widget's title, and how many sessions are running, waiting
/// and listed in all.
struct SessionsHeader: View {
    let title: String
    let sessions: [Sessions.Session]
    var compact = false

    var body: some View {
        let working = sessions.filter(\.isWorking).count, waiting = sessions.filter(\.isWaiting).count
        HStack(spacing: 5) {
            BrandMark()
            Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            if working > 0 {
                Text(L("\(working) running", "运行中 \(working)")).font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.caution).lineLimit(1)
            }
            if waiting > 0 {
                Text(L("\(waiting) waiting", "等你确认 \(waiting)")).font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.yellow).lineLimit(1)
            }
            if !compact {
                Text(L("\(sessions.count) in all", "共 \(sessions.count)")).font(.system(size: 9))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// Working, waiting for the user, or idle, as a coloured word.
struct SessionState: View {
    let session: Sessions.Session

    var body: some View {
        let (text, color): (String, Color) = session.isWaiting ? (L("Needs you", "等你确认"), .yellow)
            : session.isWorking ? (L("Running", "运行中"), Palette.caution)
            : (L("Idle", "空闲"), .secondary)
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Capsule().fill(color.opacity(0.14)))
        .fixedSize()
    }
}

func speed(_ value: Double?) -> String {
    guard let value else { return "—" }
    return String(format: value >= 100 ? "%.0f" : "%.1f", value)
}

/// A session's name sits in a column this wide, so the ids after it line up
/// down the list whatever the names' lengths; a longer name is cut short.
/// It gives way only when the line has no room left for it.
struct SessionName: View {
    let session: Sessions.Session
    var size: CGFloat
    var width: CGFloat

    var body: some View {
        Text(session.name ?? session.agent).font(.system(size: size, weight: .semibold)).lineLimit(1)
            .frame(minWidth: 40, maxWidth: width, alignment: .leading)
            .layoutPriority(1)
    }
}

/// One session on two lines: who and in what state, then what it has spent.
struct SessionRow: View {
    let session: Sessions.Session
    var compact = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            mark
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if compact {
                        Text(session.name ?? session.agent).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    } else {
                        // Room for the id, the widest state and the longest clock.
                        SessionName(session: session, size: 10, width: 108)
                        Text(session.shortID).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    Spacer(minLength: 2)
                    // Small has no room for both beside the name; the ring
                    // already tells the state by its colour.
                    if !compact { SessionState(session: session) }
                    SessionClock(session: session, size: 9, weight: .regular).lineLimit(1).layoutPriority(2)
                        .foregroundStyle(session.isWaiting ? .yellow : session.isWorking ? Palette.caution : .secondary)
                }
                ViewThatFits(in: .horizontal) {
                    detail(model: true, speed: true)
                    detail(model: false, speed: true)
                    detail(model: false, speed: false)
                }
            }
        }
        .frame(height: 28)
    }

    @ViewBuilder private var mark: some View {
        if session.isWorking {
            RunningMark(icon: session.icon, since: session.stateSince ?? session.lastActivity, size: 20)
        } else {
            ZStack {
                Circle().stroke(session.isWaiting ? Color.yellow : Palette.track, lineWidth: 2)
                Mark(icon: session.icon, size: 10).foregroundStyle(session.isWaiting ? Color.yellow : Color.secondary)
            }
            .frame(width: 20, height: 20)
        }
    }

    private func detail(model: Bool, speed showsSpeed: Bool) -> some View {
        HStack(spacing: 6) {
            if model, let name = session.model {
                Text(name).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            Text(session.reportsTokens ? session.tokenText + " Token" : session.tokenText)
                .font(.system(size: 9, weight: .semibold)).monospacedDigit().fixedSize()
            if session.reportsTokens {
                Text(L("Hit ", "命中 ") + percent(session.cacheHitRate)).font(.system(size: 9)).foregroundStyle(.secondary)
                    .monospacedDigit().fixedSize()
            }
            if showsSpeed, session.reportsTokens {
                Text(speed(session.tokensPerSecond) + " tok/s").font(.system(size: 9)).foregroundStyle(.secondary)
                    .monospacedDigit().fixedSize()
            }
        }
    }
}

/// Session Detail: every session as a card of the same size, working and
/// waiting first, so none reads as lesser than another. Medium holds one card
/// and a row, large a column of cards, extra large two columns; what does not
/// fit is counted. Small keeps the first session's figures stacked.
struct SessionDetailView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    var familyOverride: WidgetFamily?
    let entry: Entry

    private var family: WidgetFamily { familyOverride ?? widgetFamily }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let sessions = entry.sessions?.sessions, let first = sessions.first {
                switch family {
                case .systemSmall:
                    SessionSmall(session: first)
                case .systemMedium:
                    ViewThatFits(in: .vertical) {
                        cards(sessions, count: 1, rows: 1, columns: 1)
                        cards(sessions, count: 1, rows: 0, columns: 1)
                    }
                default:
                    // Each rung a whole number of cards, richest first: the
                    // timeline draws every rung of every entry ahead of time.
                    let columns = family == .systemExtraLarge ? 2 : 1
                    ViewThatFits(in: .vertical) {
                        ForEach(Array(stride(from: min(sessions.count, 4 * columns), through: columns, by: -columns)),
                                id: \.self) { count in
                            cards(sessions, count: count, rows: 0, columns: columns)
                        }
                        cards(sessions, count: 1, rows: 0, columns: 1)
                    }
                }
            } else if entry.sessions?.isReading == false {
                Hint(text: L("Turn on Settings → Token spend in DragonFly API to read sessions",
                             "在 DragonFly API 的设置 → Token 消耗中开启读取后显示会话"))
            } else {
                Hint(text: L("No session in the last three hours", "最近三小时没有会话"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    /// The header, `count` cards in `columns`, then `rows` more sessions as
    /// Session Status's rows, then how many are left.
    private func cards(_ sessions: [Sessions.Session], count: Int, rows: Int, columns: Int) -> some View {
        let shown = Array(sessions.prefix(count)), listed = Array(sessions.dropFirst(count).prefix(rows))
        let left = sessions.count - shown.count - listed.count
        return VStack(alignment: .leading, spacing: 6) {
            SessionsHeader(title: L("Session Detail", "会话详情"), sessions: sessions)
            HStack(alignment: .top, spacing: 8) {
                ForEach(0..<columns, id: \.self) { column in
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(stride(from: column, to: shown.count, by: columns)), id: \.self) { index in
                            SessionCard(session: shown[index])
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            ForEach(listed) { SessionRow(session: $0) }
            if left > 0 {
                Text(L("+\(left) more", "另有 \(left) 个会话")).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}

/// One session as a card: its mark, name and state; its whole id and model;
/// its tokens in large type beside the cache hit rate, output speed and
/// clock; and the split of its tokens by kind. A working or waiting card is
/// outlined in its state's colour.
struct SessionCard: View {
    let session: Sessions.Session

    private var tint: Color {
        session.isWaiting ? .yellow : session.isWorking ? Palette.caution : .clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if session.isWorking {
                    RunningMark(icon: session.icon, since: session.stateSince ?? session.lastActivity, size: 15)
                } else {
                    Mark(icon: session.icon, size: 12).foregroundStyle(session.isWaiting ? Color.yellow : Color.secondary)
                        .frame(width: 15, height: 15)
                }
                Text(session.name ?? session.agent).font(.system(size: 11, weight: .bold)).lineLimit(1)
                Spacer(minLength: 4)
                SessionState(session: session)
            }
            HStack(spacing: 6) {
                Text(session.id).font(.system(size: 8.5, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7).layoutPriority(1)
                Spacer(minLength: 2)
                if let model = session.model {
                    Text(model).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(session.tokenText).font(.system(size: session.reportsTokens ? 15 : 11, weight: .bold, design: .rounded))
                    .monospacedDigit().lineLimit(1)
                if session.reportsTokens {
                    Text(L("Hit ", "命中 ") + percent(session.cacheHitRate)).font(.system(size: 9))
                        .foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    Text(speed(session.tokensPerSecond) + " tok/s").font(.system(size: 9))
                        .foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                Spacer(minLength: 2)
                SessionClock(session: session, size: 10).lineLimit(1).layoutPriority(2)
                    .foregroundStyle(session.isWaiting ? .yellow : session.isWorking ? Palette.caution : .secondary)
            }
            TokenSplit(session: session, showsLegend: false)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(0.55), lineWidth: 1))
    }
}

/// What a session's clock can show. It shows each in turn, for
/// `interval` seconds, the kinds the session has (`clockKinds`).
enum SessionClockKind {
    /// The current turn: since the session started working or waiting.
    case task
    /// Since the session was opened.
    case session
    /// Since its last record.
    case lastActivity

    static let interval: TimeInterval = 5
    /// How far ahead one timeline holds the turns (`Provider.getTimeline`).
    static let ahead: TimeInterval = 60

    var label: String {
        switch self {
        case .task: L("Task", "任务")
        case .session: L("Session", "会话")
        case .lastActivity: L("Last active", "上次活动")
        }
    }
}

extension EnvironmentValues {
    private struct ClockDate: EnvironmentKey { static let defaultValue = Date() }
    /// The timeline entry's date, which picks the clock's turn.
    var clockDate: Date {
        get { self[ClockDate.self] }
        set { self[ClockDate.self] = newValue }
    }
}

extension Sessions.Session {
    /// A task only while it works or waits; a session only with a start.
    var clockKinds: [SessionClockKind] {
        (isWorking || isWaiting ? [.task] : []) + (startedAt != nil ? [.session] : []) + [.lastActivity]
    }

    func clockKind(at date: Date) -> SessionClockKind {
        let kinds = clockKinds
        return kinds[Int(date.timeIntervalSince1970 / SessionClockKind.interval) % kinds.count]
    }

    /// Live to the second under a day; a session WorkBuddy has kept for
    /// months reads in days, not as thousands of hours.
    func clockValue(_ kind: SessionClockKind, at date: Date) -> Text {
        let since: Date = switch kind {
        case .task: stateSince ?? lastActivity
        case .session: startedAt ?? lastActivity
        case .lastActivity: lastActivity
        }
        let elapsed = date.timeIntervalSince(since) < 24 * 3600 ? Text(since, style: .timer)
            : Text(duration(date.timeIntervalSince(since)))
        return kind == .lastActivity ? elapsed + Text(L(" ago", " 前")) : elapsed
    }
}

/// The session's durations in turn — the current task, the session, the
/// time since its last record — each with its name.
///
/// **Never `.fixedSize()`.** On the desktop a live timer under a fixed size
/// left the whole widget empty — archived without an error, drawn as nothing
/// — while every local render looked right. Rows keep it whole with
/// `layoutPriority(2)`, above the name column's 1, so the model is cut first.
struct SessionClock: View {
    @Environment(\.clockDate) private var date
    let session: Sessions.Session
    var size: CGFloat = 10
    var weight: Font.Weight = .semibold

    var body: some View {
        let kind = session.clockKind(at: date)
        (Text(kind.label + " ").font(.system(size: size * 0.9)).foregroundStyle(.secondary)
            + session.clockValue(kind, at: date))
            .font(.system(size: size, weight: weight)).monospacedDigit()
    }
}

func duration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds)), hours = total / 3600, minutes = (total % 3600) / 60
    if hours >= 24 { return L("\(hours / 24)d \(hours % 24)h", "\(hours / 24)天\(hours % 24)时") }
    if hours > 0 { return L("\(hours)h \(minutes)m", "\(hours)时\(minutes)分") }
    return L("\(minutes)m", "\(max(minutes, 1))分")
}

/// The session's tokens split by kind, in one bar: fresh input, cache reads,
/// cache writes and output, each named with its count.
/// Rectangles side by side, each as wide as its share of the total, at
/// least two points, one point apart. A layout rather than a
/// `GeometryReader`: while WidgetKit archived Session Detail's timeline the
/// reader placed its bar at a NaN origin, SwiftUI stopped the extension
/// (`view origin is invalid`) and the widget was drawn blank. Here every
/// length is checked before it is used, so no offer can place a part at NaN.
struct SplitLayout: Layout {
    let shares: [Double]
    var gap: CGFloat = 1
    var minimum: CGFloat = 2

    private static func finite(_ length: CGFloat?, or fallback: CGFloat) -> CGFloat {
        guard let length, length.isFinite else { return fallback }
        return max(0, length)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: Self.finite(proposal.width, or: 0), height: Self.finite(proposal.height, or: 5))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = Self.finite(bounds.width, or: 0), height = Self.finite(bounds.height, or: 0)
        let total = max(1, shares.reduce(0, +))
        let room = max(0, width - gap * CGFloat(max(0, subviews.count - 1)))
        var x = bounds.minX.isFinite ? bounds.minX : 0
        let y = bounds.minY.isFinite ? bounds.minY : 0
        for (index, subview) in subviews.enumerated() {
            let share = index < shares.count && shares[index].isFinite ? max(0, shares[index]) : 0
            let part = max(minimum, room * share / total)
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: part, height: height))
            x += part + gap
        }
    }
}

struct TokenSplit: View {
    let session: Sessions.Session
    var showsLegend = true

    private var parts: [(String, Int, Color)] {
        [(L("Input", "输入"), session.input, Palette.ember),
         (L("Cache read", "缓存读"), session.cacheRead, Palette.good),
         (L("Cache write", "缓存写"), session.cacheWrite, Palette.caution),
         (L("Output", "输出"), session.output, Color(red: 0.0, green: 0.478, blue: 1.0))]
    }

    var body: some View {
        let shown = parts.filter { $0.1 > 0 }
        VStack(alignment: .leading, spacing: 4) {
            SplitLayout(shares: shown.map { Double($0.1) }) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, part in
                    Rectangle().fill(part.2)
                }
            }
            .frame(height: 5)
            .clipShape(Capsule())
            if showsLegend {
                ViewThatFits(in: .horizontal) {
                    legend(parts)
                    legend(parts.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(3).map { $0 })
                    legend(parts.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(2).map { $0 })
                }
                .frame(height: 11, alignment: .leading)
            }
        }
    }

    private func legend(_ parts: [(String, Int, Color)]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                HStack(spacing: 3) {
                    Circle().fill(part.2).frame(width: 5, height: 5)
                    Text(part.0).font(.system(size: 9)).foregroundStyle(.secondary).fixedSize()
                    Text(tokens(part.1)).font(.system(size: 9, weight: .semibold)).monospacedDigit().fixedSize()
                }
            }
        }
    }
}

/// Small: the session's figures stacked.
struct SessionSmall: View {
    let session: Sessions.Session

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                BrandMark(size: 13)
                Text(session.name ?? session.shortID).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 2)
                SessionState(session: session)
            }
            Text(session.model ?? "—").font(.system(size: 10, weight: .semibold)).lineLimit(1)
            Text(session.tokenText).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            TokenSplit(session: session, showsLegend: false)
            if session.reportsTokens {
                HStack(spacing: 0) {
                    small(L("Hit", "命中"), percent(session.cacheHitRate))
                    small("tok/s", speed(session.tokensPerSecond))
                }
            }
            HStack(spacing: 3) {
                Image(systemName: "clock").font(.system(size: 8)).foregroundStyle(.secondary)
                SessionClock(session: session, size: 10)
                Text(session.shortID).font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    private func small(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 8)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@main
struct PulseWidgetBundle: WidgetBundle {
    var body: some Widget {
        // Four, meant to be placed side by side.
        QuotaWidget()
        ActivityWidget()
        SessionWidget()
        SessionDetailWidget()
        RelayProgressWidget()
    }
}

struct SessionDetailWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PulseSessionDetail", provider: Provider(carousel: true)) {
            SessionDetailView(entry: $0).environment(\.clockDate, $0.date)
        }
            .configurationDisplayName(L("Session Detail", "会话详情"))
            .description(L("Every session as a card: its full id, model, state and duration, its tokens by kind, cache hit rate and output speed.",
                           "每个会话一张卡片：完整 ID、模型、运行状态和时长，各类 Token、命中率和输出速度。"))
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct SessionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PulseSessionStatus", provider: Provider(carousel: true)) {
            SessionStatusView(entry: $0).environment(\.clockDate, $0.date)
        }
            .configurationDisplayName(L("Session Status", "会话状态"))
            .description(L("Every agent's open or recent sessions, a row each: running, waiting or idle, with its model, tokens, cache hit rate and output speed.",
                           "各个 Agent 正在进行或最近的会话，每个一行：运行中、等你确认或空闲，以及模型、Token、命中率和输出速度。"))
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct QuotaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PulseQuota", provider: Provider()) { QuotaView(entry: $0) }
            .configurationDisplayName(L("AI Quota", "AI 额度"))
            .description(L("Each account's limit with its reset, or its balance, and every token counted by model.",
                           "每个账号的额度进度和重置时间或余额，以及累计 Token 和各模型占比。"))
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ActivityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PulseActivity", provider: Provider()) { ActivityView(entry: $0) }
            .configurationDisplayName(L("Token Activity", "Token 活动"))
            .description(L("Each subscription's limit, today's tokens, a daily heatmap and the models used.",
                           "今日 Token、每个订阅的额度进度、每日热力图和各模型用量。"))
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Preview data

extension Entry {
    static var preview: Entry {
        let now = Date()
        let window = { (kind: String, f: Double, h: Double) in
            Snapshot.Window(kind: kind, name: kind, usedFraction: f, resetsAt: now.addingTimeInterval(h * 3600), isExhausted: false)
        }
        // `usedFraction`, `limitName`, `resetsAt` and `headlineKind` all describe
        // one window: the app's own choice of headline, which is what the widgets
        // read. Here that is the five-hour one.
        let accounts = [
            Snapshot.Account(id: "claudeCode", name: "Claude Code", provider: "claudeCode", usedFraction: 0.42,
                             limitName: "5 hours", resetsAt: now.addingTimeInterval(2.5 * 3600), balance: nil,
                             isStale: false, isExhausted: false, message: nil,
                             windows: [window("fiveHour", 0.42, 2.5), window("weekly", 0.17, 90)],
                             isSubscription: true, headlineKind: "fiveHour"),
            Snapshot.Account(id: "codex", name: "Codex", provider: "codex", usedFraction: 0.66,
                             limitName: "5 hours", resetsAt: now.addingTimeInterval(1.2 * 3600), balance: nil,
                             isStale: false, isExhausted: false, message: nil,
                             windows: [window("fiveHour", 0.66, 1.2), window("weekly", 0.31, 120)],
                             isSubscription: true, headlineKind: "fiveHour"),
            Snapshot.Account(id: "ccSwitch#a", name: "DeepSeek", provider: "ccSwitch", usedFraction: nil,
                             limitName: nil, resetsAt: nil, balance: "¥1,636.91", isStale: false, isExhausted: false,
                             message: nil, windows: [], isSubscription: false),
        ]
        let days = (0..<182).map { offset in
            Spend.Day(date: Calendar.current.date(byAdding: .day, value: offset - 181, to: Calendar.current.startOfDay(for: now))!,
                      tokens: offset % 7 == 5 ? 0 : (offset * 7919) % 9_000_000)
        }
        let spend = Spend(generatedAt: now, source: "ccSwitch",
                          today: .init(tokens: 12_400_000, requests: 123, cost: 8.4, cacheHitRate: 0.989),
                          last5h: .init(tokens: 3_100_000, cost: 2.1), week: .init(tokens: 61_000_000, cost: 44.1, cacheHitRate: 0.97),
                          days: days,
                          modelsToday: [.init(name: "Claude Opus 5.5", tokens: 8_200_000), .init(name: "GPT-5.5", tokens: 3_100_000),
                                        .init(name: "deepseek-v4-pro", tokens: 1_100_000)],
                          modelsWeek: [.init(name: "Claude Opus 5.5", tokens: 40_000_000), .init(name: "GPT-5.5", tokens: 15_000_000)])
        return Entry(date: now, snapshot: Snapshot(generatedAt: now, accounts: accounts,
                                                   running: [.init(provider: "claudeCode", name: "Claude Code", icon: "claude", since: now.addingTimeInterval(-95))]),
                     spend: spend)
    }
}
