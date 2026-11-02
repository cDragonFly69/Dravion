import SwiftUI
import RelayCore

// MARK: - Clickable stat tile

/// A `RelayStatTile` that opens its details: lifts on hover and shows a chevron, so it reads as a button.
struct RelayStatButton: View {
    var title: String
    var value: String
    var note: String
    var color: Color
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            RelayStatTile(title: title, value: value, note: note, color: color)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)).foregroundStyle(color)
                        .padding(12).opacity(hovering ? 1 : 0.35)
                }
                .background(color.opacity(hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .scaleEffect(hovering ? 1.012 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("查看\(title)详情")
        .accessibilityIdentifier("stat-\(title)")
    }
}

// MARK: - Panels opened from the dashboard

/// Shared frame of the dashboard panels: header, hairline, scrolling body. Looks the run up by id on every
/// render, so a panel left open keeps following the run.
private struct RelayRunPanel<Body: View>: View {
    let model: RelayAppModel
    let runID: String
    var icon: String
    var color: Color
    var title: String
    var subtitle: (RelayRun) -> String = { $0.input.title }
    var scrolls = true
    @ViewBuilder var content: (RelayRun) -> Body
    var body: some View {
        if let run = model.store.state.runs.first(where: { $0.id == runID }) {
            VStack(spacing: 0) {
                RelayOverlayHeader(icon: icon, color: color, title: title, subtitle: subtitle(run), close: model.dismissOverlay)
                Divider().opacity(0.5)
                if scrolls {
                    RelayFitScroll { content(run).padding(20).frame(maxWidth: .infinity, alignment: .leading) }
                } else {
                    content(run).padding(14).frame(maxHeight: .infinity)
                }
            }
        }
    }
}

/// The live run log, as a drawer from the right edge.
struct RelayRunLogPanel: View {
    let model: RelayAppModel
    let runID: String
    var body: some View {
        RelayRunPanel(model: model, runID: runID, icon: "terminal-window", color: .primary, title: "执行记录",
                      subtitle: { run in run.input.title + (run.status.isWorking ? " · 实时" : " · " + run.status.label) }, scrolls: false) { run in
            RelayTerminalLog(events: model.store.events[runID] ?? [], roles: run.roles)
        }
        .accessibilityIdentifier("run-log-panel")
    }
}

struct RelayTasksPanel: View {
    let model: RelayAppModel
    let runID: String
    var body: some View {
        RelayRunPanel(model: model, runID: runID, icon: "files", color: RelayPalette.ember, title: "子任务",
                      subtitle: { "\($0.finishedTasks) / \($0.tasks.count) 已完成 · 点击查看输出、代码和验收标准" }) { run in
            if run.tasks.isEmpty {
                Text("总调度还没有拆分任务。").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                RelayTaskStepper(run: run, framed: false) { id in
                    model.present("task-\(id)", width: 860) { RelayTaskDetail(model: model, runID: runID, taskID: id) }
                }
            }
        }
    }
}

struct RelayMilestonesPanel: View {
    let model: RelayAppModel
    let runID: String
    var body: some View {
        RelayRunPanel(model: model, runID: runID, icon: "tree-structure", color: RelayPalette.violet, title: "里程碑") { run in
            RelayMilestoneRoadmap(run: run, framed: false)
        }
    }
}

struct RelayCallsPanel: View {
    let model: RelayAppModel
    let runID: String
    var body: some View {
        RelayRunPanel(model: model, runID: runID, icon: "cpu", color: RelayPalette.green, title: "调用记录与模型状态",
                      subtitle: { run in
                          let calls = run.callRecords ?? []
                          return "\(calls.count) 次调用 · \(calls.filter { $0.status == .failed }.count) 次失败 · 最新在上"
                      }) { run in
            RelayCallTimeline(model: model, run: run, framed: false)
        }
    }
}

/// Token totals for the run, then who spent them.
struct RelayTokenPanel: View {
    let model: RelayAppModel
    let runID: String
    var body: some View {
        RelayRunPanel(model: model, runID: runID, icon: "chart-bar", color: RelayPalette.teal, title: "Token 用量",
                      subtitle: { "\(RelayTokens.text($0.totalTokens)) · 缓存命中 \(Int(($0.cacheHitRate * 100).rounded()))%" }) { run in
            VStack(alignment: .leading, spacing: 22) {
                if let usage = run.usage {
                    RelayTokenBreakdown(usage: usage)
                } else {
                    Text("这是旧版任务，只记录了总量：输入 \(RelayTokens.text(run.inputTokens)) · 缓存读取 \(RelayTokens.text(run.cacheReadTokens)) · 输出 \(RelayTokens.text(run.outputTokens))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                let rows = (run.roleUsage ?? [:]).map { id, usage in (role: run.roles.first { $0.id == id }, id: id, usage: usage) }
                    .sorted { $0.usage.tokens.total > $1.usage.tokens.total }
                if !rows.isEmpty {
                    let top = max(1, rows.map(\.usage.tokens.total).max() ?? 1)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("按员工").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(rows, id: \.id) { row in
                            let color = row.role.map { RelayStyle.color($0.color) } ?? .secondary
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Circle().fill(color).frame(width: 7, height: 7)
                                    Text(row.role?.name ?? row.id).font(.system(size: 12, weight: .medium))
                                    Text("\(row.usage.calls) 次调用").font(.system(size: 11)).foregroundStyle(.tertiary)
                                    Spacer()
                                    if let hit = row.usage.tokens.cacheHitRate {
                                        Text("命中 \(Int((hit * 100).rounded()))%").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                    Text(RelayTokens.text(row.usage.tokens.total)).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                                }
                                GeometryReader { geometry in
                                    Capsule().fill(color.opacity(0.12))
                                        .overlay(alignment: .leading) {
                                            Capsule().fill(color.opacity(0.75)).frame(width: geometry.size.width * CGFloat(row.usage.tokens.total) / CGFloat(top))
                                        }
                                }.frame(height: 5)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Account quota, compact

/// How an account's reading is shown: time windows (5h, 7d…) as what is left, or a balance as money only.
enum RelayQuotaReading {
    /// Windows that are allowances over time, shortest first; balances and credit packs are not among them.
    static func timeWindows(_ usage: ProviderUsage) -> [UsageWindow] {
        let order: (UsageWindow) -> Int = { window in
            switch window.kind {
            case .fiveHour: return 0
            case .daily: return 1
            case .weekly: return 2
            case .monthly: return 3
            default: return 4
            }
        }
        return usage.windows.filter { window in
            switch window.kind {
            case .balance, .topUp, .credits, .sharedCredits, .planCredits, .dedicatedCredits, .spend: return false
            default: return true
            }
        }.sorted { order($0) < order($1) }
    }
    static func short(_ window: UsageWindow) -> String {
        switch window.kind {
        case .fiveHour: return "5h"
        case .daily: return "1d"
        case .weekly: return "7d"
        case .monthly: return "30d"
        case .messages: return "消息"
        case .other(let seconds): return seconds >= 86_400 ? "\(seconds / 86_400)d" : "\(max(1, seconds / 3_600))h"
        default: return window.name
        }
    }
    /// "24分前" when the reading is more than 5 minutes old, so a stuck figure is not taken for a live one.
    static func age(_ usage: ProviderUsage, now: Date = Date()) -> String? {
        guard let observed = usage.observedAt, now.timeIntervalSince(observed) > 300 else { return nil }
        return RelayCountdown.short(now.timeIntervalSince(observed)) + "前"
    }
    static func tint(_ window: UsageWindow) -> Color {
        UsageTint.color(for: window.usedFraction, isExhausted: window.isExhausted, warningAt: UsageTint.warningThreshold)
    }
}

/// Which accounts the page header shows, in the user's order (Dravion's own choice, separate from what the
/// usage page lists). Empty means "the first three shown".
enum RelayQuotaHeader {
    static let key = "quota.header.accounts"
    static func ids() -> [String] { (UserDefaults.standard.string(forKey: key) ?? "").split(separator: ",").map(String.init) }
    static func save(_ ids: [String]) { UserDefaults.standard.set(ids.joined(separator: ","), forKey: key) }
    static func accounts(_ settings: AppSettings, stored: String) -> [AccountKey] {
        let ids = stored.split(separator: ",").map(String.init)
        let shown = settings.shownAccounts
        let picked = ids.compactMap { id in shown.first { $0.id == id } }
        return picked.isEmpty ? Array(shown.prefix(3)) : picked
    }
    /// The same list for callers with no view to read the app storage from —
    /// the quota feed, which keeps exactly these accounts current.
    static func accounts(_ settings: AppSettings) -> [AccountKey] {
        accounts(settings, stored: ids().joined(separator: ","))
    }
    enum Kind: Int { case windows, balance, missing }
    static func kind(_ usage: ProviderUsage) -> Kind {
        if !RelayQuotaReading.timeWindows(usage).isEmpty { return .windows }
        return usage.creditBalance != nil ? .balance : .missing
    }
}

/// Account quota in the page header: one pill per chosen account, each named, so a reading is never mistaken for
/// another account's. Subscription accounts show 5h/7d remaining as dots; balances show the money.
struct RelayQuotaPills: View {
    let model: RelayAppModel
    @AppStorage(RelayQuotaHeader.key) private var stored = ""
    var body: some View {
        if let store = model.usageStore, let settings = model.usageSettings, !settings.shownAccounts.isEmpty {
            let accounts = RelayQuotaHeader.accounts(settings, stored: stored)
            HStack(spacing: 6) {
                ForEach(accounts) { account in RelayQuotaPill(model: model, account: account, usage: store.usage(for: account), label: settings.label(for: account)) }
                if store.isRefreshing { ProgressView().controlSize(.mini) }
            }
            .accessibilityIdentifier("quota-pills")
        }
    }
}

private struct RelayQuotaPill: View {
    let model: RelayAppModel
    let account: AccountKey
    let usage: ProviderUsage
    let label: String
    @State private var hovering = false
    var body: some View {
        let windows = RelayQuotaReading.timeWindows(usage)
        let retry = RelayQuotaFeed.gap(for: account)
        let retryText = retry >= 90 ? "\(Int((retry / 60).rounded())) 分钟" : "\(Int(retry.rounded())) 秒"
        Button {
            // Opening the panel is a request to see the current numbers, so it
            // reads them on the way in rather than showing whatever the loop
            // happened to have. Each account is committed as its answer lands.
            model.readQuotaNow()
            model.present("quota", width: 780) { RelayQuotaPanel(model: model) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: windows.isEmpty ? (usage.creditBalance == nil ? "exclamationmark.circle" : "yensign.circle") : "gauge.with.dots.needle.50percent")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary).lineLimit(1).frame(maxWidth: 110, alignment: .leading)
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 11)
                if !windows.isEmpty {
                    ForEach(Array(windows.prefix(2))) { window in
                        HStack(spacing: 3) {
                            Circle().fill(RelayQuotaReading.tint(window)).frame(width: 6, height: 6)
                            Text(RelayQuotaReading.short(window)).foregroundStyle(.tertiary)
                            Text("\(window.percentValue(remaining: true))%").monospacedDigit().foregroundStyle(.primary)
                        }
                    }
                } else if let balance = usage.creditBalance {
                    Text(balance).monospacedDigit().foregroundStyle(.primary)
                } else {
                    Text("未获取").foregroundStyle(.tertiary)
                }
                if let age = RelayQuotaReading.age(usage) {
                    Text(age).font(.system(size: 10)).foregroundStyle(.orange).monospacedDigit()
                }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color.primary.opacity(hovering ? 0.08 : 0.04), in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help("\(label)：剩余额度。" + (RelayQuotaReading.age(usage).map { "当前是\($0)的读数：额度接口限流（429）或暂时读不到，正在每 \(retryText)重试一次。" } ?? "") + "点击查看全部账户并立即刷新")
    }
}

/// Every shown account: time windows as what is left with their reset, balances as money. Each card can be hidden
/// (it stays set up in 用量) or, for an added account, removed with its settings.
struct RelayQuotaPanel: View {
    let model: RelayAppModel
    @State private var removing: AccountKey?
    @AppStorage(RelayQuotaHeader.key) private var stored = ""
    var body: some View {
        VStack(spacing: 0) {
            RelayOverlayHeader(icon: "chart-bar", color: RelayPalette.amber, title: "账户额度",
                               subtitle: "显示剩余额度 · 每 15 秒自动读取，点刷新立即读取 · 读取额度不调用模型，不消耗 token", close: model.dismissOverlay) {
                if let store = model.usageStore {
                    Button { model.readQuotaNow() } label: {
                        if store.isReadingQuota { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }.buttonStyle(.borderless).help("立即刷新").disabled(store.isReadingQuota)
                }
                Button("全部用量") { model.dismissOverlay(); model.section = .usage }.buttonStyle(.borderless).font(.system(size: 12))
            }
            Divider().opacity(0.5)
            if let store = model.usageStore, let settings = model.usageSettings {
                RelayFitScroll {
                    VStack(alignment: .leading, spacing: 18) {
                        headerOrder(settings)
                        let groups: [(RelayQuotaHeader.Kind, String)] = [(.windows, "订阅额度 · 按时间窗口"), (.balance, "余额"), (.missing, "未获取")]
                        ForEach(groups, id: \.0) { kind, title in
                            let accounts = settings.shownAccounts.filter { RelayQuotaHeader.kind(store.usage(for: $0)) == kind }
                            if !accounts.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("\(title)  \(accounts.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)], spacing: 12) {
                                        ForEach(accounts) { account in card(account, store: store, settings: settings) }
                                    }
                                }
                            }
                        }
                        let hidden = settings.orderedAccounts.filter { !settings.isEnabled($0) }
                        if !hidden.isEmpty {
                            HStack(spacing: 6) {
                                Text("已隐藏：").foregroundStyle(.secondary)
                                ForEach(hidden.prefix(8)) { account in
                                    Button(settings.label(for: account)) { settings.setEnabled(true, for: account) }
                                        .buttonStyle(.bordered).controlSize(.small).help("重新显示")
                                }
                            }.font(.system(size: 11))
                        }
                    }.padding(20)
                }
            }
        }
        .confirmationDialog("删除这个账户的额度配置？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("删除", role: .destructive) {
                if let removing, let settings = model.usageSettings { settings.removeAccount(removing) }
                removing = nil
            }
            Button("取消", role: .cancel) { removing = nil }
        } message: { Text("只删除 Dravion 里这个账户的额度读取设置，不影响账户本身。") }
    }

    /// The header's accounts, in order: move left/right, remove; cards add themselves with their pin.
    private func headerOrder(_ settings: AppSettings) -> some View {
        let pinned = RelayQuotaHeader.accounts(settings, stored: stored)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("顶部显示").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("用 ← → 调整顺序；在下面的卡片上点图钉添加").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                Spacer()
                if !stored.isEmpty { Button("恢复默认") { stored = "" }.buttonStyle(.borderless).font(.system(size: 11)) }
            }
            RelayFlow(spacing: 6) {
                ForEach(Array(pinned.enumerated()), id: \.element.id) { index, account in
                    HStack(spacing: 4) {
                        Button { move(account, by: -1, pinned: pinned) } label: { Image(systemName: "chevron.left") }.disabled(index == 0)
                        Text("\(index + 1). \(settings.label(for: account))").font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        Button { move(account, by: 1, pinned: pinned) } label: { Image(systemName: "chevron.right") }.disabled(index == pinned.count - 1)
                        Button { toggle(account, pinned: pinned) } label: { Image(systemName: "xmark") }.help("不在顶部显示")
                    }
                    .buttonStyle(.borderless).font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RelayPalette.amber.opacity(0.1), in: Capsule())
                    .overlay(Capsule().stroke(RelayPalette.amber.opacity(0.25)))
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    private func move(_ account: AccountKey, by offset: Int, pinned: [AccountKey]) {
        var ids = pinned.map(\.id)
        guard let index = ids.firstIndex(of: account.id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset); stored = ids.joined(separator: ",")
    }
    private func toggle(_ account: AccountKey, pinned: [AccountKey]) {
        var ids = pinned.map(\.id)
        if let index = ids.firstIndex(of: account.id) { ids.remove(at: index) } else { ids.append(account.id) }
        // Removing the last one would fall back to the default three; keep at least one.
        guard !ids.isEmpty else { return }
        stored = ids.joined(separator: ",")
    }

    private func card(_ account: AccountKey, store: UsageStore, settings: AppSettings) -> some View {
        let usage = store.usage(for: account)
        let windows = RelayQuotaReading.timeWindows(usage)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(settings.label(for: account)).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                let pinned = RelayQuotaHeader.accounts(settings, stored: stored)
                let isPinned = pinned.contains(account)
                Button { toggle(account, pinned: pinned) } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin").font(.system(size: 10.5))
                        .foregroundStyle(isPinned ? RelayPalette.amber : Color.secondary)
                }.buttonStyle(.borderless).help(isPinned ? "顶部显示中，点击取消" : "在顶部显示")
                switch usage.state {
                case .live: EmptyView()
                case .stale: Text("历史读数").font(.system(size: 10)).foregroundStyle(.orange)
                case .unavailable: Text("未获取").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Menu {
                    Button("隐藏") { settings.setEnabled(false, for: account) }
                        .disabled(settings.shownAccounts.count <= 1)
                    if !account.isPrimary {
                        Button("删除配置…", role: .destructive) { removing = account }
                    }
                } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("隐藏或删除")
            }
            if !windows.isEmpty {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(windows.prefix(3))) { window in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Circle().fill(RelayQuotaReading.tint(window)).frame(width: 6, height: 6)
                                    Text(RelayQuotaReading.short(window)).font(.system(size: 11)).foregroundStyle(.secondary)
                                    Text("剩 \(window.percentValue(remaining: true))%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                    Spacer()
                                    if let reset = window.resetsAt, reset > context.date {
                                        Text("↻\(RelayCountdown.short(reset.timeIntervalSince(context.date)))").font(.system(size: 10.5)).foregroundStyle(.tertiary).monospacedDigit()
                                    }
                                }
                                Capsule().fill(Color.primary.opacity(0.07)).frame(height: 4)
                                    .overlay(alignment: .leading) {
                                        GeometryReader { g in
                                            Capsule().fill(RelayQuotaReading.tint(window)).frame(width: g.size.width * window.remainingFraction)
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            if let balance = usage.creditBalance {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("余额").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(balance).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }
            if windows.isEmpty, usage.creditBalance == nil, case .unavailable(let reason) = usage.state {
                Text(reason.message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("隐藏") { settings.setEnabled(false, for: account) }.disabled(settings.shownAccounts.count <= 1)
                    if !account.isPrimary { Button("删除配置", role: .destructive) { removing = account } }
                }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(RelayStyle.border))
    }
}

// MARK: - Bring an employee into a running task

/// Pick an employee (already in the task or not), give them one sub-task, optionally after other sub-tasks.
/// The scheduler checks the employee's model and picks the sub-task up like any other (`addMember`).
struct RelayAddMemberPanel: View {
    let model: RelayAppModel
    let runID: String
    @State private var roleID = ""
    @State private var title = ""
    @State private var detail = ""
    @State private var after: Set<String> = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        if let run = model.store.state.runs.first(where: { $0.id == runID }) {
            let roles = candidates(run)
            VStack(alignment: .leading, spacing: 0) {
                RelayOverlayHeader(icon: "users-three", color: RelayPalette.ember, title: "临时加入员工", subtitle: run.input.title, close: model.dismissOverlay)
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 16) {
                    field("员工") {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            ForEach(roles) { role in roleTile(role, run: run) }
                        }
                    }
                    field("要他做什么") {
                        TextField("例如：补齐 README 的安装说明", text: $title).relayField()
                        TextField("具体要求、范围和验收（可选）", text: $detail, axis: .vertical).relayField().lineLimit(3...6)
                    }
                    let open = run.tasks.filter { $0.status != .succeeded }
                    if !open.isEmpty {
                        field("等这些完成后再开始（可选）") {
                            Menu {
                                ForEach(open) { item in
                                    Toggle(item.task.title, isOn: Binding(get: { after.contains(item.id) },
                                                                          set: { on in if on { after.insert(item.id) } else { after.remove(item.id) } }))
                                }
                                if !after.isEmpty { Divider(); Button("清除，不等") { after = [] } }
                            } label: {
                                Text(after.isEmpty ? "不等，马上可以开始" : run.tasks.filter { after.contains($0.id) }.map(\.task.title).joined(separator: "、"))
                                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .menuStyle(.button).buttonStyle(.bordered)
                        }
                    }
                    if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                    HStack {
                        Text(note(run)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("取消") { model.dismissOverlay() }
                        Button(busy ? "检查模型…" : "加入并分配") { submit(run) }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy || roleID.isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("confirm-add-member")
                    }
                }.padding(20)
            }
            .onAppear { if roleID.isEmpty { roleID = roles.first { r in !run.roles.contains { $0.id == r.id } }?.id ?? roles.first?.id ?? "" } }
        }
    }

    /// Executors first (newcomers before current members), then everyone else who is enabled.
    private func candidates(_ run: RelayRun) -> [RelayRole] {
        model.store.state.roles.filter(\.enabled).sorted { a, b in
            let rank = { (role: RelayRole) in (role.stage == .executor ? 0 : 2) + (run.roles.contains { $0.id == role.id } ? 1 : 0) }
            return rank(a) < rank(b)
        }
    }

    private func roleTile(_ role: RelayRole, run: RelayRun) -> some View {
        let selected = roleID == role.id
        let color = RelayStyle.color(role.color)
        let connection = model.store.state.connections.first { $0.id == role.connectionID }
        let member = run.roles.contains { $0.id == role.id }
        let status = RelayEmployeeState.of(role, in: model.store.state, events: model.store.events)
        return Button { roleID = role.id } label: {
            HStack(spacing: 9) {
                RelayAvatar(role: role, connection: connection, active: status.kind == .working, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(member ? "已在任务中 · 追加工作" : "\(role.stage.label) · \(status.label)").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(color) }
            }
            .padding(9)
            .background(selected ? color.opacity(0.1) : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(selected ? color.opacity(0.5) : RelayStyle.border))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func note(_ run: RelayRun) -> String {
        switch run.phase {
        case .tests, .quality, .review: return "任务正在测试或复审；这项工作会在当前步骤后先完成，再重新测试和复审。"
        default: return run.status.isWorking ? "加入后，依赖满足就会和其他员工并行开工。" : "任务暂停中；恢复后开始这项工作。"
        }
    }

    private func submit(_ run: RelayRun) {
        busy = true; error = nil
        Task {
            do {
                _ = try await model.scheduler.addMember(runID, roleID: roleID, title: title, description: detail, dependsOn: Array(after))
                model.dismissOverlay()
            } catch { self.error = model.store.redact(error.localizedDescription) }
            busy = false
        }
    }
}

/// Why a run waits for a Claude seat, side by side with who holds it, and the two ways out:
/// release the old seat (its client history stays), or hand this step to another employee.
struct RelaySeatConflictPanel: View {
    let model: RelayAppModel
    let runID: String
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let run = model.store.state.runs.first { $0.id == runID }
        VStack(alignment: .leading, spacing: 0) {
            RelayOverlayHeader(icon: "cpu", color: .orange, title: "Claude 席位被占用", subtitle: run?.input.title ?? "", close: model.dismissOverlay)
            Divider().opacity(0.5)
            if let conflict = model.scheduler.seatConflict(runID) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Claude 的“\(conflict.needed.purpose.label)”只能有一个常驻会话。它现在属于别的项目、连接或模型，Dravion 不会替你换掉，要你选一个办法。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 10) {
                        seat("本任务需要", key: conflict.needed, who: conflict.role.name, highlight: true)
                        seat("目前占用", key: conflict.holder.key, who: conflict.holderRuns.isEmpty ? "没有未完成任务在用" : conflict.holderRuns.joined(separator: "、"),
                             status: conflict.holderBusy ? "正在执行" : conflict.holder.lastUsedAt.map { "上次使用 " + $0.formatted(.relative(presentation: .named)) } ?? "空闲")
                    }
                    if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                    VStack(spacing: 8) {
                        Button { release() } label: {
                            choice("释放旧席位并继续", detail: conflict.holderBusy
                                   ? "旧席位正在执行，等它这次调用结束后才能释放。"
                                   : "旧会话的历史记录保留在 Claude 里，本任务新开会话继续。" + (conflict.holderRuns.isEmpty ? "" : "用它的任务下次派活时再建新席位。"))
                        }
                        .buttonStyle(.borderedProminent).disabled(busy || conflict.holderBusy)
                        .accessibilityIdentifier("release-seat")
                        Menu {
                            ForEach(others(conflict)) { role in
                                let connection = model.store.state.connections.first { $0.id == role.connectionID }?.name ?? "连接缺失"
                                Button("\(role.name) · \(connection)") { replace(conflict, with: role.id) }
                            }
                        } label: {
                            choice("换个员工接手", detail: "把「\(conflict.role.name)」这一步交给别人，不动 Claude 的席位。")
                        }
                        .menuStyle(.button).buttonStyle(.bordered).disabled(busy || others(conflict).isEmpty)
                        .accessibilityIdentifier("replace-seat-holder")
                    }
                    Text("也可以什么都不做：旧席位被释放后，这个任务会自动继续。所有席位在“连接 → 常驻会话”里查看。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(20)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("席位已经空出来，任务会自动继续。").font(.system(size: 13))
                    HStack { Spacer(); Button("好") { model.dismissOverlay() }.buttonStyle(.borderedProminent) }
                }.padding(20)
            }
        }
    }

    private func seat(_ title: String, key: RelaySessionKey, who: String, status: String? = nil, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(highlight ? RelayStyle.accent : .orange)
                Spacer()
                if let status { Text(status).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            row("员工/任务", who)
            row("项目", URL(fileURLWithPath: key.projectPath).lastPathComponent, help: key.projectPath)
            row("连接", model.store.state.connections.first { $0.id == key.connectionID }?.name ?? key.connectionID)
            row("模型", key.model.isEmpty ? "沿用客户端配置" : key.model)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    private func row(_ label: String, _ value: String, help: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Text(value).lineLimit(2).textSelection(.enabled).help(help ?? value)
        }.font(.system(size: 11))
    }
    private func choice(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 11)).opacity(0.8).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
    }
    /// Anyone enabled except the blocked employee; those not on Claude first, since they need no seat.
    private func others(_ conflict: RelayScheduler.SeatConflict) -> [RelayRole] {
        let kind = { (role: RelayRole) in model.store.state.connections.first { $0.id == role.connectionID }?.kind }
        return model.store.state.roles.filter { $0.enabled && $0.id != conflict.role.id }
            .sorted { (kind($0) == .claude ? 1 : 0) < (kind($1) == .claude ? 1 : 0) }
    }
    private func release() {
        busy = true; error = nil
        do { try model.scheduler.releaseSeat(for: runID); model.dismissOverlay(); model.notice = "已释放旧席位，任务继续。" }
        catch { self.error = error.localizedDescription }
        busy = false
    }
    private func replace(_ conflict: RelayScheduler.SeatConflict, with roleID: String) {
        busy = true; error = nil
        Task {
            do {
                let message = try await model.scheduler.replaceMember(runID, stage: conflict.stage, from: conflict.role.id, to: roleID)
                model.dismissOverlay(); if !message.isEmpty { model.notice = message }
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
