import SwiftUI
import UniformTypeIdentifiers
import RelayCore

@MainActor enum RelayDialogs {
    static func directory() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "选择项目"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
    static func attachments() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.prompt = "添加文本附件"
        return panel.runModal() == .OK ? panel.urls : []
    }
}

struct RelayRolePicker: View {
    var title: String
    var roles: [RelayRole]
    @Binding var selection: String
    var body: some View {
        Picker(title, selection: $selection) {
            Text("请选择角色").tag("")
            ForEach(roles.filter(\.enabled)) { Text($0.name).tag($0.id) }
        }
    }
}

struct RelayComposer: View {
    @Bindable var model: RelayAppModel
    @State private var input = RelayRunInput(title: "", goal: "", projectID: "")
    @State private var direct = false
    @State private var directRole = ""
    @State private var submitting = false
    @State private var error: String?
    @State private var speech = RelaySpeechInput()
    @State private var addingProject: RelayProject?
    @State private var askGroupName = false
    @State private var groupName = ""
    @State private var newRole: RelayRole?
    private var roles: [RelayRole] { model.store.state.roles }
    /// Directories the goal names that lie outside the chosen project. Every subtask runs in the project
    /// directory only, so a goal spanning several worktrees must become one task per worktree.
    private var foreignDirectories: [String] {
        guard let project = model.store.state.projects.first(where: { $0.id == input.projectID }) else { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let root = URL(fileURLWithPath: project.path).standardizedFileURL.path
        let found = input.goal.matches(of: /(~|\/Users\/[^\/\s]+)(\/[A-Za-z0-9._\-]+)+/).map { String($0.output.0) }
        var seen = Set<String>()
        return found.filter { raw in
            let path = URL(fileURLWithPath: raw.hasPrefix("~") ? home + raw.dropFirst() : raw).standardizedFileURL.path
            return !RelayWorkspace.overlaps(root, path) && seen.insert(path).inserted
        }
    }
    /// What still blocks "开始调度", in the order the form asks for it; shown next to the button.
    private var missing: [String] {
        var items: [String] = []
        if input.projectID.isEmpty { items.append("选择或添加工作项目") }
        if direct {
            if directRole.isEmpty { items.append("选择接收角色") }
        } else {
            if input.executorIDs.isEmpty { items.append("至少安排一位执行员工") }
            if input.executorIDs.count > 1, input.plannerID.isEmpty { items.append("几位执行员工需要一位总调度来分工") }
        }
        return items
    }
    private var involved: [RelayRole] {
        let ids = Set([input.testerID, input.reviewerID] + (direct ? [directRole] : [input.plannerID] + input.executorIDs))
        return roles.filter { ids.contains($0.id) }
    }
    var body: some View {
        VStack(spacing: 0) {
            RelaySheetHeader(title: "把任务交给团队", close: { model.showsComposer = false })
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    TextField("任务名称（可选）", text: $input.title).relayField().accessibilityIdentifier("task-title")
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text("你想完成什么？").font(.headline)
                            Text("可以先不写，建好后在任务底部发送").font(.caption).foregroundStyle(.tertiary)
                            Spacer()
                            Button {
                                if speech.isRecording { speech.stop() }
                                else { Task { do { try await speech.start() } catch { self.error = error.localizedDescription } } }
                            } label: { Label(speech.isRecording ? "结束听写" : "语音输入", systemImage: speech.isRecording ? "stop.circle.fill" : "mic") }
                                .foregroundStyle(speech.isRecording ? .red : .secondary)
                        }
                        TextEditor(text: $input.goal).font(.system(size: 14)).scrollContentBackground(.hidden)
                            .padding(8).frame(height: 115).background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(RelayStyle.border)).accessibilityIdentifier("task-goal")
                        if !speech.transcript.isEmpty {
                            Text(speech.transcript).font(.system(size: 12)).foregroundStyle(.secondary)
                            Button("将听写加入目标") { input.goal += (input.goal.isEmpty ? "" : "\n") + speech.transcript; speech.clear() }
                        }
                        if let problem = speech.error { Text(problem).font(.caption).foregroundStyle(.red) }
                        HStack {
                            Button { addAttachments() } label: { Label("添加文本附件", systemImage: "paperclip") }
                            Text("每个附件不超过 128 KB；发送前可以修改目标。").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(input.attachments) { attachment in
                            HStack {
                                Label(attachment.name, systemImage: "doc.text").font(.caption)
                                Spacer()
                                Button { input.attachments.removeAll { $0.id == attachment.id } } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                            }
                        }
                    }
                    // The project is a folder: pick one already used, or choose any folder (new folders become projects).
                    HStack(spacing: 10) {
                        Text("工作项目").font(.system(size: 13))
                        Menu {
                            ForEach(model.store.state.projects) { project in
                                Toggle(isOn: Binding(get: { input.projectID == project.id }, set: { _ in input.projectID = project.id })) {
                                    Text("\(project.name)  —  \(project.path)")
                                }
                            }
                            if !model.store.state.projects.isEmpty { Divider() }
                            Button("选择文件夹…") { chooseFolder() }
                        } label: {
                            let chosen = model.store.state.projects.first { $0.id == input.projectID }
                            HStack(spacing: 8) {
                                DravionIcon(name: "folder-simple", size: 15)
                                Text(chosen?.name ?? "选择项目文件夹").fontWeight(chosen == nil ? .regular : .medium)
                                if let chosen { Text(chosen.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .menuStyle(.button).buttonStyle(.bordered).accessibilityIdentifier("task-project")
                        Button("选择文件夹…") { chooseFolder() }.accessibilityIdentifier("add-project")
                    }
                    HStack {
                        Picker("项目群", selection: $input.groupID) {
                            Text("不分组").tag(String?.none)
                            ForEach(model.store.state.groupList) { group in
                                Text(group.name).tag(Optional(group.id))
                            }
                        }.accessibilityIdentifier("task-group")
                        Button("保存为项目群…") {
                            groupName = model.store.state.projects.first { $0.id == input.projectID }?.name ?? "新项目群"
                            askGroupName = true
                        }
                        .disabled(input.projectID.isEmpty)
                        .accessibilityIdentifier("save-group")
                    }
                    if model.store.state.projects.isEmpty {
                        Text("还没有工作项目：点“添加项目…”选择代码目录，并填写实际测试命令。").font(.caption).foregroundStyle(.secondary)
                    }
                    if !foreignDirectories.isEmpty {
                        Text("目标提到了项目以外的目录：\(foreignDirectories.prefix(3).joined(separator: "、"))。子任务只会在所选项目目录里执行；涉及多个目录时，请为每个目录分别新建任务。")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("foreign-directories")
                    }
                    Divider()
                    HStack {
                        Toggle("直接分配给一个角色", isOn: $direct)
                        Spacer()
                        Button {
                            newRole = .init(name: "", stage: .executor, connectionID: model.store.state.connections.first?.id ?? "")
                        } label: { Label("新建员工", systemImage: "person.badge.plus") }
                            .disabled(model.store.state.connections.isEmpty)
                            .help(model.store.state.connections.isEmpty ? "先在“连接器与会话”里添加一个模型连接" : "现在新建一位员工；保存后直接加入这次的分工")
                            .accessibilityIdentifier("composer-new-role")
                    }
                    RelayAssignmentBoard(roles: roles, connections: model.store.state.connections, planner: $input.plannerID,
                        executors: direct ? Binding(get: { directRole.isEmpty ? [] : [directRole] }, set: { directRole = $0.first ?? "" }) : $input.executorIDs,
                        tester: $input.testerID, reviewer: $input.reviewerID, direct: direct)
                    DisclosureGroup("选择已有会话") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("默认复用对应岗位的常驻会话，首次使用才创建。手动指定的会话须属于当前项目；执行中的会话不能同时接单。").font(.caption).foregroundStyle(.secondary)
                            ForEach(involved) { role in
                                let options = availableSessions(role)
                                Picker(role.name, selection: Binding(get: { input.selectedSessions[role.id] ?? "" }, set: { value in
                                    input.selectedSessions[role.id] = value.isEmpty ? nil : value
                                })) {
                                    Text("自动复用常驻会话").tag("")
                                    ForEach(options) { session in
                                        Text("\(session.title) · \(session.sessionID.prefix(8))\(session.isActive ? "（运行中）" : "")").tag(session.sessionID).disabled(session.isActive)
                                    }
                                }
                            }
                            Button("刷新会话") { model.refreshSessions() }.disabled(model.scanning)
                        }.padding(.top, 10)
                    }
                    HStack {
                        Toggle("限时", isOn: Binding(get: { input.budgetMinutes > 0 }, set: { input.budgetMinutes = $0 ? 60 : 0 }))
                            .toggleStyle(.switch).controlSize(.small)
                        if input.budgetMinutes > 0 {
                            Stepper("时间预算 \(RelayCountdown.short(Double(input.budgetMinutes * 60)))", value: $input.budgetMinutes, in: 15...RelayScheduler.maxBudgetMinutes, step: 15)
                        } else {
                            Text("不限时，做完为止").foregroundStyle(.secondary)
                        }
                    }.font(.system(size: 12))
                    if input.directRoleID == nil {
                        Toggle("按里程碑分阶段推进：每个阶段做完先停下，等我确认下一阶段目标再拆任务", isOn: Binding(get: { input.staged != false }, set: { input.staged = $0 }))
                            .font(.system(size: 12))
                    }
                    Text(input.budgetMinutes > 0
                         ? "只计有效运行时间（等待额度、时段、回答不计）。到时不会打断正在进行的调用，而是在当前步骤完成后暂停，可追加时间继续。"
                         : "没有总时长上限；卡住由各模型的“无输出上限”判断。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
            Divider()
            HStack {
                if missing.isEmpty {
                    Text("暂停时间不计入运行预算").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("还需要：\(missing.joined(separator: "、"))").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("submit-missing")
                }
                Spacer()
                Button("取消") { model.showsComposer = false }
                Button(submitting ? "正在检查…" : "开始调度") { submit() }.buttonStyle(.borderedProminent)
                    .disabled(submitting || !missing.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command).accessibilityIdentifier("submit-task")
            }.padding(20)
        }.frame(width: 780).frame(maxHeight: 790).tint(RelayStyle.action).background(RelayStyle.canvas)
            .onAppear {
                let routing = model.store.state.routing
                // Start with one executor only; add a planner, quality check or review when the task needs them.
                input.executorIDs = Array(routing.executorIDs.prefix(1))
                if model.store.state.projects.count == 1 { input.projectID = model.store.state.projects[0].id }
                if let draft = model.draftProjectID, model.store.state.projects.contains(where: { $0.id == draft }) { input.projectID = draft }
                model.draftProjectID = nil
                if !model.draftGoal.isEmpty { input.goal = model.draftGoal; model.draftGoal = "" }
                if model.draftDictation {
                    model.draftDictation = false
                    Task { do { try await speech.start() } catch { self.error = error.localizedDescription } }
                }
            }
            .onChange(of: input.projectID) { _, _ in input.selectedSessions = [:] }
            .onChange(of: input.groupID) { _, id in applyGroup(id) }
            .alert("保存为项目群", isPresented: $askGroupName) {
                TextField("项目群名称", text: $groupName)
                Button("保存") { saveGroup() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("项目群保存当前的项目和角色分工；下次派活选它就能直接套用，统计也按群汇总。")
            }
            .sheet(item: $newRole) { role in
                RelayRoleEditor(model: model, role: role) { saved in place(saved) }
            }
            .sheet(item: $addingProject) { project in
                RelayProjectEditor(model: model, project: project) { saved in input.projectID = saved.id }
            }
            .onDisappear { speech.stop() }
    }
    /// A new employee joins this task where its duty fits: planner, executors, quality check or review.
    private func place(_ role: RelayRole) {
        guard role.enabled else { return }
        if direct { directRole = role.id; return }
        switch role.stage {
        case .planner: input.plannerID = role.id
        case .executor: if !input.executorIDs.contains(role.id) { input.executorIDs.append(role.id) }
        case .tester: input.testerID = role.id
        case .reviewer: input.reviewerID = role.id
        }
    }
    /// 选项目群时套用它的项目与角色分工；选“不分组”时不动当前选择。
    private func applyGroup(_ id: String?) {
        guard let id, let group = model.store.state.groupList.first(where: { $0.id == id }) else { return }
        input.projectID = group.projectID
        if !group.plannerID.isEmpty { input.plannerID = group.plannerID }
        if !group.executorIDs.isEmpty { input.executorIDs = group.executorIDs }
        if !group.testerID.isEmpty { input.testerID = group.testerID }
        if !group.reviewerID.isEmpty { input.reviewerID = group.reviewerID }
        input.selectedSessions = [:]
    }
    private func saveGroup() {
        guard !input.projectID.isEmpty else { return }
        let group = RelayGroup(name: groupName, projectID: input.projectID, plannerID: input.plannerID,
                               executorIDs: input.executorIDs, testerID: input.testerID, reviewerID: input.reviewerID)
        do {
            try model.store.saveGroup(group)
            input.groupID = group.id
            model.notice = "已保存项目群 \(group.name)。"
        } catch { self.error = error.localizedDescription }
    }
    private func availableSessions(_ role: RelayRole) -> [RelayExternalSession] {
        guard let connection = model.store.state.connections.first(where: { $0.id == role.connectionID }),
              let project = model.store.state.projects.first(where: { $0.id == input.projectID }) else { return [] }
        return model.sessions.filter { $0.provider == connection.kind && URL(fileURLWithPath: $0.projectPath).standardizedFileURL == URL(fileURLWithPath: project.path).standardizedFileURL }
    }
    private func addAttachments() {
        do {
            for url in RelayDialogs.attachments() {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 128_000, String(data: try Data(contentsOf: url), encoding: .utf8) != nil else { throw RelayError.invalid("\(url.lastPathComponent) 需为 128 KB 以内的 UTF-8 文本。") }
                if !input.attachments.contains(where: { $0.path == url.path }) { input.attachments.append(.init(path: url.path)) }
            }
        } catch { self.error = error.localizedDescription }
    }
    /// A folder already registered as a project is just selected; any other folder opens the project form.
    private func chooseFolder() {
        guard let path = RelayDialogs.directory() else { return }
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        if let known = model.store.state.projects.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == standard }) {
            input.projectID = known.id; return
        }
        addingProject = RelayProject(name: URL(fileURLWithPath: path).lastPathComponent, path: path,
                                     testCommand: RelayProjectHints.testCommand(for: path))
    }

    private func submit() {
        submitting = true; error = nil; speech.stop()
        var submitted = input
        // No goal yet: the scheduler names it "新任务" and takes the first message from the bottom bar as the goal.
        submitted.title = input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(input.goal.prefix(50)) : input.title
        submitted.directRoleID = direct ? directRole : nil
        let ids = Set(involved.map(\.id))
        submitted.selectedSessions = input.selectedSessions.filter { ids.contains($0.key) }
        Task {
            if !(await model.submit(submitted)) { error = model.error; model.error = nil }
            submitting = false
        }
    }
}

struct RelayProjectEditor: View {
    @Bindable var model: RelayAppModel
    @State var project: RelayProject
    var onSave: ((RelayProject) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            RelaySheetHeader(title: "工作项目", close: { dismiss() })
            Form {
                TextField("名称", text: $project.name)
                HStack { TextField("目录", text: $project.path); Button("选择…") { if let path = RelayDialogs.directory() { project.path = path; if project.name.isEmpty { project.name = URL(fileURLWithPath: path).lastPathComponent } } } }
                TextField("要求分支（可选）", text: $project.expectedBranch)
                TextField("实际测试命令", text: $project.testCommand, axis: .vertical)
                Stepper("测试上限 \(project.testTimeoutSeconds < 60 ? "\(project.testTimeoutSeconds) 秒" : RelayCountdown.short(Double(project.testTimeoutSeconds)))", value: $project.testTimeoutSeconds, in: 10...RelayProject.maxTestSeconds, step: 30)
                Text("命令在项目目录执行；退出码为 0 后才进入质量检查。").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped)
            HStack { Spacer(); Button("保存项目") { do { try model.store.saveProject(project); onSave?(project); dismiss() } catch { self.error = error.localizedDescription } }.buttonStyle(.borderedProminent) }.padding(20)
        }.frame(width: 620, height: 430).tint(RelayStyle.action)
    }
}

struct RelayConnectionEditor: View {
    @Bindable var model: RelayAppModel
    @State var connection: RelayConnection
    @State private var secret = ""
    @State private var clearSecret = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            RelaySheetHeader(title: "模型连接", close: { dismiss() })
            Form {
                TextField("连接名称", text: $connection.name)
                Picker("接入方式", selection: $connection.kind) { ForEach(RelayProviderKind.allCases, id: \.self) { Text($0.label).tag($0) } }
                if connection.kind == .api {
                    Picker("API 协议", selection: $connection.apiKind) { ForEach(RelayAPIKind.allCases, id: \.self) { Text($0.label).tag($0) } }
                    TextField("API 基础地址", text: $connection.baseURL)
                    Toggle("需要密钥", isOn: $connection.requiresAuth)
                    SecureField(connection.hasSecret ? "替换密钥（留空保留）" : "API 密钥", text: $secret)
                    TextField("或读取环境变量", text: $connection.keyEnvironment)
                    if connection.hasSecret { Toggle("删除已保存密钥", isOn: $clearSecret).disabled(!secret.isEmpty) }
                    Text("密钥保存在 macOS 钥匙串。环境变量需由启动应用的进程传入。").font(.caption).foregroundStyle(.secondary)
                }
                if connection.kind == .doubaoApp {
                    TextField("豆包对话编号（可留空，之后在卡片上绑定当前对话）", text: Binding(
                        get: { connection.appConversationID ?? "" },
                        set: { value in
                            let id = value.filter(\.isNumber)
                            connection.appConversationID = id.isEmpty ? nil : id
                            if connection.appConversationTitle == nil || id.isEmpty { connection.appConversationTitle = id.isEmpty ? nil : "对话 \(id)" }
                        }))
                    Text("保存后在连接卡片上点“绑定豆包当前对话”。需要在 系统设置 → 隐私与安全性 → 辅助功能 里允许 Dravion。豆包只用于群聊、私聊和后台工作，不接开发任务。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !(connection.kind == .workbuddy && connection.connectorTransport == .workbuddyApp) {
                    TextField("可执行文件（留空自动检测）", text: $connection.binaryPath)
                }
                if connection.kind == .workbuddy {
                    Picker("连接器", selection: Binding(get: { connection.connectorTransport }, set: { connection.transport = $0 })) {
                        ForEach(connection.connectorTransports, id: \.self) { Text($0.label).tag($0) }
                    }
                    Text(connection.connectorTransport == .workbuddyApp ? connection.connectorTransport.detail
                         : "命令行方式只能用独立安装并已登录的 CodeBuddy 命令行；WorkBuddy 安装包自带的精简命令行从 Dravion 启动时登录不了。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if connection.kind == .codex {
                    Picker("连接器", selection: Binding(get: { connection.connectorTransport }, set: { connection.transport = $0 })) {
                        ForEach(connection.connectorTransports, id: \.self) { Text($0.label).tag($0) }
                    }
                    Text(connection.connectorTransport.detail).font(.caption).foregroundStyle(.secondary)
                    if connection.connectorTransport == .codexDesktop {
                        TextField("控制 socket（留空使用客户端默认）", text: Binding(get: { connection.controlSocketPath ?? "" }, set: { connection.controlSocketPath = $0 }))
                        Text("只有桌面客户端开放共享控制接口时才可使用；检测只进行握手和读取模型目录。").font(.caption).foregroundStyle(.secondary)
                    }
                    if connection.connectorTransport != .cli {
                        Toggle("App 连不上时用命令行保底", isOn: Binding(get: { connection.cliFallback != false }, set: { connection.cliFallback = $0 ? nil : false }))
                        Text("只在任务还没开始执行时换成命令行（例如 App 启动、握手或打开会话失败），同一件事不会做两遍。").font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("建立会话时在 Codex 中打开", isOn: Binding(get: { connection.revealInClient ?? false }, set: { connection.revealInClient = $0 }))
                }
                if connection.kind != .doubaoApp { Stepper(value: Binding(get: { connection.maxConcurrentSessions ?? 1 },
                                       set: { connection.maxConcurrentSessions = $0 }), in: 1...4) {
                    HStack {
                        Text("最大同时调用数")
                        Spacer()
                        Text("\(connection.maxConcurrentSessions ?? 1)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Text("限制这个连接同时消耗 token 的调用。Claude 全局最多保留两个常驻席位：文档与审查一个、执行一个。")
                    .font(.caption).foregroundStyle(.secondary) }
                if connection.kind != .api && connection.kind != .opencode && connection.kind != .doubaoApp || !connection.models.isEmpty {
                    RelayAllowedModels(model: model, connection: $connection)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped)
            HStack { Spacer(); Button("保存连接") { do { try model.store.saveConnection(connection, secret: secret.isEmpty ? nil : secret, clearSecret: clearSecret && secret.isEmpty); dismiss() } catch { self.error = error.localizedDescription } }.buttonStyle(.borderedProminent) }.padding(20)
        }.frame(width: 680, height: 740).tint(RelayStyle.action)
            .onChange(of: connection.kind) { _, kind in
                connection.transport = kind == .codex ? .codexAppServer : kind == .workbuddy ? .workbuddyApp : .cli; connection.controlSocketPath = nil
            }
            .onChange(of: connection.connectorTransport) { _, _ in connection.probedAt = nil; connection.probeOK = nil; connection.probeMessage = nil }
    }
}

/// Picks the client's models that roles may use. For WorkBuddy this is how "only its built-in DeepSeek models"
/// is enforced: roles cannot choose any other model, nor fall back to the client's default.
struct RelayAllowedModels: View {
    @Bindable var model: RelayAppModel
    @Binding var connection: RelayConnection
    @State private var filter = ""
    @State private var loading = false
    @State private var notes: [String: String] = [:]
    private var allowed: Set<String> { Set(connection.allowedModels ?? []) }
    private var shown: [String] {
        let all = connection.models
        return filter.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(filter) }
    }
    var body: some View {
        Section {
            HStack {
                Text(allowed.isEmpty ? "允许全部模型" : "只允许 \(allowed.count) 个模型").font(.system(size: 13, weight: .medium))
                Spacer()
                if connection.kind == .workbuddy {
                    Button("只用 DeepSeek 模型") {
                        connection.allowedModels = connection.models.filter { $0.localizedCaseInsensitiveContains("deepseek") }
                    }.disabled(connection.models.isEmpty)
                }
                Button("全部允许") { connection.allowedModels = nil }.disabled(allowed.isEmpty)
                Button(loading ? "读取中…" : "读取模型目录") {
                    loading = true
                    Task {
                        do { connection.models = try await model.catalog(connection).ids } catch { model.error = error.localizedDescription }
                        notes = connection.kind == .workbuddy ? RelayProviders.buddyModelNotes() : [:]
                        loading = false
                    }
                }.disabled(loading)
            }
            if connection.models.isEmpty {
                Text("先读取模型目录，再选择允许使用的模型。").font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("筛选模型", text: $filter)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(shown, id: \.self) { id in
                            Toggle(isOn: Binding(get: { allowed.contains(id) }, set: { on in
                                var next = allowed; if on { next.insert(id) } else { next.remove(id) }
                                connection.allowedModels = next.isEmpty ? nil : connection.models.filter { next.contains($0) }
                            })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(id).font(.system(size: 12, design: .monospaced))
                                    if let note = notes[id] { Text(note).font(.caption2).foregroundStyle(.secondary) }
                                }
                            }.toggleStyle(.checkbox)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 170)
            }
        } header: { Text("允许使用的模型") } footer: {
            Text("不勾选任何模型表示允许全部。设置后，角色只能选这些模型，也不能沿用客户端默认模型。").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { if connection.kind == .workbuddy { notes = RelayProviders.buddyModelNotes() } }
    }
}

struct RelayRoleEditor: View {
    @Bindable var model: RelayAppModel
    @State var role: RelayRole
    var onSave: ((RelayRole) -> Void)? = nil
    /// Shown above the page (overlay) instead of as a sheet: closes through this.
    var close: (() -> Void)? = nil
    /// Editing an employee inside a running task: saves through the scheduler; the flag also updates the employee.
    var runEdit: ((RelayRole, Bool) async throws -> Void)? = nil
    /// Inline in the 员工 page's 设置 tab: no header or fixed size, and saving keeps the form open.
    var embedded = false
    @State private var error: String?
    @State private var saved = false
    @State private var saveAsDefault = false
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    private var connection: RelayConnection? { model.store.state.connections.first { $0.id == role.connectionID } }
    private var hours: Binding<[RelayTimeWindow]> {
        Binding(get: { role.workHours?.windows ?? [] }, set: { role.workHours?.windows = $0 })
    }
    private var standIns: [String] { role.standIns ?? [] }
    var body: some View {
        VStack(spacing: 0) {
            if !embedded { RelaySheetHeader(title: runEdit == nil ? "角色设置" : "修改员工（本任务）", close: { finish() }) }
            Form {
                Section {
                    TextField("角色名称", text: $role.name)
                    Picker("职责分类", selection: $role.stage) { ForEach(RelayStage.allCases, id: \.self) { Text($0.label).tag($0) } }
                        .disabled(runEdit != nil)
                    Picker("模型连接", selection: $role.connectionID) { ForEach(model.store.state.connections) { Text($0.name).tag($0.id) } }
                    RelayModelField(model: model, connectionID: role.connectionID, selected: $role.model)
                    Text("职责提示词").font(.headline)
                    TextEditor(text: $role.prompt).font(.system(size: 12)).frame(height: 115)
                    Picker("思考强度", selection: $role.effort) { ForEach(["default", "low", "medium", "high", "xhigh", "max"], id: \.self) { Text($0 == "default" ? "客户端默认" : $0).tag($0) } }
                    if connection?.kind == .api {
                        TextField("上下文长度", value: $role.contextLimit, format: .number)
                        TextField("输出上限", value: $role.outputLimit, format: .number)
                    }
                    if runEdit == nil { Toggle("启用角色", isOn: $role.enabled) }
                }
                Section("文件权限") {
                    Picker("写项目以外的目录", selection: Binding(get: { role.fileAccess ?? .ask }, set: { role.fileAccess = $0 == .ask ? nil : $0 })) {
                        ForEach(RelayFileAccess.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Text((role.fileAccess ?? .ask) == .full
                         ? "写入被拒时，如果那个目录在项目旁边（同一个上级文件夹，例如 worktree），直接允许（仅本任务）并继续，不再问你；隐藏目录（如 .ssh）、~/Library 和其他位置仍然问你。每个任务最多自动授权 3 轮。"
                         : "写入被拒时停下来，由你点“允许写入并继续”。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("工作时间") {
                    Toggle("只在工作时间内工作", isOn: Binding(get: { role.workHours != nil }, set: { role.workHours = $0 ? .office : nil }))
                    if role.workHours != nil {
                        RelayWindowList(windows: hours, note: "不在工作时间不接新的调用（正在进行的调用会做完）。快下班或不在岗时，工作交给下面的候选员工；没有候选就等他上班再继续。")
                        TextField("时区", text: Binding(get: { role.workHours?.timeZone ?? TimeZone.current.identifier }, set: { role.workHours?.timeZone = $0 }))
                    }
                }
                Section("候选员工") {
                    Text("他额度快用完、快下班、不在岗或模型不可用时，按这个顺序找第一个能工作的人接手（需在“调度设置”打开自动换人）。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(standIns.enumerated()), id: \.element) { index, id in
                        let other = model.store.state.roles.first { $0.id == id }
                        HStack(spacing: 8) {
                            Text("\(index + 1)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            Circle().fill(RelayStyle.color(other?.color ?? "gray")).frame(width: 7, height: 7)
                            Text(other?.name ?? "已删除的员工").foregroundStyle(other == nil ? .secondary : .primary)
                            Text(model.store.state.connections.first { $0.id == other?.connectionID }?.name ?? "").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { move(index, -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).disabled(index == 0).help("提前")
                            Button { move(index, 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless).disabled(index == standIns.count - 1).help("延后")
                            Button { role.standIns = standIns.filter { $0 != id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("移除")
                        }
                    }
                    let options = model.store.state.roles.filter { $0.enabled && $0.id != role.baseID && !standIns.contains($0.id) }
                    Menu {
                        ForEach(options) { other in
                            Button("\(other.name) · \(model.store.state.connections.first { $0.id == other.connectionID }?.name ?? "")") {
                                role.standIns = standIns + [other.id]
                            }
                        }
                    } label: { Label("添加候选员工", systemImage: "plus") }
                        .disabled(options.isEmpty).fixedSize()
                }
                if runEdit != nil {
                    Toggle("同时保存为这位员工的默认设置（以后的任务也用）", isOn: $saveAsDefault)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped)
            HStack {
                if embedded && saved { Text("已保存；正在进行的调用结束后生效。").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(saving ? "正在检查…" : embedded ? "保存设置" : (runEdit == nil ? "保存角色" : "保存并应用到任务")) { save() }
                    .buttonStyle(.borderedProminent).disabled(saving)
            }.padding(embedded ? 12 : 20)
        }.frame(width: embedded ? nil : 670, height: embedded ? nil : 760).tint(RelayStyle.action).background(RelayStyle.canvas)
            .onChange(of: role.connectionID) { _, _ in role.model = "" }
            .onChange(of: role) { _, _ in saved = false }
    }
    private func move(_ index: Int, _ offset: Int) {
        var list = standIns
        list.swapAt(index, index + offset)
        role.standIns = list
    }
    private func finish() { if let close { close() } else { dismiss() } }
    private func save() {
        error = nil
        if let runEdit {
            saving = true
            Task {
                do { try await runEdit(role, saveAsDefault); finish() } catch { self.error = error.localizedDescription }
                saving = false
            }
            return
        }
        do {
            try model.store.saveRole(role); onSave?(role)
            if embedded { saved = true } else { finish() }
        } catch { self.error = error.localizedDescription }
    }
}

struct RelayModelField: View {
    @Bindable var model: RelayAppModel
    var connectionID: String
    @Binding var selected: String
    @State private var loading = false
    @State private var groups: [RelayClientCatalog.Group] = []
    private func loadGroups() async {
        guard let connection else { groups = []; return }
        let allowed = connection.allowedModels ?? []
        groups = await Task.detached(priority: .utility) { RelayClientCatalog.groups(for: connection) }.value.map { group in
            var next = group; next.entries = group.entries.filter { allowed.isEmpty || allowed.contains($0.id) }; return next
        }.filter { !$0.entries.isEmpty }
    }
    private var connection: RelayConnection? { model.store.state.connections.first { $0.id == connectionID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                if connection?.kind == .workbuddy {
                    Picker("固定模型", selection: $selected) {
                        Text("请选择一个模型").tag("")
                        ForEach(connection?.selectableModels ?? [], id: \.self) { Text($0).tag($0) }
                        if !selected.isEmpty && !(connection?.selectableModels ?? []).contains(selected) { Text(selected).tag(selected) }
                    }
                } else {
                    TextField(connection?.kind == .api ? "模型 ID（必填）" : "模型 ID（留空沿用客户端）", text: $selected)
                    if !groups.isEmpty {
                        Menu("选择") {
                            ForEach(groups) { group in
                                Menu(group.title) {
                                    if let note = group.note { Text(note) }
                                    ForEach(group.entries, id: \.id) { entry in
                                        Button(entry.note.map { "\(entry.label)　\($0)" } ?? entry.label) { selected = entry.id }
                                    }
                                }
                            }
                        }.fixedSize()
                    }
                }
                Button(loading ? "读取中…" : "刷新模型") { loading = true; Task { await model.models(for: connectionID); await loadGroups(); loading = false } }.disabled(loading)
            }
            if connection?.kind == .workbuddy { Text("只使用选中的模型；不可用时暂停并等待恢复。").font(.caption).foregroundStyle(.secondary) }
            if let allowed = connection?.allowedModels, !allowed.isEmpty {
                Text("此连接只允许：\(allowed.joined(separator: "、"))。可在“角色与连接”中修改。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: connectionID) { await loadGroups() }
    }
}

struct RelaySwitchSheet: View {
    @Bindable var model: RelayAppModel
    var run: RelayRun
    @State private var roleID = ""
    @State private var connectionID = ""
    @State private var selectedModel = ""
    @State private var busy = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            RelaySheetHeader(title: "切换接入并继续", close: { dismiss() })
            Form {
                RelayRolePicker(title: "切换哪个角色", roles: run.roles, selection: $roleID)
                Picker("新连接", selection: $connectionID) {
                    Text("请选择连接").tag("")
                    ForEach(model.store.state.connections) { Text($0.name).tag($0.id) }
                }
                RelayModelField(model: model, connectionID: connectionID, selected: $selectedModel)
                Text("保留已完成子任务和文件修改，把当前步骤交给新接入的新会话。").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped)
            HStack { Spacer(); Button(busy ? "正在检查…" : "切换并继续") {
                busy = true
                Task { do { try await model.scheduler.switchConnection(run.id, roleID: roleID, connectionID: connectionID, model: selectedModel); dismiss() } catch { self.error = error.localizedDescription }; busy = false }
            }.buttonStyle(.borderedProminent).disabled(busy || roleID.isEmpty || connectionID.isEmpty) }.padding(20)
        }.frame(width: 660, height: 365).tint(RelayStyle.action).onAppear {
            roleID = run.currentRoleID ?? ""
            if let role = run.roles.first(where: { $0.id == roleID }) { connectionID = role.connectionID; selectedModel = role.model }
        }.onChange(of: connectionID) { _, _ in selectedModel = "" }
    }
}

