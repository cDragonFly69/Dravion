import SwiftUI
import RelayCore

/// The top of the usage page: totals, then every quota window as its own card (or a row in the list
/// view), then APIUse's Token activity and sessions. Quota comes from `UsageStore`; spend from
/// `SpendPaneModel`, which this view owns through its own `SettingsNavigation` parked on `.spend` while
/// the page is on screen, so leaving the page releases what was read.
struct RelayUsageOverview: View {
    let model: RelayAppModel
    let store: UsageStore
    let settings: AppSettings
    @State private var navigation: SettingsNavigation
    @State private var spend: SpendPaneModel
    @AppStorage("relay.usage.quotaLayout") private var layout = RelayQuotaLayout.cards

    init(model: RelayAppModel, store: UsageStore, settings: AppSettings) {
        self.model = model
        self.store = store
        self.settings = settings
        let navigation = SettingsNavigation()
        navigation.pane = .spend
        _navigation = State(initialValue: navigation)
        _spend = State(initialValue: SpendPaneModel(settings: settings, navigation: navigation))
    }

    private var items: [RelayQuotaItem] { RelayQuotaItem.all(store: store, settings: settings) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            RelayUsageTotals(items: items, spend: spend, settings: settings)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("额度").font(.headline)
                    Text("\(items.count) 项").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("显示方式", selection: $layout) {
                        Label("卡片", systemImage: "square.grid.2x2").tag(RelayQuotaLayout.cards)
                        Label("列表", systemImage: "list.bullet").tag(RelayQuotaLayout.list)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if items.isEmpty {
                    Text("还没有启用账户。点右上角“账户设置”添加 Claude、Codex、DeepSeek 等账户。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        switch layout {
                        case .cards: RelayQuotaCards(items: items, now: context.date)
                        case .list: RelayQuotaList(items: items, now: context.date)
                        }
                    }
                }
            }
            RelaySpendSection(model: model, settings: settings, spend: spend)
        }
        .task(id: spend.loadKey) { await spend.load() }
        .task(id: spend.summaryRequest) { await spend.recompute() }
        .onAppear { navigation.isWindowVisible = true }
        .onDisappear { navigation.isWindowVisible = false }
        // A model opened under one client means nothing under another, so switching clients goes back to the list.
        .onChange(of: spend.spendFocus) { _, _ in spend.selectedModel = nil }
    }
}

enum RelayQuotaLayout: String { case cards, list }

/// One quota window of one account, or an account's balance, or an account that could not be read.
struct RelayQuotaItem: Identifiable {
    enum Kind { case window(UsageWindow), balance(String), unavailable(String) }
    let id: String
    let account: String
    let kind: Kind
    let stale: Bool

    var usedFraction: Double? { if case .window(let window) = kind { window.usedFraction } else { nil } }
    var isSpent: Bool { if case .window(let window) = kind { window.isExhausted || window.usedFraction >= 1 } else { false } }

    @MainActor static func all(store: UsageStore, settings: AppSettings) -> [RelayQuotaItem] {
        settings.shownAccounts.flatMap { key -> [RelayQuotaItem] in
            let usage = store.usage(for: key)
            let name = settings.label(for: key)
            let stale = { if case .stale = usage.state { true } else { false } }()
            var rows = usage.windows.map { RelayQuotaItem(id: "\(key.id)/\($0.id)", account: name, kind: .window($0), stale: stale) }
            if let credit = usage.creditBalance {
                rows.append(.init(id: "\(key.id)/balance", account: name, kind: .balance(credit), stale: stale))
            }
            if rows.isEmpty, case .unavailable(let reason) = usage.state {
                rows.append(.init(id: "\(key.id)/unavailable", account: name, kind: .unavailable(reason.message), stale: false))
            }
            return rows
        }
    }

    var title: String {
        switch kind {
        case .window(let window): window.name
        case .balance: "余额"
        case .unavailable: "未获取"
        }
    }
    func color(_ fraction: Double) -> Color {
        UsageTint.color(for: fraction, isExhausted: isSpent, warningAt: UsageTint.warningThreshold)
    }
    func reset(_ now: Date) -> String? {
        guard case .window(let window) = kind, let reset = window.resetsAt, reset > now else { return nil }
        return "↻ \(RelayCountdown.short(reset.timeIntervalSince(now)))"
    }
}

/// Totals at the very top: what was spent over the chosen span, how many tokens, and how tight quota is.
private struct RelayUsageTotals: View {
    let items: [RelayQuotaItem]
    let spend: SpendPaneModel
    let settings: AppSettings

    var body: some View {
        let windows = items.filter { $0.usedFraction != nil }
        let tightest = windows.max { ($0.usedFraction ?? 0) < ($1.usedFraction ?? 0) }
        let spent = windows.filter(\.isSpent).count
        let average = windows.isEmpty ? nil : windows.compactMap(\.usedFraction).reduce(0, +) / Double(windows.count)
        let balances = items.compactMap { item -> String? in if case .balance(let text) = item.kind { "\(item.account) \(text)" } else { nil } }
        RelayCard(padding: 18) {
            HStack(alignment: .top, spacing: 0) {
                metric("总消费 · \(settings.spendSpan.title)",
                       settings.readsTokenSpend ? (spend.isScanningSpend && spend.spend.isEmpty ? "读取中…" : SpendFormat.money(spend.spend.cost)) : "—",
                       settings.readsTokenSpend ? "按模型公开价格估算" : "未开启读取本机记录")
                divider
                metric("总 Tokens", settings.readsTokenSpend ? SpendFormat.tokens(spend.spend.tokens) : "—",
                       settings.readsTokenSpend ? "\(spend.spend.sessions.count) 个会话" : "")
                divider
                metric("总额度占用", average.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                       windows.isEmpty ? "没有额度窗口" : "\(windows.count) 个额度窗口的平均已用", color: average.map { UsageTint.color(for: $0, warningAt: UsageTint.warningThreshold) })
                divider
                metric("最紧张", tightest.map { "\(Int((($0.usedFraction ?? 0) * 100).rounded()))%" } ?? "—",
                       tightest.map { "\($0.account) · \($0.title)" + (spent > 0 ? " · \(spent) 项已用完" : "") } ?? "",
                       color: tightest.flatMap { item in item.usedFraction.map { item.color($0) } })
                if !balances.isEmpty {
                    divider
                    metric("余额", "\(balances.count) 个账户", balances.joined(separator: "  "))
                }
            }
        }
    }
    private var divider: some View { Rectangle().fill(RelayStyle.border).frame(width: 1).padding(.horizontal, 18) }
    private func metric(_ label: String, _ value: String, _ note: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(color ?? .primary).lineLimit(1).minimumScaleFactor(0.6)
            Text(note).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One card per quota window: which account and which limit, how much is used, when it resets.
private struct RelayQuotaCards: View {
    let items: [RelayQuotaItem]
    let now: Date

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text(item.account).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        if item.stale { Text("历史读数").font(.system(size: 10)).foregroundStyle(.orange) }
                    }
                    Text(item.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    switch item.kind {
                    case .window(let window):
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(Int((window.usedFraction * 100).rounded()))%")
                                .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(item.color(window.usedFraction))
                            Text("已用").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            if let reset = item.reset(now) { Text(reset).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
                        }
                        UsageBar(fraction: window.usedFraction, accent: item.color(window.usedFraction),
                                 track: Color.primary.opacity(0.08), style: .continuous)
                            .frame(height: UsageBar.continuousHeight)
                    case .balance(let text):
                        Text(text).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    case .unavailable(let message):
                        Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                .padding(14).frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(RelayStyle.border))
            }
        }
    }
}

/// The same windows as aligned rows, for scanning many accounts at once.
private struct RelayQuotaList: View {
    let items: [RelayQuotaItem]
    let now: Date

    var body: some View {
        RelayCard(padding: 0) {
            VStack(spacing: 0) {
                row(account: Text("账户"), title: Text("额度"), bar: AnyView(Text("用量")), used: Text("已用"), reset: Text("重置"))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.vertical, 8)
                ForEach(items) { item in
                    Divider().opacity(0.5)
                    switch item.kind {
                    case .window(let window):
                        row(account: Text(item.account) + Text(item.stale ? " · 历史读数" : "").foregroundColor(.orange),
                            title: Text(item.title),
                            bar: AnyView(UsageBar(fraction: window.usedFraction, accent: item.color(window.usedFraction),
                                                  track: Color.primary.opacity(0.08), style: .continuous).frame(height: UsageBar.continuousHeight)),
                            used: Text("\(Int((window.usedFraction * 100).rounded()))%").foregroundColor(item.color(window.usedFraction)).fontWeight(.semibold),
                            reset: Text(item.reset(now) ?? "—"))
                    case .balance(let text):
                        row(account: Text(item.account), title: Text(item.title), bar: AnyView(EmptyView()), used: Text(text).fontWeight(.semibold), reset: Text("—"))
                    case .unavailable(let message):
                        row(account: Text(item.account), title: Text(message).foregroundColor(.secondary), bar: AnyView(EmptyView()), used: Text("—"), reset: Text("—"))
                    }
                }
            }.font(.system(size: 12)).monospacedDigit()
        }
    }
    private func row(account: Text, title: Text, bar: AnyView, used: Text, reset: Text) -> some View {
        HStack(spacing: 14) {
            account.lineLimit(1).frame(width: 170, alignment: .leading)
            title.lineLimit(1).frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            bar.frame(width: 180, alignment: .leading)
            used.frame(width: 70, alignment: .trailing)
            reset.foregroundColor(.secondary).frame(width: 90, alignment: .trailing)
        }.padding(.horizontal, 16).padding(.vertical, 9)
    }
}

/// APIUse's Token activity and per-session detail, embedded as is.
struct RelaySpendSection: View {
    let model: RelayAppModel
    let settings: AppSettings
    @Bindable var spend: SpendPaneModel
    @State private var openedSession: SpendSummary.Session?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Token 活动与会话").font(.headline)
                Spacer()
                if settings.readsTokenSpend, spend.isScanningSpend, let progress = spend.spendProgress {
                    Text("正在读取 \(progress.agent.displayName)… \(progress.index + 1)/\(progress.total)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Toggle("读取本机用量记录", isOn: Binding(get: { settings.readsTokenSpend }, set: { settings.readsTokenSpend = $0 }))
                    .toggleStyle(.switch).controlSize(.small)
            }
            if settings.readsTokenSpend {
                TokenSpendView(
                    summary: spend.spend,
                    focus: $spend.spendFocus,
                    focused: spend.focusedSpend,
                    modelFocus: $spend.selectedModel,
                    modelSummary: spend.modelSpend,
                    noRecords: spend.spendNoRecords,
                    hasReadLimitations: spend.spendHasReadLimitations,
                    span: Binding(get: { settings.spendSpan }, set: { settings.spendSpan = $0 }),
                    customDays: Binding(get: { settings.spendCustomDays }, set: { settings.spendCustomDays = $0 }),
                    activity: spend.spendActivity,
                    activityView: Binding(get: { settings.spendActivityView }, set: { settings.spendActivityView = $0 }),
                    isLoading: spend.isScanningSpend,
                    isSummarizing: spend.summaryIsPending,
                    refresh: { spend.spendRescan += 1 },
                    openSession: { openedSession = $0 }
                )
                .sheet(item: $openedSession) { row in
                    RelaySessionDetail(model: model, row: row, projectName: (spend.spendFocus == nil ? spend.spend : spend.focusedSpend).projectName(for: row))
                }
            } else {
                RelayCard {
                    HStack(spacing: 14) {
                        RelayIconTile(icon: "chart-bar")
                        VStack(alignment: .leading, spacing: 5) {
                            Text("未读取本机用量记录").font(.system(size: 14, weight: .medium))
                            Text("打开右上角开关后，读取 Claude Code、Codex 等客户端留在本机的记录，显示总消费、Token 活动和每个会话的消耗。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
