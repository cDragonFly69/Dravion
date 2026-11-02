import SwiftUI
import RelayCore

struct RelayUsageView: View {
    @Bindable var model: RelayAppModel
    private var totals: RelayUsageTotals { .overall(runs: model.store.state.runs) }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                RelayPageTitle(title: "额度与用量", subtitle: "账户额度由 APIUse 读取；任务消耗按客户端实际报告分项记录。")
                if let store = model.usageStore {
                    Button(store.isReadingQuota ? "读取中…" : "刷新额度") { model.readQuotaNow() }.disabled(store.isReadingQuota)
                }
                Button("账户设置") { model.openUsage() }.buttonStyle(.bordered).disabled(model.isUITest)
            }
            if let store = model.usageStore, let settings = model.usageSettings {
                RelayUsageOverview(model: model, store: store, settings: settings)
            } else { emptyAccounts }
            Text("调度器已记录的调用").font(.headline)
            RelayCard { RelayTokenBreakdown(usage: totals) }
            let legacy = model.store.state.runs.filter { $0.usage == nil || $0.legacyUsageUnattributed == true }.count
            if legacy > 0 {
                Text("\(legacy) 项历史任务未完整记录角色与调用分项，保留原总量，不推算缺失数据。").font(.caption).foregroundStyle(.secondary)
            }
            RelayCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("按员工统计").font(.headline)
                    ForEach(model.store.state.roles) { role in
                        let usage = RelayUsageTotals.role(role.id, runs: model.store.state.runs)
                        HStack {
                            Text(role.name).font(.system(size: 13, weight: .medium)).frame(width: 130, alignment: .leading)
                            Spacer()
                            if let usage {
                                Text("\(usage.calls) 次调用 · \(RelayTokens.text(usage.tokens.total))")
                                Text("复用 \(usage.resumedCalls) 次").foregroundStyle(.secondary)
                                if usage.unreportedCalls > 0 { Text("\(usage.unreportedCalls) 次未报告").foregroundStyle(.orange) }
                            } else { Text("暂无调用记录").foregroundStyle(.secondary) }
                        }.font(.system(size: 12)).monospacedDigit()
                        if role.id != model.store.state.roles.last?.id { Divider().opacity(0.4) }
                    }
                }
            }
            RelayCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("按任务统计").font(.headline)
                    ForEach(model.store.state.runs.prefix(30)) { run in
                        Button { model.selectRun(run.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(run.input.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text("\(run.project.name) · \(run.status.label)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(RelayTokens.text(run.totalTokens)).font(.system(size: 12, design: .monospaced))
                                if let count = run.usage?.unreportedCalls, count > 0 { Text("另有 \(count) 次未报告").font(.caption).foregroundStyle(.secondary) }
                                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
                            }.padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if model.store.state.runs.isEmpty { Text("完成一次调用后会显示用量。").font(.caption).foregroundStyle(.secondary) }
                }
            }
            HStack {
                DravionIcon(name: "desktop", size: 20)
                Text("桌面右键 → 编辑小组件 → Dravion，可查看额度、会话与调度进度。").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("显示 / 隐藏悬浮条") { model.toggleUsagePanel() }.disabled(model.isUITest)
            }
            Text("账户监控复用 APIUse / Pulse（Apache-2.0），与菜单栏、悬浮条共用同一份读数。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var emptyAccounts: some View {
        RelayCard {
            HStack(spacing: 14) {
                RelayIconTile(icon: "chart-bar")
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.isUITest ? "界面验证未连接真实账户" : "尚未启用账户监控").font(.system(size: 14, weight: .medium))
                    Text(model.isUITest ? "此模式不会读取或刷新账号额度。" : "在账户设置中启用服务后，主窗口会直接显示读数。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct RelayTokenBreakdown: View {
    let usage: RelayUsageTotals
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 14) {
                metric("已报告", usage.calls == usage.unreportedCalls ? "—" : RelayTokens.number(usage.tokens.total), unit: "tokens", exact: usage.tokens.total)
                metric("普通输入", RelayTokens.number(usage.tokens.input), unit: "tokens", exact: usage.tokens.input)
                metric("缓存读取", RelayTokens.number(usage.tokens.cacheRead), unit: "tokens", exact: usage.tokens.cacheRead)
                metric("缓存写入", RelayTokens.number(usage.tokens.cacheWrite), unit: "tokens", exact: usage.tokens.cacheWrite)
                metric("输出", RelayTokens.number(usage.tokens.output), unit: "tokens", exact: usage.tokens.output)
                metric("缓存命中率", usage.tokens.cacheHitRate?.formatted(.percent.precision(.fractionLength(0))) ?? "—")
            }
            Text("\(usage.calls) 次调用 · 复用 \(usage.resumedCalls) 次 · 新会话 \(usage.newSessions) 个 · 失败 \(usage.failedCalls) 次")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if usage.unreportedCalls > 0 {
                Text("另有 \(usage.unreportedCalls) 次调用未报告 token，未按 0 计入。").font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }
    private func metric(_ label: String, _ value: String, unit: String? = nil, exact: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
                if let unit, value != "—" { Text(unit).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
        .help(exact.map { "\($0.formatted()) tokens" } ?? "")
    }
}

struct RelayQuotaStrip: View {
    let model: RelayAppModel
    var showsTitle = true
    var body: some View {
        if let store = model.usageStore, let settings = model.usageSettings, !settings.shownAccounts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if showsTitle {
                    HStack {
                        Text("账户额度").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button("全部用量") { model.section = .usage }.font(.caption).buttonStyle(.borderless)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), alignment: .top)], spacing: 12) {
                    ForEach(Array(settings.shownAccounts.prefix(showsTitle ? 4 : 12))) { account in
                        let usage = store.usage(for: account)
                        RelayCard(padding: 12) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(settings.label(for: account)).font(.system(size: 12, weight: .medium)); Spacer(); RelayUsageState(usage: usage) }
                                ForEach(Array(usage.windows.prefix(2))) { window in
                                    HStack {
                                        Text(window.name).foregroundStyle(.secondary)
                                        Spacer()
                                        Text(window.percentText(remaining: true)).monospacedDigit()
                                    }.font(.system(size: 11))
                                }
                                if let credit = usage.creditBalance { Text("余额 \(credit)").font(.system(size: 11)).monospacedDigit() }
                                if usage.windows.isEmpty, case .unavailable(let reason) = usage.state {
                                    Text(reason.message).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct RelayUsageState: View {
    let usage: ProviderUsage
    var body: some View {
        switch usage.state {
        case .live: Text("最新读数").font(.system(size: 10)).foregroundStyle(.secondary)
        case .stale: Text("历史读数").font(.system(size: 10)).foregroundStyle(.orange)
        case .unavailable: Text("未获取").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
