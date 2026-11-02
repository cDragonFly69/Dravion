import SwiftUI
import RelayCore

/// Copies the Claude Code and Codex account windows APIUse has read into the scheduler's quota board,
/// so a subscription-limit pause waits for the real reset instead of a time parsed out of the error text.
///
/// **And keeps them current.** APIUse reads accounts on its own adaptive cadence — two minutes at best,
/// half an hour when nothing seems to move — which is the wrong answer for a number someone is watching a
/// run spend against. This loop asks only the accounts that are on screen (the header pills, and every
/// shown account while the quota panel is open), on a cadence each provider can actually sustain, and
/// copies the result to the board every couple of seconds so the run dashboard follows at once.
///
/// Reads are account endpoints (Claude's OAuth usage, Codex's app-server rate limits): no model call, no
/// tokens.
@MainActor
enum RelayQuotaFeed {
    private static var task: Task<Void, Never>?
    static let clients: [(RelayProviderKind, Provider)] = [(.claude, .claudeCode), (.codex, .codex)]

    /// How often the board is copied from the store. No request is made — one
    /// copy of a handful of windows — so this can run far faster than anything
    /// is fetched.
    static let boardTick: Duration = .seconds(2)

    /// Where each kind of account starts, and the shortest it is ever asked.
    ///
    /// Codex's limits come from the app server on this Mac, a local round trip
    /// that spends nothing upstream, so its pill can genuinely be kept live.
    /// Claude's endpoint rate-limits the login token it shares with Claude Code,
    /// the CLI and this window, so it starts a minute apart and `settle` moves
    /// it from there. Everything else is a balance read against someone else's
    /// server and is left at a minute.
    static let starts: [Provider: (start: TimeInterval, floor: TimeInterval)] = [
        .codex: (10, 10),
        .claudeCode: (30, 20),
    ]
    static let otherStart: (start: TimeInterval, floor: TimeInterval) = (30, 30)
    /// The longest anything is left: where a provider that keeps refusing ends
    /// up. The old fixed wait for a rate-limited Claude reading, kept as the
    /// ceiling rather than the first answer.
    static let ceiling: TimeInterval = 300
    /// How long an ask is given before the next tick reads its outcome.
    static let answerGrace: TimeInterval = 3

    /// When each account was last asked.
    private static var askedAt: [String: Date] = [:]
    /// How long each account is currently left between asks. Learned; see
    /// `settle`.
    private static var currentGap: [String: TimeInterval] = [:]
    /// An ask in flight — when it went out, and the reading's stamp before it —
    /// so the next tick can tell whether it brought anything new.
    private static var pending: [String: (askedAt: Date, before: Date?)] = [:]

    static func start(model: RelayAppModel) {
        task?.cancel()
        askedAt.removeAll()
        currentGap.removeAll()
        pending.removeAll()
        task = Task { @MainActor [weak model] in
            while !Task.isCancelled, let model {
                let now = Date()
                settle(model, now: now)
                // The board follows the store on every tick, not only after an
                // ask: a reading handed back by the panel's own refresh is then
                // on the run dashboard two seconds later instead of thirty.
                feed(model)

                // Only while someone could be looking: the window in front, or
                // a run spending against these limits.
                if let store = model.usageStore, NSApp.isActive || spending(model) {
                    let due = dueAccounts(model, now: now)
                    if !due.isEmpty {
                        for account in due {
                            askedAt[account.id] = now
                            pending[account.id] = (now, store.usage(for: account).observedAt)
                        }
                        store.refreshQuota(due)
                    }
                }
                try? await Task.sleep(for: boardTick)
            }
        }
    }

    /// Reads the answers that have had time to come back, and moves each
    /// account's gap accordingly.
    ///
    /// **Learned rather than fixed.** A reading that moved means the provider
    /// answered, so the next ask may come a little sooner; one that did not
    /// means it refused (Claude's endpoint answers 429 when asked too often) or
    /// has nothing better to give (a status-line capture only moves while a
    /// session runs), so the next ask waits twice as long. Each pill ends up as
    /// current as its own provider allows and no faster — which is the only
    /// honest way to be live against an endpoint that rate-limits, and it
    /// replaces a rule that parked a single refusal for ten minutes.
    private static func settle(_ model: RelayAppModel, now: Date) {
        guard let store = model.usageStore else { return }
        for (id, ask) in Array(pending) where now.timeIntervalSince(ask.askedAt) >= answerGrace {
            pending.removeValue(forKey: id)
            guard let account = AccountKey(id: id) else { continue }
            let advanced = store.usage(for: account).observedAt.map { observed in
                ask.before.map { observed > $0 } ?? true
            } ?? false
            let limits = limits(for: account.provider)
            let gap = currentGap[id] ?? limits.start
            currentGap[id] = advanced ? max(limits.floor, gap * 0.7) : min(ceiling, gap * 2)
        }
    }

    /// The accounts this loop keeps current: the header pills, because those
    /// are the numbers in front of someone, and every shown account while the
    /// quota panel is open for inspection.
    static func accounts(_ model: RelayAppModel) -> [AccountKey] {
        guard let settings = model.usageSettings else { return [] }
        let shown = model.overlay?.id == "quota" ? settings.shownAccounts : RelayQuotaHeader.accounts(settings)
        return shown.filter { settings.isEnabled($0) }
    }

    /// The accounts whose own gap has come round and are not being asked
    /// already.
    static func dueAccounts(_ model: RelayAppModel, now: Date = Date()) -> [AccountKey] {
        accounts(model).filter { account in
            guard pending[account.id] == nil else { return false }
            guard let last = askedAt[account.id] else { return true }
            return now.timeIntervalSince(last) >= gap(for: account)
        }
    }

    /// How long this account is left between asks now.
    static func gap(for account: AccountKey) -> TimeInterval {
        currentGap[account.id] ?? limits(for: account.provider).start
    }

    private static func limits(for provider: Provider) -> (start: TimeInterval, floor: TimeInterval) {
        starts[provider] ?? otherStart
    }

    /// The refresh button (user request, 2026-11-01: 点击刷新后立马刷新): forget every learned back-off so the
    /// loop starts over from each provider's quickest pace, and ask every header account right now.
    static func refreshNow(_ model: RelayAppModel) {
        currentGap.removeAll(); pending.removeAll()
        let now = Date()
        for account in accounts(model) { askedAt[account.id] = now }
        model.readQuotaNow(allShown: false)
        feed(model)
    }

    /// Whether a run is spending right now, which is the other reason to keep
    /// the pills current.
    static func spending(_ model: RelayAppModel) -> Bool {
        model.store.state.runs.contains { $0.status.isWorking }
    }

    static func feed(_ model: RelayAppModel) {
        guard let store = model.usageStore, let settings = model.usageSettings else { return }
        for (kind, provider) in clients {
            // The CLI sends as whoever it is signed in as, which is the provider's first account.
            guard let account = settings.shownAccounts.first(where: { $0.provider == provider && $0.isPrimary }) else {
                model.scheduler.quota.update(kind, []); continue
            }
            model.scheduler.quota.update(kind, store.usage(for: account).windows.map {
                .init(name: $0.name, usedFraction: $0.usedFraction, resetsAt: $0.resetsAt, exhausted: $0.isExhausted)
            })
        }
    }
}

extension RelayAppModel {
    /// Reads the quota sources now, without waiting for the loop.
    ///
    /// This is the refresh button's whole job, and what opening the quota panel
    /// does so its first frame is the current one: the store asks each account
    /// side by side and publishes each answer as it lands, so a click never
    /// waits behind a pass that is already running.
    ///
    /// - Parameter allShown: every account set up in 用量, rather than only the
    ///   ones the page header shows.
    func readQuotaNow(allShown: Bool = true) {
        guard let store = usageStore, let settings = usageSettings else { return }
        store.refreshQuota(allShown ? settings.shownAccounts : RelayQuotaFeed.accounts(self))
    }
}

/// A model's time window as it stands now, drawn like the APIUse widget: state, a bar through the current
/// stretch, and when it next changes.
struct RelayPolicyLive: View {
    let policy: RelayModelPolicy

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let segment = policy.segment(at: context.date)
            let remaining = segment.end.map { $0.timeIntervalSince(context.date) }
            let fraction: Double = {
                guard let start = segment.start, let end = segment.end, end > start else { return segment.open ? 1 : 0 }
                return context.date.timeIntervalSince(start) / end.timeIntervalSince(start)
            }()
            let color: Color = !segment.open ? .secondary : (remaining ?? .infinity) < 30 * 60 ? .pulseCaution : .pulseGood
            HStack(spacing: 8) {
                Circle().fill(segment.open ? color : Color.clear).overlay(Circle().stroke(color, lineWidth: 1)).frame(width: 7, height: 7)
                Text(segment.open ? "现在可用" : "现在不可用").font(.system(size: 11, weight: .semibold)).foregroundStyle(segment.open ? color : .secondary)
                UsageBar(fraction: fraction, accent: color.opacity(segment.open ? 1 : 0.45), track: Color.primary.opacity(0.08), style: .continuous)
                    .frame(width: 120, height: UsageBar.continuousHeight)
                if let end = segment.end, let remaining {
                    Text("↻ \(RelayCountdown.short(remaining))后\(segment.open ? "停用" : "开放") · \(Self.clock(end, from: context.date))")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    static func clock(_ date: Date, from now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// The client's account windows (five-hour, weekly…) as APIUse reads them: used share and reset countdown.
struct RelayQuotaLine: View {
    let model: RelayAppModel
    let kind: RelayProviderKind

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let windows = model.scheduler.quota.windows(for: kind)
            if windows.isEmpty {
                Text(model.usageStore == nil ? "额度读数未启用" : "未读取到账户额度：在“用量 → 账户设置”中启用该账户。")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 16) {
                    Text("账户额度").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(Array(windows.prefix(3).enumerated()), id: \.offset) { _, window in
                        HStack(spacing: 4) {
                            Text(window.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            Text("已用\(Int((window.usedFraction * 100).rounded()))%")
                                .font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(UsageTint.color(for: window.usedFraction, isExhausted: window.exhausted,
                                                                 warningAt: UsageTint.warningThreshold))
                            if let reset = window.resetsAt, reset > context.date {
                                Text("↻\(RelayCountdown.short(reset.timeIntervalSince(context.date)))")
                                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

extension RelayCountdown {
    /// "2天7时" / "2时25分" / "38分", as the APIUse widget counts down to a reset.
    static func short(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds) / 60)
        let days = minutes / 1440, hours = minutes % 1440 / 60, rest = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)天\(hours)时" : "\(days)天" }
        if hours > 0 { return rest > 0 ? "\(hours)时\(rest)分" : "\(hours)时" }
        return minutes > 0 ? "\(minutes)分" : "不到1分"
    }
}
