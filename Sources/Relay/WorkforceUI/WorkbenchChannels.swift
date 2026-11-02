import SwiftUI
import RelayCore

/// 群聊 (UI02 / UI14, merged with the former 团队群聊 on 2026-11-01). The left list has persistent channels and,
/// below them, one group per task (filtered by project group). The middle is the conversation; the right panel holds
/// stats, members with their model and live status, and — for a channel — its tasks, owners and handoffs.
struct RelayWorkbenchChannels: View {
    @Bindable var model: RelayWorkbenchModel
    @State private var atBottom = true
    @State private var creating = false
    @State private var showsContext = true
    @State private var board = false
    @State private var handoff: RelayWorkAssignment?
    private var app: RelayAppModel { model.app }
    private var state: RelayState { app.store.state }

    /// Tasks in the chosen project group, running ones first.
    private var taskGroups: [RelayRun] {
        let known = Set(state.groupList.map(\.id))
        let runs = state.runs.filter { $0.archivedAt == nil }.filter { run in
            switch model.groupFilter {
            case "all": return true
            case "none": return run.input.groupID.map { !known.contains($0) } ?? true
            default: return run.input.groupID == model.groupFilter
            }
        }
        return runs.filter { !$0.status.isTerminal } + runs.filter(\.status.isTerminal)
    }

    var body: some View {
        let _ = model.host.revision
        let channels = model.host.channels()
        let run = model.taskRunID.flatMap { id in state.runs.first { $0.id == id } }
        let channel = run == nil ? channels.first { $0.id == (model.channelID ?? channels.first?.id) } : nil
        HStack(spacing: 0) {
            list(channels, selectedChannel: channel?.id, selectedRun: run?.id).frame(width: 260)
            Divider()
            if let run {
                RelayTaskGroupChat(model: app, runID: run.id)
            } else if let channel { conversation(channel) } else {
                RelayEmpty(symbol: "bubble.left.and.bubble.right", title: "还没有群", detail: "新建常驻群承载多次请求；每个任务也有自己的任务群，在左侧“任务群”里。")
                    .frame(maxHeight: .infinity)
            }
            if showsContext, run != nil || channel != nil {
                Divider()
                Group {
                    if let run { taskContext(run) } else if let channel { context(channel) }
                }.frame(width: 300)
            }
        }
        .workbenchCard(creating, close: { creating = false }) { RelayChannelForm(model: model) { creating = false } }
        .workbenchCard(handoff != nil, close: { handoff = nil }) { if let item = handoff { RelayHandoffForm(model: model, assignment: item) { handoff = nil } } }
    }

    // MARK: List

    private func list(_ channels: [RelayChannel], selectedChannel: String?, selectedRun: String?) -> some View {
        List {
            Section {
                ForEach(channels) { channel in
                    row(selected: channel.id == selectedChannel, title: channel.name,
                        detail: "\(channel.memberIDs.count) 位成员 · 负责人 \(model.host.name(channel.leadID))") {
                        model.channelID = channel.id; model.taskRunID = nil
                    }
                }
                if channels.isEmpty { Text("还没有常驻群").font(.system(size: 11)).foregroundStyle(.tertiary) }
            } header: {
                HStack {
                    Text("常驻群"); Spacer()
                    Button { creating = true } label: { Image(systemName: "plus") }.buttonStyle(.borderless).accessibilityLabel("新建常驻群")
                }
            }
            Section {
                HStack(spacing: 6) {
                    Picker("项目群", selection: $model.groupFilter) {
                        Text("全部任务").tag("all")
                        ForEach(state.groupList) { Text($0.name).tag($0.id) }
                        Text("未分组").tag("none")
                    }.labelsHidden()
                    if model.groupFilter != "all" && model.groupFilter != "none" {
                        Button { deleteGroup(model.groupFilter) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            .help("只删除项目群，不删除任务；这些任务会归到“未分组”。")
                    }
                }
                ForEach(taskGroups) { run in
                    row(selected: run.id == selectedRun, title: run.input.title,
                        detail: "\(run.status.label) · \(run.finishedTasks)/\(run.tasks.count) 子任务", dot: run.status.isWorking ? RelayStyle.accent : nil) {
                        model.taskRunID = run.id
                    }
                }
                if taskGroups.isEmpty { Text("新建任务后，员工的协作汇报会出现在这里。").font(.system(size: 11)).foregroundStyle(.tertiary) }
            } header: { Text("任务群") }
        }.listStyle(.sidebar)
    }

    /// A list row drawn as a plain button, so the selection stays the neutral grey of the sidebar (no system blue).
    private func row(selected: Bool, title: String, detail: String, dot: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(selected ? RelayStyle.sidebarSelection : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func deleteGroup(_ id: String) {
        guard let group = state.groupList.first(where: { $0.id == id }) else { return }
        app.perform {
            try app.store.deleteGroup(id)
            app.notice = "已删除项目群 \(group.name)；它的任务已归到“未分组”。"
            model.groupFilter = "all"
        }
    }

    // MARK: Channel conversation

    private func conversation(_ channel: RelayChannel) -> some View {
        let root = model.host.project(for: channel)?.path ?? ""
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(channel.name).font(.system(size: 17, weight: .semibold))
                if !channel.purpose.isEmpty { Text(channel.purpose).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                HStack(spacing: -6) {
                    ForEach(channel.memberIDs.prefix(6), id: \.self) { id in
                        let role = state.roles.first { $0.id == id }
                        RelayAvatar(role: role, connection: state.connections.first { $0.id == role?.connectionID }, active: busy(id), size: 22)
                            .overlay(Circle().stroke(RelayStyle.canvas, lineWidth: 2))
                    }
                }
                contextToggle
            }.padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.host.messages(channel.id)) { message in
                            RelayWorkbenchMessage(message: message, author: model.host.name(message.authorID), openReceipt: model.open(receipt:), app: app, root: root).id(message.id)
                        }
                        RelayDispatchStrip(app: model.app, host: model.host, channelID: channel.id)
                        Color.clear.frame(height: 1).id("end")
                    }.padding(20)
                }
                .modifier(RelayFollowBottom(atBottom: $atBottom))
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: model.host.messages(channel.id).count) { if atBottom { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } } }
            }
            Divider()
            RelayWorkbenchComposer(text: Binding(get: { model.drafts[channel.id] ?? "" }, set: { model.drafts[channel.id] = $0 }),
                                   placeholder: "@成员 派活，@全体 给每人一项；不 @ 时由群负责人拆解分配",
                                   send: { model.host.post(channel.id, text: $0) }, sendTask: { model.host.post(channel.id, text: $0, asTask: true) })
        }
    }

    private var contextToggle: some View {
        Button { showsContext.toggle() } label: { Image(systemName: "sidebar.right") }.buttonStyle(.borderless).accessibilityLabel("成员与任务")
    }
    private func busy(_ employeeID: String) -> Bool {
        model.host.allAssignments().contains { $0.ownerID == employeeID && model.host.running.contains($0.id) }
    }

    // MARK: Right panels

    private func taskContext(_ run: RelayRun) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("项目群统计").font(.system(size: 13, weight: .semibold)); Spacer(); contextToggle }
                RelayGroupStatsRow(runs: taskGroups)
                Divider()
                Text("成员 · \(run.roles.count) 位").font(.system(size: 13, weight: .semibold))
                ForEach(run.roles) { role in RelayEmployeeCard(model: app, role: role) { model.taskRunID = $0 } }
            }.padding(16)
        }.background(Color.primary.opacity(0.02))
    }

    private func context(_ channel: RelayChannel) -> some View {
        let items = model.host.allAssignments().filter { $0.channelID == channel.id }.sorted { $0.createdAt > $1.createdAt }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    stat("任务", "\(items.count)"); stat("进行中", "\(items.filter(\.isOpen).count)")
                    stat("已完成", "\(items.filter { $0.state == .completed }.count)"); stat("失败", "\(items.filter { $0.state == .failed }.count)")
                }
                HStack {
                    Text("任务").font(.system(size: 13, weight: .semibold)); Spacer()
                    Picker("", selection: $board) { Text("列表").tag(false); Text("看板").tag(true) }.pickerStyle(.segmented).frame(width: 120)
                }
                if items.isEmpty { Text("还没有任务。").font(.system(size: 12)).foregroundStyle(.secondary) }
                if board {
                    ForEach([("待办", [RelayWorkAssignment.State.queued]), ("执行中", [.running]), ("待处理", [.awaitingReceipt]), ("完成", [.completed, .failed, .cancelled, .handedOff])], id: \.0) { column in
                        let cards = items.filter { column.1.contains($0.state) }
                        if !cards.isEmpty {
                            Text("\(column.0) · \(cards.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            ForEach(cards) { taskCard($0) }
                        }
                    }
                } else { ForEach(items) { taskCard($0) } }
                Divider()
                Text("成员").font(.system(size: 13, weight: .semibold))
                ForEach(channel.memberIDs, id: \.self) { id in member(id, lead: id == channel.leadID) }
                if let group = channel.linkedGroupID.flatMap({ id in state.groupList.first { $0.id == id } }) {
                    Text("关联原项目群：\(group.name)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button("归档此群（保留消息，停止新派发）") { model.host.archiveChannel(channel.id) }.buttonStyle(.link).font(.system(size: 11))
            }.padding(16)
        }.background(Color.primary.opacity(0.02))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8).background(RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 8))
    }

    /// A member with client, model and what they are doing in this workspace now.
    private func member(_ id: String, lead: Bool) -> some View {
        let role = state.roles.first { $0.id == id }
        let connection = state.connections.first { $0.id == role?.connectionID }
        let open = model.host.allAssignments().filter { $0.ownerID == id && $0.isOpen }
        let status = !(role?.enabled ?? false) ? "已停用" : busy(id) ? "执行中" : open.first.map { $0.state == .awaitingReceipt ? "等回执被接收" : "排队中" } ?? "空闲"
        return HStack(spacing: 10) {
            RelayAvatar(role: role, connection: connection, active: busy(id), size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.host.name(id)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if lead { RelayBadge(text: "负责人", color: RelayPalette.violet) }
                }
                Text(role.map { app.effectiveModel($0, connection: connection).model } ?? "").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                RelayStatusPill(text: status, color: busy(id) ? RelayPalette.green : .secondary, pulsing: busy(id))
                Button("私聊") { model.open(employee: id) }.buttonStyle(.link).font(.system(size: 10.5))
            }
        }
    }

    /// Each task shows its single owner; the channel lead is not the owner of everything.
    private func taskCard(_ item: RelayWorkAssignment) -> some View {
        RelayCard(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.instruction).font(.system(size: 12)).lineLimit(2)
                HStack {
                    Text("负责人 \(model.host.name(item.ownerID))").font(.system(size: 11)).foregroundStyle(.secondary)
                    if item.ownerRevision > 1 { Text("已移交 \(item.ownerRevision - 1) 次").font(.system(size: 11)).foregroundStyle(.secondary) }
                    Spacer()
                    if item.isOpen, item.callState == .idle { Button("移交") { handoff = item }.buttonStyle(.link).font(.system(size: 11)) }
                }
                RelayResultBadges(result: item.result).scaleEffect(0.92, anchor: .leading)
                if item.callState == .unconfirmed { Text("上次调用没有确认结束：不会自动重试，请在原客户端确认后再处理。").font(.system(size: 11)).foregroundStyle(RelayPalette.amber) }
            }
        }
    }
}

struct RelayChannelForm: View {
    @Bindable var model: RelayWorkbenchModel
    var close: () -> Void
    @State private var name = ""
    @State private var purpose = ""
    @State private var members: Set<String> = []
    @State private var lead = ""
    @State private var projectID = ""
    @State private var groupID = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RelaySheetHeader(title: "新建常驻群", close: close)
            Form {
                TextField("群名", text: $name)
                TextField("目标（可选）", text: $purpose)
                Picker("工作目录", selection: $projectID) {
                    ForEach(model.app.store.state.projects) { Text($0.name).tag($0.id) }
                }
                Section("成员") {
                    ForEach(model.host.employees()) { role in
                        Toggle(role.name, isOn: Binding(get: { members.contains(role.id) }, set: { on in
                            if on { members.insert(role.id) } else { members.remove(role.id) }
                            if !members.contains(lead) { lead = members.first ?? "" }
                        }))
                    }
                }
                Picker("群负责人", selection: $lead) { ForEach(members.sorted(), id: \.self) { Text(model.host.name($0)).tag($0) } }
                Picker("关联原项目群（可选）", selection: $groupID) {
                    Text("不关联").tag("")
                    ForEach(model.app.store.state.groupList) { Text($0.name).tag($0.id) }
                }
            }.formStyle(.grouped)
            HStack { Spacer(); Button("取消", action: close)
                Button("创建") {
                    model.host.createChannel(name: name, purpose: purpose, leadID: lead, memberIDs: members.sorted(), projectID: projectID.isEmpty ? nil : projectID,
                                             linkedGroupID: groupID.isEmpty ? nil : groupID)
                    if model.host.lastError == nil { model.channelID = model.host.channels().last?.id; close() }
                }.buttonStyle(.borderedProminent).tint(RelayStyle.action).disabled(name.isEmpty || members.isEmpty)
            }.padding(20)
        }.frame(width: 520, height: 620)
        .onAppear { projectID = model.app.store.state.projects.first?.id ?? "" }
    }
}

/// The handoff card (FE §5.2): who hands what to whom; "已接手" only after the host swapped the owner.
struct RelayHandoffForm: View {
    @Bindable var model: RelayWorkbenchModel
    var assignment: RelayWorkAssignment
    var close: () -> Void
    @State private var to = ""
    @State private var note = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RelaySheetHeader(title: "移交工作", close: close)
            VStack(alignment: .leading, spacing: 10) {
                Text("目标：\(assignment.instruction)").font(.system(size: 13))
                Text("当前负责人：\(model.host.name(assignment.ownerID))（第 \(assignment.ownerRevision) 任）").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("已有回执 \(model.host.receipts().filter { $0.assignmentID == assignment.id }.count) 份 · 快照 \(assignment.checkpointIDs.count) 个").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("接手人", selection: $to) {
                    ForEach(model.host.employees().filter { $0.id != assignment.ownerID && $0.enabled }) { Text($0.name).tag($0.id) }
                }
                TextField("交接说明：已完成什么、剩下什么", text: $note, axis: .vertical).lineLimit(3...6).relayField()
                HStack { Spacer(); Button("取消", action: close)
                    Button("发起并接手") {
                        model.host.requestHandoff(assignment.id, to: to, note: note)
                        if let pending = model.host.handoffs().last(where: { $0.assignmentID == assignment.id && $0.state == .pending }) {
                            model.host.decideHandoff(pending.id, accept: true)
                        }
                        close()
                    }.buttonStyle(.borderedProminent).tint(RelayStyle.action).disabled(to.isEmpty)
                }
            }.padding(.horizontal, 24).padding(.bottom, 24)
        }.frame(width: 480)
    }
}
