import SwiftUI
import UserNotifications
import RelayCore

struct RelayProjectsView: View {
    @Bindable var model: RelayAppModel
    @State private var editingProject: RelayProject?
    @State private var search = ""
    @State private var provider = "all"
    @State private var limit = 80
    private var filtered: [RelayExternalSession] {
        model.sessions.filter { session in
            (provider == "all" || session.provider.rawValue == provider) && (search.isEmpty || (session.title + " " + session.projectPath + " " + session.sessionID).localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                RelayPageTitle(title: "项目与会话，在同一处", subtitle: "读取客户端已有记录，在原来的目录接着做。新任务使用持久会话。")
                Button("添加项目", systemImage: "folder.badge.plus") {
                    if let path = RelayDialogs.directory() { editingProject = .init(name: URL(fileURLWithPath: path).lastPathComponent, path: path) }
                }.buttonStyle(.bordered)
            }
            if model.store.state.projects.isEmpty {
                RelayCard { RelayEmpty(symbol: "folder", title: "还没有工作项目", detail: "选择本机目录，或从下方的客户端会话导入项目，再填写实际测试命令。") }
            }
            ForEach(model.store.state.projects) { project in
                RelayCard {
                    HStack(spacing: 16) {
                        Image(systemName: "folder.fill").font(.system(size: 25)).foregroundStyle(RelayStyle.accent.opacity(0.7))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(project.name).font(.headline)
                            Text(project.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            Text("测试：\(project.testCommand)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("在 Finder 中打开") { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) }
                        Button("编辑") { editingProject = project }
                        Menu { Button("移除项目", role: .destructive) { model.perform { try model.store.deleteProject(project.id) } } } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("更多")
                    }
                }
            }
            HStack {
                Text("客户端会话").font(.headline)
                Text("\(model.sessions.count)").foregroundStyle(.secondary).font(.caption)
                Spacer()
                Button(model.scanning ? "读取中…" : "刷新") { model.refreshSessions() }.disabled(model.scanning)
            }
            HStack {
                TextField("搜索项目、标题或会话 ID", text: $search).relayField()
                Picker("客户端", selection: $provider) {
                    Text("全部客户端").tag("all")
                    ForEach([RelayProviderKind.codex, .claude, .deepseekHarness, .workbuddy], id: \.self) { Text($0.label).tag($0.rawValue) }
                }.labelsHidden().frame(width: 170)
            }
            ForEach(model.sessionIssues, id: \.self) { issue in Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if filtered.isEmpty && !model.scanning { RelayEmpty(symbol: "bubble.left.and.bubble.right", title: "没有匹配的会话", detail: "客户端的本机记录会在此显示；没有工作目录的会话会保留标题和来源。") }
            LazyVStack(spacing: 10) {
                ForEach(filtered.prefix(limit)) { session in
                    RelayCard(padding: 15) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: session.provider.symbol).foregroundStyle(RelayStyle.accent).frame(width: 25)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack { Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(1); if session.isActive { RelayBadge(text: "客户端执行中", color: .blue) } }
                                Text(session.projectPath.isEmpty ? "未记录工作目录" : session.projectPath).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                                Text("\(session.provider.label) · \(session.updatedAt.formatted(date: .abbreviated, time: .shortened)) · \(session.sessionID)")
                                    .font(.system(size: 10)).foregroundStyle(.tertiary).textSelection(.enabled)
                            }
                            Spacer(minLength: 6)
                            Menu("操作") {
                                Button("复制会话 ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.sessionID, forType: .string) }
                                Button("显示原始记录") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.recordPath)]) }
                                if !session.projectPath.isEmpty {
                                    Button("导入为工作项目") {
                                        editingProject = model.store.state.projects.first { $0.path == session.projectPath } ?? .init(name: URL(fileURLWithPath: session.projectPath).lastPathComponent, path: session.projectPath)
                                    }
                                }
                            }.fixedSize()
                        }
                    }
                }
                if filtered.count > limit { Button("显示更多（剩余 \(filtered.count - limit) 项）") { limit += 80 } }
            }
        }.sheet(item: $editingProject) { RelayProjectEditor(model: model, project: $0) }
    }
}

/// Time windows belong to a model inside a client, not to the client: e.g. WorkBuddy's DeepSeek models run
/// only off-peak while its other models are not used at all. The page groups models under their client.
struct RelayPoliciesView: View {
    @Bindable var model: RelayAppModel
    @State private var editing: RelayModelPolicy?
    @State private var buddyNotes: [String: String] = [:]
    @State private var catalogs: [String: [RelayClientCatalog.Group]] = [:]
    private var state: RelayState { model.store.state }
    /// Models worth listing for a connection: those with a policy, those roles use, and the allow-list.
    private func models(of connection: RelayConnection) -> [String] {
        var ids = state.modelPolicies.filter { $0.connectionID == connection.id }.map(\.model)
        ids += state.roles.filter { $0.connectionID == connection.id }.map(\.model)
        ids += connection.allowedModels ?? []
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }.sorted()
    }
    private func policy(_ connection: RelayConnection, _ id: String) -> RelayModelPolicy {
        state.modelPolicies.first { $0.id == RelayModelPolicy.key(connectionID: connection.id, model: id) }
            ?? .init(connectionID: connection.id, model: id)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            RelayPageTitle(title: "让模型按你的节奏工作",
                           subtitle: "时段设在客户端里的具体模型上，例如只在非高峰期使用 WorkBuddy 内置的 DeepSeek。额度不足时通知并暂停，不会自动换模型。")
            let connections = state.connections.filter { !models(of: $0).isEmpty || $0.kind == .workbuddy }
            if connections.isEmpty {
                RelayEmpty(symbol: "clock", title: "还没有可设置的模型", detail: "先在“角色与连接”中添加连接，并为角色选择模型。")
            }
            ForEach(connections) { connection in
                RelayCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(connection.name).font(.system(size: 15, weight: .semibold))
                            Text(connection.kind.label).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            let taken = Set(models(of: connection))
                            let allowed = connection.allowedModels ?? []
                            let groups = (catalogs[connection.id] ?? []).map { group in
                                var next = group; next.entries = group.entries.filter { allowed.isEmpty || allowed.contains($0.id) }; return next
                            }.filter { !$0.entries.isEmpty }
                            if !groups.isEmpty {
                                // One submenu per group the client itself uses (cc-switch providers, DSH providers, WorkBuddy families).
                                Menu("为模型添加时段") {
                                    ForEach(groups) { group in
                                        Menu(group.title) {
                                            if let note = group.note { Text(note) }
                                            ForEach(group.entries, id: \.id) { entry in
                                                Button(entry.note.map { "\(entry.label)　\($0)" } ?? entry.label) { editing = policy(connection, entry.id) }
                                                    .disabled(taken.contains(entry.id))
                                            }
                                        }
                                    }
                                }.fixedSize()
                            }
                        }
                        if let allowed = connection.allowedModels, !allowed.isEmpty {
                            Text("只允许：\(allowed.joined(separator: "、"))").font(.caption).foregroundStyle(.secondary)
                        }
                        if RelayQuotaFeed.clients.contains(where: { $0.0 == connection.kind }) {
                            RelayQuotaLine(model: model, kind: connection.kind)
                        }
                        ForEach(models(of: connection), id: \.self) { id in
                            let current = policy(connection, id)
                            Divider().opacity(0.5)
                            HStack(alignment: .top, spacing: 14) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(id.isEmpty ? "客户端默认模型" : id).font(.system(size: 13, weight: .medium, design: .monospaced))
                                    Text(current.restrictHours ? RelayWindowText.describe(current) : "全天可用").font(.system(size: 12)).foregroundStyle(.secondary)
                                    if current.restrictHours { RelayPolicyLive(policy: current) }
                                    if let note = connection.kind == .workbuddy ? buddyNotes[id] : nil {
                                        Text(note).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text("无输出 \(current.maxCallSeconds < 60 ? "\(current.maxCallSeconds) 秒" : RelayCountdown.short(Double(current.maxCallSeconds))) 判为卡住 · 冷却 \(current.cooldownSeconds) 秒 · 自动重试 \(current.automaticRetries) 次").font(.caption).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                RelayBadge(text: current.restrictHours ? "按时段使用" : "全天可用", color: current.restrictHours ? RelayStyle.accent : .secondary)
                                Button("设置") { editing = current }
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { RelayPolicyEditor(model: model, policy: $0) }
        .onAppear { buddyNotes = RelayProviders.buddyModelNotes() }
        .task {
            let connections = state.connections
            catalogs = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: connections.map { ($0.id, RelayClientCatalog.groups(for: $0)) })
            }.value
        }
    }
}

enum RelayWindowText {
    static let days = ["日", "一", "二", "三", "四", "五", "六"]
    static func time(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
    static func days(_ set: Set<Int>) -> String {
        if set == Set(1...7) { return "每天" }
        if set == [2, 3, 4, 5, 6] { return "周一至周五" }
        if set == [1, 7] { return "周末" }
        return "周" + set.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { days[$0 - 1] }.joined(separator: "、")
    }
    static func describe(_ window: RelayTimeWindow) -> String {
        let span = window.startMinute == window.endMinute ? "全天"
            : "\(time(window.startMinute))–\(window.endMinute == 0 ? "24:00" : time(window.endMinute))"
        return "\(days(window.weekdays)) \(span)"
    }
    static func describe(_ policy: RelayModelPolicy) -> String {
        policy.effectiveWindows.map(describe).joined(separator: "；") + "（\(policy.timeZone)）"
    }
}

struct RelayPolicyEditor: View {
    @Bindable var model: RelayAppModel
    @State var policy: RelayModelPolicy
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var connection: RelayConnection? { model.store.state.connections.first { $0.id == policy.connectionID } }
    private var vendorNote: String? { connection?.kind == .workbuddy ? RelayProviders.buddyModelNotes()[policy.model] : nil }
    private var windows: Binding<[RelayTimeWindow]> {
        Binding(get: { policy.effectiveWindows }, set: { policy.windows = $0 })
    }
    var body: some View {
        VStack(spacing: 0) {
            RelaySheetHeader(title: "模型时间策略", close: { dismiss() })
            Form {
                Section {
                    LabeledContent("客户端", value: connection?.name ?? policy.connectionID)
                    LabeledContent("模型") { Text(policy.model.isEmpty ? "客户端默认模型" : policy.model).font(.system(.body, design: .monospaced)) }
                    if let vendorNote { Text(vendorNote).font(.caption).foregroundStyle(.secondary) }
                }
                Section {
                    Toggle("只在以下时段使用", isOn: $policy.restrictHours)
                    if policy.restrictHours {
                        if policy.model.localizedCaseInsensitiveContains("deepseek") && connection?.kind == .workbuddy {
                            Button("套用 WorkBuddy DeepSeek 非高峰（5 折）") { policy.applyOffPeakDeepSeek() }
                        }
                        RelayWindowList(windows: windows)
                        TextField("时区", text: $policy.timeZone)
                        if let note = policy.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section {
                    TextField("无输出上限（秒）", value: $policy.maxCallSeconds, format: .number)
                    Text("客户端持续有输出（读文件、改代码、跑命令）就不会被打断；连续这么久没有任何输出才判为卡住，停止后自动续接原会话重试一次。").font(.caption).foregroundStyle(.secondary)
                    TextField("不可用后冷却（秒）", value: $policy.cooldownSeconds, format: .number)
                    Stepper("自动重试 \(policy.automaticRetries) 次", value: $policy.automaticRetries, in: 0...10)
                    Text("额度不足时按员工设置里的“候选员工”换人接手；没有候选就停下，等额度恢复后自动继续。认证失败需要手动处理。").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped)
            HStack { Spacer(); Button("保存策略") { do { try model.store.savePolicy(policy); dismiss() } catch { self.error = error.localizedDescription } }.buttonStyle(.borderedProminent) }.padding(20)
        }.frame(width: 680, height: policy.restrictHours ? 720 : 470).tint(RelayStyle.action)
    }
}

/// Daily time windows, edited as rows (start, end, weekdays); used for model hours and employees' working hours.
struct RelayWindowList: View {
    @Binding var windows: [RelayTimeWindow]
    var note = "结束早于开始表示跨午夜；开始等于结束表示所选日期全天。任一时段内都可以运行。"
    var body: some View {
        ForEach(Array(windows.enumerated()), id: \.offset) { index, _ in row(index) }
        Button { windows.append(.init(startMinute: 9 * 60, endMinute: 18 * 60, weekdays: [2, 3, 4, 5, 6])) } label: {
            Label("添加时段", systemImage: "plus")
        }.disabled(windows.count >= 12)
        Text(note).font(.caption).foregroundStyle(.secondary)
    }
    private func row(_ index: Int) -> some View {
        let window = Binding(get: { windows[index] }, set: { windows[index] = $0 })
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                timePicker("开始", value: window.startMinute)
                Text("至").foregroundStyle(.secondary)
                timePicker("结束", value: window.endMinute)
                Spacer()
                Text(summary(window.wrappedValue)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Button(role: .destructive) { windows.remove(at: index) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).disabled(windows.count <= 1).help("删除这个时段")
            }
            HStack {
                ForEach(Array(RelayWindowText.days.enumerated()), id: \.offset) { day, label in
                    Toggle(label, isOn: Binding(get: { window.wrappedValue.weekdays.contains(day + 1) }, set: { on in
                        if on { window.wrappedValue.weekdays.insert(day + 1) } else { window.wrappedValue.weekdays.remove(day + 1) }
                    })).toggleStyle(.checkbox)
                }
            }
        }.padding(.vertical, 2)
    }
    /// Hour and minute are dropdowns (时 00–23, 分 每 5 分钟): typing digits into two tiny fields was not discoverable.
    private func timePicker(_ title: String, value: Binding<Int>) -> some View {
        let hour = Binding(get: { value.wrappedValue / 60 }, set: { value.wrappedValue = $0 * 60 + value.wrappedValue % 60 })
        let minute = Binding(get: { value.wrappedValue % 60 }, set: { value.wrappedValue = value.wrappedValue / 60 * 60 + $0 })
        // Keep an earlier off-step minute (e.g. 07) selectable instead of silently showing a blank menu.
        let minutes = Array(Set(Array(stride(from: 0, to: 60, by: 5)) + [minute.wrappedValue])).sorted()
        return HStack(spacing: 4) {
            Picker(title + "（时）", selection: hour) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d 时", $0)).tag($0) }
            }.labelsHidden().pickerStyle(.menu).fixedSize()
            Picker(title + "（分）", selection: minute) {
                ForEach(minutes, id: \.self) { Text(String(format: "%02d 分", $0)).tag($0) }
            }.labelsHidden().pickerStyle(.menu).fixedSize()
        }
    }
    private func summary(_ window: RelayTimeWindow) -> String {
        let clock = { (m: Int) in String(format: "%02d:%02d", m / 60, m % 60) }
        if window.startMinute == window.endMinute { return "全天" }
        return clock(window.startMinute) + "–" + clock(window.endMinute) + (window.endMinute < window.startMinute ? "（到次日）" : "")
    }
}

struct RelayRoutingView: View {
    @Bindable var model: RelayAppModel
    @State private var routing = RelayRouting()
    @State private var updates = RelayClientUpdates()
    @AppStorage("relay.notifications") private var notifications = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            RelayPageTitle(title: "谁来调度，你说了算", subtitle: "设置新任务的默认分工；创建每项任务时仍可调整。")
            RelayCard {
                VStack(alignment: .leading, spacing: 20) {
                    RelayAssignmentBoard(roles: model.store.state.roles, connections: model.store.state.connections,
                        planner: $routing.coordinatorID, executors: $routing.executorIDs, tester: $routing.testerID, reviewer: $routing.reviewerID)
                }
            }
            RelayCard {
                VStack(alignment: .leading, spacing: 18) {
                    Text("并行").font(.headline)
                    Text("同时运行几个任务。默认 2；想更省 token 就设 1（一次只推进一个任务）。每个连接自己的“最大同时会话数”会在这个上限之内再限制一次。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Stepper(value: Binding(get: { routing.maxConcurrentRuns ?? 2 }, set: { routing.maxConcurrentRuns = $0 }), in: 1...4) {
                        HStack {
                            Text("同时运行任务数")
                            Spacer()
                            Text("\(routing.maxConcurrentRuns ?? 2)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                    Divider().opacity(0.5)
                    Text("同一个任务里，依赖已满足、分给不同员工的子任务同时执行（例如 Claude 和 DeepSeek 各做一块）。同一员工一次只做一个；同一连接受它的“最大同时会话数”限制。设 1 恢复逐个执行。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Stepper(value: Binding(get: { routing.maxParallelTasks ?? 2 }, set: { routing.maxParallelTasks = $0 }), in: 1...4) {
                        HStack {
                            Text("同一任务内并行子任务数")
                            Spacer()
                            Text("\(routing.maxParallelTasks ?? 2)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            RelayCard {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(isOn: Binding(get: { routing.autoSwitchMembers != false }, set: { routing.autoSwitchMembers = $0 })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("自动换人").font(.headline)
                            Text("员工额度快用完、快下班、不在工作时间或模型不可用时，交给他的“候选员工”（在员工设置里按顺序指定）。候选都不行就停下，等有人能接手或额度恢复时自动继续。")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }.toggleStyle(.switch)
                    if routing.autoSwitchMembers != false {
                        Stepper(value: Binding(get: { Int(((routing.switchAtQuota ?? 0.99) * 100).rounded()) }, set: { routing.switchAtQuota = Double($0) / 100 }), in: 50...100) {
                            HStack {
                                Text("订阅额度用到这个比例就提前换人")
                                Spacer()
                                Text("\(Int(((routing.switchAtQuota ?? 0.99) * 100).rounded()))%").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                        Stepper(value: Binding(get: { routing.switchBeforeOffMinutes ?? 10 }, set: { routing.switchBeforeOffMinutes = $0 }), in: 0...120, step: 5) {
                            HStack {
                                Text("下班前提前交接")
                                Spacer()
                                Text("\(routing.switchBeforeOffMinutes ?? 10) 分钟").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                        Text("额度读数来自“额度与用量”（Claude Code、Codex 的订阅窗口）。没有候选员工时，快用完也会继续用完剩下的额度。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            RelayCard {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("省 token：及时换新会话").font(.headline)
                        Text("模型每一轮都要把整段会话重读一遍，会话越长越贵。按下面的规则换新会话，新会话只带项目、规则和当前进度。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle("任务结束后，用过的会话下次换新", isOn: Binding(get: { routing.freshSessionAfterRun != false }, set: { routing.freshSessionAfterRun = $0 }))
                        .toggleStyle(.switch)
                    Toggle("会话太长时，在两步之间换新", isOn: Binding(get: { routing.freshSessionThreshold != nil },
                                                           set: { routing.freshSessionAtTokens = $0 ? 100_000 : 0 }))
                        .toggleStyle(.switch)
                    if let limit = routing.freshSessionThreshold {
                        Stepper(value: Binding(get: { limit / 1000 }, set: { routing.freshSessionAtTokens = $0 * 1000 }), in: 40...400, step: 10) {
                            HStack {
                                Text("上下文超过")
                                Spacer()
                                Text("\(limit / 1000)k token").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Stepper(value: Binding(get: { routing.freshSessionIdleMinutes ?? 60 }, set: { routing.freshSessionIdleMinutes = $0 }), in: 0...240, step: 5) {
                        HStack {
                            Text("空闲后换新（缓存已过期、上下文超过 40k）")
                            Spacer()
                            Text((routing.freshSessionIdleMinutes ?? 60) == 0 ? "关闭" : "\(routing.freshSessionIdleMinutes ?? 60) 分钟").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                    Picker("每天例行换新", selection: Binding(get: { routing.freshSessionDailyHour ?? 4 }, set: { routing.freshSessionDailyHour = $0 })) {
                        Text("关闭").tag(-1)
                        ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                    }
                    Stepper(value: Binding(get: { routing.compactPercent ?? 25 }, set: { routing.claudeCompactPercent = $0 <= 25 ? 0 : $0 }), in: 25...95, step: 5) {
                        HStack {
                            Text("Claude Code 调用内提前压缩上下文")
                            Spacer()
                            Text(routing.compactPercent.map { "用到 \($0)%" } ?? "关闭（默认约 95%）").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                    Text("换新的会话带上项目、规则、进度和这位员工上次的回复（工作笔记），只发一次。失败的任务保留会话，方便从失败处继续；提问或调用中途不会换。上下文大小目前能从 Claude Code 和 Codex 读到，其他客户端只按任务结束和每日换新。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            RelayPlatformRunnerCard(model: model)
            RelayClientUpdatesCard(updates: updates)
            RelayWeChatCard(model: model)
            RelayCard {
                VStack(alignment: .leading, spacing: 18) {
                    Text("会话异常恢复").font(.headline)
                    Text("会话资源异常时，先在原会话发送“继续”，达到次数后在原席位顺序换新。原调用未确认结束时暂停，不会再开会话。").font(.system(size: 12)).foregroundStyle(.secondary)
                    Stepper("原会话最多继续 \(routing.continueAttempts) 次", value: $routing.continueAttempts, in: 0...10)
                    Stepper("最多顺序换新 \(routing.newSessionAttempts) 次", value: $routing.newSessionAttempts, in: 0...3)
                    Divider()
                    Text("Codex：一个会话出错就在原会话重试，连续出错这么多次后新开会话（带交接说明）继续；新开的会话也都失败才暂停任务。额度、登录和被拒绝的工具调用不在此列。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Stepper("每个会话最多尝试 \(routing.codexTriesPerSession ?? 3) 次", value: Binding(get: { routing.codexTriesPerSession ?? 3 }, set: { routing.codexTriesPerSession = $0 }), in: 1...10)
                    Stepper("最多新开 \(routing.codexNewSessions ?? 5) 个会话", value: Binding(get: { routing.codexNewSessions ?? 5 }, set: { routing.codexNewSessions = $0 }), in: 0...10)
                    TextField("继续间隔（秒）", value: $routing.continueDelaySeconds, format: .number)
                    Text("交接提示词").font(.system(size: 12, weight: .medium))
                    TextEditor(text: $routing.handoffPrompt).font(.system(size: 12)).frame(height: 125)
                    Text("自动附加用户目标、项目规则、当前步骤、已完成结果、测试证据与待办。").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Toggle("任务等待处理时发送系统通知", isOn: Binding(get: { notifications }, set: { enabled in
                    if !enabled { notifications = false; return }
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { allowed, error in
                        Task { @MainActor in notifications = allowed; if let error { model.error = error.localizedDescription }; if !allowed && error == nil { model.notice = "通知未获授权，可在系统设置中开启 Dravion 通知。" } }
                    }
                }))
                Spacer()
                Button("保存调度设置") { model.perform { var next = model.store.state; next.routing = routing; try model.store.commit(next); model.notice = "调度设置已保存。" } }.buttonStyle(.borderedProminent)
            }
        }.onAppear { routing = model.store.state.routing }
    }
}
