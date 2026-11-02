import SwiftUI
import RelayCore

// MARK: - Project bar

/// Projects that have runs, as tabs across the top of the dashboard. Choosing a project shows its runs underneath;
/// choosing a run opens it below. Live projects carry a breathing dot.
struct RelayProjectBar: View {
    @Bindable var model: RelayAppModel
    let current: RelayRun
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection

    private var projects: [(project: RelayProject, runs: [RelayRun])] {
        var order: [String] = []
        var grouped: [String: [RelayRun]] = [:]
        for run in model.store.state.runs where run.archivedAt == nil || run.id == current.id {
            if grouped[run.project.id] == nil { order.append(run.project.id) }
            grouped[run.project.id, default: []].append(run)
        }
        return order.compactMap { id in
            guard let runs = grouped[id], let first = runs.first else { return nil }
            return (model.store.state.projects.first { $0.id == id } ?? first.project, runs)
        }
    }

    var body: some View {
        let items = projects
        let runs = items.first { $0.project.id == current.project.id }?.runs ?? [current]
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items, id: \.project.id) { item in
                        projectTab(item.project, runs: item.runs)
                    }
                }.padding(4)
            }
            .background(RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if runs.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(runs) { run in runTab(run) }
                    }.padding(.vertical, 2)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: current.id)
        .accessibilityIdentifier("project-bar")
    }

    private func projectTab(_ project: RelayProject, runs: [RelayRun]) -> some View {
        let selected = project.id == current.project.id
        let live = runs.contains { $0.status.isWorking && $0.waitingForSession == nil }
        let attention = runs.contains { $0.status == .paused || $0.status == .interrupted }
        return Button {
            guard !selected, let run = runs.first(where: { !$0.status.isTerminal }) ?? runs.first else { return }
            model.selectRun(run.id)
        } label: {
            HStack(spacing: 8) {
                DravionIcon(name: selected ? "folder-open" : "folder-simple", duotone: selected, size: 15)
                Text(project.name.isEmpty ? URL(fileURLWithPath: project.path).lastPathComponent : project.name)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                Text("\(runs.count)").font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(Color.primary.opacity(0.06), in: Capsule())
                if live { RelayPulseDot(color: RelayStyle.accent) }
                else if attention { Circle().fill(.orange).frame(width: 6, height: 6) }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(RelayStyle.surface)
                        .shadow(color: .black.opacity(0.07), radius: 3, y: 1)
                        .matchedGeometryEffect(id: "project", in: selection)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(selected ? .primary : .secondary)
        .help(project.path)
        .accessibilityIdentifier("project-tab-\(project.id)")
    }

    private func runTab(_ run: RelayRun) -> some View {
        let selected = run.id == current.id
        return Button { model.selectRun(run.id) } label: {
            HStack(spacing: 6) {
                if run.status.isWorking && run.waitingForSession == nil { RelayPulseDot(color: RelayStyle.status(run.status), size: 5) }
                else { Circle().fill(RelayStyle.status(run.status)).frame(width: 5, height: 5) }
                Text(run.input.title).lineLimit(1).frame(maxWidth: 220)
                Text(run.createdAt.formatted(.relative(presentation: .named))).foregroundStyle(.tertiary)
            }
            .font(.system(size: 11, weight: selected ? .medium : .regular))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(selected ? Color.primary.opacity(0.07) : .clear, in: Capsule())
            .overlay(Capsule().stroke(selected ? Color.primary.opacity(0.18) : RelayStyle.border))
            .contentShape(Capsule())
        }.buttonStyle(.plain).foregroundStyle(selected ? .primary : .secondary)
    }
}

// MARK: - Node model

/// A node of the run graph: a stage, and the role that holds it (none for the local test run).
struct RelayNodeKey: Hashable {
    var stage: RelayRunStatus
    var roleID: String?
}

enum RelayNodeState: Equatable {
    case pending, active, waiting, done, failed
    var label: String {
        switch self {
        case .pending: return "未开始"
        case .active: return "正在执行"
        case .waiting: return "等待恢复"
        case .done: return "已完成"
        case .failed: return "失败"
        }
    }
    var color: Color {
        switch self {
        case .pending: return .secondary
        case .active: return RelayStyle.accent
        case .waiting: return .orange
        case .done: return .green
        case .failed: return .red
        }
    }
}

extension RelayRun {
    /// 0 planning · 1 executing · 2 testing · 3 reviewing · 4 finished.
    var stageIndex: Int {
        if status == .succeeded { return 4 }
        switch status {
        case .planning: return 0
        case .executing: return 1
        case .testing: return 2
        case .reviewing: return 3
        default:
            switch phase {
            case .planning: return 0
            case .execution: return 1
            case .tests, .quality: return 2
            case .review: return 3
            case .complete: return 4
            }
        }
    }

    func nodeState(_ key: RelayNodeKey) -> RelayNodeState {
        let order: [RelayRunStatus: Int] = [.planning: 0, .executing: 1, .testing: 2, .reviewing: 3]
        let index = order[key.stage] ?? 0
        let here = stageIndex == index
        let stopped = status == .paused || status == .interrupted || waitingForSession != nil || status == .queued
        if key.stage == .executing, let roleID = key.roleID {
            let mine = tasks.filter { $0.task.roleId == roleID }
            if mine.contains(where: { $0.status == .failed }) && (status == .failed || !here) { return .failed }
            if here && (currentRoleID == roleID || mine.contains(where: { $0.status == .running })) {
                if status == .failed { return .failed }
                return stopped ? .waiting : (status.isWorking ? .active : .pending)
            }
            if !mine.isEmpty && mine.allSatisfy({ $0.status == .succeeded }) { return .done }
            if mine.contains(where: { $0.status == .paused }) { return .waiting }
            return stageIndex > index ? .done : .pending
        }
        if stageIndex > index { return .done }
        guard here else { return .pending }
        if status == .failed || status == .budgetExceeded { return .failed }
        if stopped { return .waiting }
        return status.isWorking ? .active : .pending
    }
}

/// What a node produced, read from the run's own events and results; nothing is recomputed or re-run.
struct RelayNodeArtifacts {
    struct FileChange: Identifiable {
        var path: String
        var edits: Int
        var lastDate: Date
        var diffs: [String]
        var created: Bool
        var id: String { path }
    }
    struct Command: Identifiable {
        var id: String
        var date: Date
        var command: String
        var output: String
        var exitCode: Int?
    }
    struct Output: Identifiable {
        var id: String
        var title: String
        var status: String
        var text: String
    }
    var files: [FileChange] = []
    var commands: [Command] = []
    var outputs: [Output] = []
    var events: [RelayEvent] = []

    init(run: RelayRun, key: RelayNodeKey, events all: [RelayEvent]) {
        let tasks = run.tasks.filter { key.stage != .executing || $0.task.roleId == key.roleID }
        let taskIDs = Set(tasks.map(\.id))
        events = all.filter { event in
            switch key.stage {
            case .executing: return event.roleID == key.roleID && (event.taskID == nil || taskIDs.contains(event.taskID!))
            case .testing where key.roleID == nil: return event.kind == .test
            default: return key.roleID != nil && event.roleID == key.roleID
            }
        }
        var byPath: [String: FileChange] = [:]
        for event in events where event.kind == .tool {
            guard let data = event.message.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for change in Self.fileChanges(json) {
                let path = Self.relative(change.path, root: run.root.isEmpty ? run.project.path : run.root)
                var entry = byPath[path] ?? FileChange(path: path, edits: 0, lastDate: event.date, diffs: [], created: change.created)
                entry.edits += 1; entry.lastDate = event.date
                if !change.diff.isEmpty { entry.diffs.append(change.diff) }
                byPath[path] = entry
            }
            if let command = Self.command(json) {
                commands.append(.init(id: event.id, date: event.date, command: command.0, output: command.1, exitCode: command.2))
            }
        }
        files = byPath.values.sorted { $0.lastDate > $1.lastDate }

        switch key.stage {
        case .planning:
            if let plan = run.plan {
                let list = plan.tasks.enumerated().map { index, task in "\(index + 1). \(task.title) → \(run.roles.first { $0.id == task.roleId }?.name ?? task.roleId)" }
                outputs.append(.init(id: "plan", title: "任务拆分", status: "\(plan.tasks.count) 项", text: ([plan.summary, ""] + list).joined(separator: "\n")))
            }
        case .executing:
            outputs = tasks.filter { !$0.output.isEmpty }.map { .init(id: $0.id, title: $0.task.title, status: $0.status.label, text: $0.output) }
        case .testing:
            if !run.testOutput.isEmpty {
                outputs.append(.init(id: "test", title: "实际测试", status: run.testExitCode.map { "退出码 \($0)" } ?? "运行中", text: run.testOutput))
            }
            if key.roleID != nil, let quality = run.quality { outputs.append(Self.review("quality", "质量检查", quality)) }
        case .reviewing:
            if let review = run.review { outputs.append(Self.review("review", "最终复审", review)) }
            if !run.output.isEmpty { outputs.append(.init(id: "final", title: "完成输出", status: run.status.label, text: run.output)) }
        default: break
        }
    }

    var isEmpty: Bool { files.isEmpty && commands.isEmpty && outputs.isEmpty && events.isEmpty }

    private static func review(_ id: String, _ title: String, _ review: RelayReview) -> Output {
        .init(id: id, title: title, status: review.passed ? "通过" : "需返工",
              text: ([review.summary] + review.issues.map { "• " + $0 }).joined(separator: "\n"))
    }
    private static func relative(_ path: String, root: String) -> String {
        guard !root.isEmpty else { return path }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
    /// Claude Code `Edit`/`MultiEdit`/`Write` and Codex `file_change`, as in `RelayEventLine.describeTool`.
    private static func fileChanges(_ json: [String: Any]) -> [(path: String, diff: String, created: Bool)] {
        let input = json["input"] as? [String: Any] ?? [:]
        if let name = json["name"] as? String {
            guard let path = input["file_path"] as? String, !path.isEmpty else { return [] }
            switch name {
            case "Write":
                let content = (input["content"] as? String ?? "").components(separatedBy: "\n").prefix(400).map { "+" + $0 }
                return [(path, content.joined(separator: "\n"), true)]
            case "Edit", "MultiEdit":
                let edits = input["edits"] as? [[String: Any]] ?? [input]
                let diff = edits.map { edit in
                    let old = (edit["old_string"] as? String ?? "").components(separatedBy: "\n").map { "-" + $0 }
                    let new = (edit["new_string"] as? String ?? "").components(separatedBy: "\n").map { "+" + $0 }
                    return (old + new).joined(separator: "\n")
                }.joined(separator: "\n@@\n")
                return [(path, diff, false)]
            default: return []
            }
        }
        let item = json["item"] as? [String: Any] ?? json
        guard item["type"] as? String == "file_change" else { return [] }
        return (item["changes"] as? [[String: Any]] ?? []).compactMap { change in
            guard let path = change["path"] as? String, !path.isEmpty else { return nil }
            return (path, change["diff"] as? String ?? "", (change["kind"] as? String) == "add")
        }
    }
    private static func command(_ json: [String: Any]) -> (String, String, Int?)? {
        if json["name"] as? String == "Bash" {
            return ((json["input"] as? [String: Any])?["command"] as? String ?? "", "", nil)
        }
        let item = json["item"] as? [String: Any] ?? json
        guard item["type"] as? String == "command_execution" else { return nil }
        return (item["command"] as? String ?? "",
                item["aggregated_output"] as? String ?? item["aggregatedOutput"] as? String ?? "",
                item["exit_code"] as? Int ?? item["exitCode"] as? Int)
    }
}

// MARK: - Node inspector

/// Everything one node produced: changed files with their diffs, code and results, commands, and its run log.
struct RelayNodeInspector: View {
    let model: RelayAppModel
    let run: RelayRun
    let key: RelayNodeKey
    var framed = true
    let close: () -> Void
    enum Tab: String, CaseIterable { case files = "文件", outputs = "代码与结果", commands = "命令", log = "执行记录" }
    @State private var tab: Tab = .files
    @State private var openFile: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var role: RelayRole? { key.roleID.flatMap { id in run.roles.first { $0.id == id } } }
    private var title: String {
        switch key.stage {
        case .planning: return "规划"
        case .executing: return "执行"
        case .testing: return key.roleID == nil ? "本机实际测试" : "质量检查"
        case .reviewing: return "复审"
        default: return key.stage.label
        }
    }

    var body: some View {
        let artifacts = RelayNodeArtifacts(run: run, key: key, events: model.store.events[run.id] ?? [])
        let state = run.nodeState(key)
        SwiftUI.Group {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    RelayAgentAvatar(icon: Self.icon(key.stage), color: role.map { RelayStyle.color($0.color) } ?? RelayStyle.accent, state: state, size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(role?.name ?? title).font(.system(size: 15, weight: .semibold))
                            RelayBadge(text: state.label, color: state.color)
                        }
                        Text([title, role.map { $0.model.isEmpty ? "客户端默认模型" : $0.model }, key.roleID.flatMap { run.roleSessions[$0] }.map { "会话 " + String($0.prefix(12)) }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if state == .active { RelayTypingDots(color: RelayStyle.accent) }
                    if let role, !run.status.isTerminal { RelayRoleConfigChip(model: model, run: run, role: role, maxWidth: nil) }
                    Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("关闭（Esc）")
                }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
                HStack(spacing: 4) {
                    ForEach(Tab.allCases, id: \.self) { item in
                        let count: Int = switch item {
                        case .files: artifacts.files.count
                        case .outputs: artifacts.outputs.count
                        case .commands: artifacts.commands.count
                        case .log: artifacts.events.count
                        }
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { tab = item }
                        } label: {
                            HStack(spacing: 5) {
                                Text(item.rawValue)
                                if count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(.secondary) }
                            }
                            .font(.system(size: 12, weight: tab == item ? .semibold : .regular))
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(tab == item ? Color.primary.opacity(0.07) : .clear, in: Capsule())
                            .contentShape(Capsule())
                        }.buttonStyle(.plain).foregroundStyle(tab == item ? .primary : .secondary)
                    }
                    Spacer()
                }.padding(.horizontal, 16).padding(.bottom, 12)
                Divider().opacity(0.5)
                Group {
                    switch tab {
                    case .files: files(artifacts.files)
                    case .outputs: outputs(artifacts.outputs)
                    case .commands: commands(artifacts.commands)
                    case .log:
                        RelayTerminalLog(events: artifacts.events, roles: run.roles).frame(minHeight: 260, maxHeight: 460)
                    }
                }
                .padding(16)
                .id(tab)
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .relayFramed(framed, padding: 0)
        .onAppear { tab = Self.defaultTab(artifacts) }
        .onChange(of: key) { _, _ in openFile = nil; tab = Self.defaultTab(RelayNodeArtifacts(run: run, key: key, events: model.store.events[run.id] ?? [])) }
        .accessibilityIdentifier("node-inspector")
    }

    static func icon(_ stage: RelayRunStatus) -> String {
        switch stage {
        case .executing: return "terminal-window"
        case .testing: return "cpu"
        case .reviewing: return "users-three"
        default: return "tree-structure"
        }
    }
    private static func defaultTab(_ artifacts: RelayNodeArtifacts) -> Tab {
        if !artifacts.files.isEmpty { return .files }
        if !artifacts.outputs.isEmpty { return .outputs }
        if !artifacts.commands.isEmpty { return .commands }
        return .log
    }

    private func empty(_ text: String) -> some View {
        VStack(spacing: 8) {
            DravionIcon(name: "files", size: 22).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 110)
    }

    @ViewBuilder private func files(_ files: [RelayNodeArtifacts.FileChange]) -> some View {
        if files.isEmpty { empty("这个节点还没有修改文件") } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(files) { file in
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9)) { openFile = openFile == file.path ? nil : file.path }
                        } label: {
                            HStack(spacing: 10) {
                                DravionIcon(name: "file-code", size: 16).foregroundStyle(.secondary)
                                Text(file.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
                                if file.created { RelayBadge(text: "新建", color: .green) }
                                Spacer()
                                let (added, removed) = Self.lineCounts(file.diffs)
                                if added > 0 { Text("+\(added)").foregroundStyle(.green) }
                                if removed > 0 { Text("−\(removed)").foregroundStyle(.red) }
                                Text("\(file.edits) 次").foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                                    .rotationEffect(.degrees(openFile == file.path ? 90 : 0))
                            }
                            .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                            .padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if openFile == file.path {
                            HStack {
                                Button("在访达中显示") {
                                    let root = run.root.isEmpty ? run.project.path : run.root
                                    let url = file.path.hasPrefix("/") ? URL(fileURLWithPath: file.path) : URL(fileURLWithPath: root).appendingPathComponent(file.path)
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                                Button("复制路径") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.path, forType: .string) }
                                Spacer()
                            }.buttonStyle(.borderless).font(.system(size: 11)).padding(.horizontal, 10).padding(.bottom, 6)
                            RelayCodeOutput(text: file.diffs.isEmpty ? "客户端没有报告这次修改的内容。" : file.diffs.joined(separator: "\n@@\n"))
                                .padding(.horizontal, 6).padding(.bottom, 8)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .background(openFile == file.path ? RelayStyle.sunken : .clear, in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
    }

    @ViewBuilder private func outputs(_ outputs: [RelayNodeArtifacts.Output]) -> some View {
        if outputs.isEmpty { empty("这个节点还没有产出代码或结果") } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(outputs) { output in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(output.title).font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(output.status).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        RelayCodeOutput(text: output.text)
                    }
                }
            }
        }
    }

    @ViewBuilder private func commands(_ commands: [RelayNodeArtifacts.Command]) -> some View {
        if commands.isEmpty { empty("这个节点还没有执行命令") } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(commands.reversed()) { command in
                    DisclosureGroup {
                        Text(RelaySyntaxText.render(command.output.isEmpty ? "（客户端没有报告输出）" : String(command.output.prefix(20_000)), code: true))
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(GhosttyPalette.background, in: RoundedRectangle(cornerRadius: 8))
                    } label: {
                        HStack(spacing: 8) {
                            Text(command.date.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary).monospacedDigit()
                            Text("$").foregroundStyle(.secondary)
                            Text(command.command).lineLimit(1).truncationMode(.tail)
                            Spacer()
                            if let code = command.exitCode {
                                Text(code == 0 ? "✓" : "退出码 \(code)").foregroundStyle(code == 0 ? .green : .red)
                            }
                        }.font(.system(size: 11.5, design: .monospaced))
                    }
                }
            }
        }
    }

    private static func lineCounts(_ diffs: [String]) -> (Int, Int) {
        var added = 0, removed = 0
        for diff in diffs {
            for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("+") && !line.hasPrefix("+++") { added += 1 }
                else if line.hasPrefix("-") && !line.hasPrefix("---") { removed += 1 }
            }
        }
        return (added, removed)
    }
}

// MARK: - Live agent banner

/// "Who is working right now": the active agent's avatar with its halo, what it is doing, and its latest action,
/// which crossfades as new events arrive.
struct RelayLiveAgentBanner: View {
    let model: RelayAppModel
    let run: RelayRun
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let role = run.roles.first { $0.id == run.currentRoleID }
        let stage = run.status.isWorking ? run.status : [.planning, .executing, .testing, .reviewing][min(run.stageIndex, 3)]
        let state = run.nodeState(.init(stage: stage, roleID: run.phase == .tests ? nil : role?.id))
        let task = run.tasks.first { $0.id == run.currentTaskID }?.task.title
        let latest = (model.store.events[run.id] ?? []).last { event in
            event.roleID == run.currentRoleID && [.tool, .text, .test].contains(event.kind)
        }.map(RelayEventLine.from)
        HStack(spacing: 14) {
            RelayAgentAvatar(icon: RelayNodeInspector.icon(stage), color: role.map { RelayStyle.color($0.color) } ?? RelayStyle.accent, state: state, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if state == .active {
                        RelayShimmerText(text: "\(role?.name ?? "本机测试") 正在\(run.phase.label)")
                            .font(.system(size: 13, weight: .semibold))
                    } else {
                        Text("\(role?.name ?? run.phase.label) · \(state == .waiting ? (run.waitingForSession ?? "等待恢复") : run.status.label)")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    if state == .active { RelayTypingDots(color: RelayStyle.accent, size: 4) }
                }
                if let task { Text(task).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                if let latest {
                    HStack(spacing: 6) {
                        if !latest.verb.isEmpty { Text(latest.verb).fontWeight(.semibold) }
                        Text(latest.body.components(separatedBy: "\n").first ?? "").lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .id(latest.id)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity.combined(with: .offset(y: -8))))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: latest?.id)
            Spacer()
            RelayStageProgress(run: run)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(state.color.opacity(state == .active ? 0.05 : 0.03))
            if state == .active && !reduceMotion { RelaySweep(color: RelayStyle.accent).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)) }
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(state.color.opacity(0.18)))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: state)
        .accessibilityElement(children: .combine)
    }
}

/// Four segments (plan, execute, test, review) that fill as the run advances; the current one shimmers.
struct RelayStageProgress: View {
    let run: RelayRun
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let index = run.stageIndex
        HStack(spacing: 4) {
            ForEach(0..<4, id: \.self) { step in
                Capsule()
                    .fill(step < index ? Color.green.opacity(0.75) : step == index ? RelayStyle.status(run.status).opacity(0.85) : Color.primary.opacity(0.1))
                    .frame(width: step == index ? 28 : 16, height: 5)
                    .overlay {
                        if step == index && run.status.isWorking && run.waitingForSession == nil && !reduceMotion {
                            RelaySweep(color: .white, band: 0.5, period: 1.4, strength: 0.7).clipShape(Capsule())
                        }
                    }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8), value: index)
        .help(["规划", "执行", "测试", "复审"].prefix(min(index + 1, 4)).joined(separator: " → "))
    }
}

// MARK: - Motion primitives

/// The agent's tile. Active: a comet ring orbits it and a halo breathes; done: a check pops in; pending: dimmed.
struct RelayAgentAvatar: View {
    var icon: String
    var color: Color
    var state: RelayNodeState
    var size: CGFloat = 52
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        let radius = size * 0.29
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                if state == .active {
                    RoundedRectangle(cornerRadius: radius + 6, style: .continuous)
                        .fill(RelayStyle.accent.opacity(breathe ? 0.0 : 0.22))
                        .frame(width: size + 12, height: size + 12)
                        .scaleEffect(breathe ? 1.18 : 0.94)
                    if !reduceMotion {
                        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                            let angle = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4 * 360
                            RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                                .strokeBorder(AngularGradient(colors: [RelayStyle.accent.opacity(0), RelayStyle.accent.opacity(0.15), RelayStyle.accent],
                                                              center: .center, angle: .degrees(angle)), lineWidth: 2)
                                .frame(width: size + 6, height: size + 6)
                        }
                    }
                }
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(color.opacity(state == .pending ? 0.06 : 0.12))
                    .frame(width: size, height: size)
                    .overlay(DravionIcon(name: icon, duotone: state == .active, size: size * 0.44).foregroundStyle(color))
                    .opacity(state == .pending ? 0.55 : 1)
                    .scaleEffect(state == .active && breathe ? 1.03 : 1)
            }
            .frame(width: size + 12, height: size + 12)
            badge.offset(x: -4, y: -4)
        }
        .onAppear { startBreathing() }
        .onChange(of: state) { _, _ in startBreathing() }
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.7), value: state)
    }

    @ViewBuilder private var badge: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark").font(.system(size: size * 0.16, weight: .bold)).foregroundStyle(.white)
                .frame(width: size * 0.3, height: size * 0.3).background(Color.green, in: Circle())
                .overlay(Circle().stroke(RelayStyle.surface, lineWidth: 2))
                .transition(.scale(scale: 0.2).combined(with: .opacity))
        case .failed:
            Image(systemName: "xmark").font(.system(size: size * 0.15, weight: .bold)).foregroundStyle(.white)
                .frame(width: size * 0.3, height: size * 0.3).background(Color.red, in: Circle())
                .overlay(Circle().stroke(RelayStyle.surface, lineWidth: 2))
                .transition(.scale(scale: 0.2).combined(with: .opacity))
        case .waiting:
            Image(systemName: "pause.fill").font(.system(size: size * 0.13, weight: .bold)).foregroundStyle(.white)
                .frame(width: size * 0.3, height: size * 0.3).background(Color.orange, in: Circle())
                .overlay(Circle().stroke(RelayStyle.surface, lineWidth: 2))
                .transition(.scale(scale: 0.2).combined(with: .opacity))
        case .active:
            RelayPulseDot(color: .green, size: size * 0.17).overlay(Circle().stroke(RelayStyle.surface, lineWidth: 2))
                .transition(.scale.combined(with: .opacity))
        case .pending: EmptyView()
        }
    }

    private func startBreathing() {
        guard state == .active, !reduceMotion else { breathe = false; return }
        breathe = false
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
    }
}

/// A status dot with a ring that expands and fades, like a heartbeat.
struct RelayPulseDot: View {
    var color: Color
    var size: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .background(
                Circle().fill(color.opacity(pulse ? 0 : 0.5)).scaleEffect(pulse ? 2.6 : 1)
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

/// Three dots that rise in turn: "working on it".
struct RelayTypingDots: View {
    var color: Color
    var size: CGFloat = 5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.7) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = (sin((t * 2 * .pi / 1.1) - Double(index) * 0.9) + 1) / 2
                    Circle().fill(color).frame(width: size, height: size)
                        .opacity(reduceMotion ? 0.7 : 0.3 + 0.7 * phase)
                        .offset(y: reduceMotion ? 0 : -size * 0.6 * phase)
                }
            }
        }
        .frame(height: size * 2.2)
        .accessibilityHidden(true)
    }
}

/// Text with a soft highlight sweeping across it.
struct RelayShimmerText: View {
    var text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Text(text).foregroundStyle(.primary)
            .overlay {
                if !reduceMotion {
                    RelaySweep(color: RelayStyle.accent, band: 0.35, period: 2.2, strength: 0.95).mask(Text(text))
                }
            }
    }
}

/// A diagonal band of light that travels left to right on a loop.
struct RelaySweep: View {
    var color: Color
    var band: CGFloat = 0.3
    var period: Double = 2.6
    var strength: Double = 0.18
    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                let progress = CGFloat(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period)
                let width = geometry.size.width
                LinearGradient(colors: [color.opacity(0), color.opacity(strength), color.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: width * band)
                    .offset(x: -width * band + progress * width * (1 + band))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Role config popover

/// The model and thinking level of one role in this run, changed in place. The call in progress keeps going;
/// the role's next call uses the new settings (`RelayScheduler.reconfigureRole`).
struct RelayRoleConfigCard: View {
    @Bindable var model: RelayAppModel
    let run: RelayRun
    let role: RelayRole
    var done: () -> Void = {}
    @State private var selected = ""
    @State private var effort = "default"
    @State private var saveAsDefault = false
    @State private var busy = false
    @State private var error: String?
    private static let efforts = ["default", "low", "medium", "high", "xhigh", "max"]

    var body: some View {
        let connection = run.connections.first { $0.id == role.connectionID }
        let effective = model.effectiveModel(role, connection: connection)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("当前生效").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(effective.model).font(.system(size: 12, design: .monospaced))
                Text(effective.detail).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RelayStyle.color(role.color).opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 6) {
                Text("模型").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                RelayModelField(model: model, connectionID: role.connectionID, selected: $selected)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("思考级别").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Picker("思考级别", selection: $effort) {
                    ForEach(Self.efforts, id: \.self) { Text($0 == "default" ? "默认" : $0).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            Toggle("同时保存为这个员工的默认配置", isOn: $saveAsDefault).font(.system(size: 12))
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text(run.status.isWorking && run.currentRoleID == role.id ? "当前调用继续，下一次调用生效" : "下一次调用生效")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(busy ? "检查中…" : "应用") {
                    busy = true; error = nil
                    Task {
                        do { try await model.scheduler.reconfigureRole(run.id, roleID: role.id, model: selected, effort: effort, saveAsDefault: saveAsDefault); done() }
                        catch { self.error = model.store.redact(error.localizedDescription) }
                        busy = false
                    }
                }
                .buttonStyle(.borderedProminent).disabled(busy || (selected == role.model && effort == role.effort))
                .accessibilityIdentifier("apply-role-config")
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 20)
        .onAppear { selected = role.model; effort = Self.efforts.contains(role.effort) ? role.effort : "default" }
    }
}

/// The model and effort under a graph node, as a chip that opens `RelayRoleConfigCard` as a card above the page.
struct RelayRoleConfigChip: View {
    @Bindable var model: RelayAppModel
    let run: RelayRun
    let role: RelayRole
    /// nil: as wide as the model name needs (inspector header); a number: fits the graph node, shrinking text first.
    var maxWidth: CGFloat? = 146
    @State private var hovering = false
    var body: some View {
        let connection = run.connections.first { $0.id == role.connectionID }
        let effective = model.effectiveModel(role, connection: connection)
        let color = RelayStyle.color(role.color)
        Button {
            let runID = run.id, roleID = role.id
            model.present("role-config-\(roleID)", width: 480) { RelayRoleConfigPanel(model: model, runID: runID, roleID: roleID) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 8, weight: .semibold))
                Text(effective.model + (role.effort != "default" ? " · \(role.effort)" : ""))
                    .lineLimit(1).minimumScaleFactor(0.7).truncationMode(.middle)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(hovering ? 0.18 : 0.10), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.25)))
            .frame(maxWidth: maxWidth)
            .fixedSize(horizontal: maxWidth == nil, vertical: false)
        }
        .buttonStyle(.plain).help("\(effective.model)\(role.effort != "default" ? " · 思考 \(role.effort)" : "")：点击更换模型和思考级别")
        .onHover { hovering = $0 }
        .accessibilityIdentifier("role-config-\(role.id)")
    }
}

/// `RelayRoleConfigCard` with its header, looked up live by id so it follows the run while open.
struct RelayRoleConfigPanel: View {
    @Bindable var model: RelayAppModel
    let runID: String
    let roleID: String
    var body: some View {
        if let run = model.store.state.runs.first(where: { $0.id == runID }), let role = run.roles.first(where: { $0.id == roleID }) {
            let connection = run.connections.first { $0.id == role.connectionID }
            VStack(alignment: .leading, spacing: 0) {
                RelayOverlayHeader(icon: "sliders-horizontal", color: RelayStyle.color(role.color), title: "\(role.name) · 模型与思考级别",
                                   subtitle: (connection?.name ?? "连接缺失") + " · 仅这次任务", close: model.dismissOverlay)
                RelayRoleConfigCard(model: model, run: run, role: role) { model.dismissOverlay() }
            }
        }
    }
}

/// A graph node's inspector as a card above the page, following the run live.
struct RelayNodePanel: View {
    let model: RelayAppModel
    let runID: String
    let key: RelayNodeKey
    var body: some View {
        if let run = model.store.state.runs.first(where: { $0.id == runID }) {
            RelayFitScroll {
                RelayNodeInspector(model: model, run: run, key: key, framed: false) { model.dismissOverlay() }
            }
        }
    }
}
