import SwiftUI
import RelayCore

/// 员工 (UI01, merged with the former 员工与分工 on 2026-11-01). Left: the default staffing at the top, then every
/// employee with a live status. Right: 私聊 · 工作 · 交付 · 设置 — 设置 is the full role editor (connection, model,
/// prompt, effort, file access, working hours, stand-ins) plus the employee's scoped notes. Roles stay the single truth.
struct RelayWorkbenchPeople: View {
    @Bindable var model: RelayWorkbenchModel
    @State private var note = ""
    @State private var atBottom = true
    @State private var creating = false
    @State private var showsStaffing = false
    @State private var routing = RelayRouting()
    typealias Tab = RelayWorkbenchModel.PeopleTab
    private var tab: Tab { model.peopleTab }
    private var app: RelayAppModel { model.app }

    var body: some View {
        let _ = model.host.revision
        let employees = model.host.employees()
        let selected = showsStaffing ? nil : employees.first { $0.id == (model.employeeID ?? employees.first?.id) }
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List {
                    rowButton(selected: showsStaffing) { showsStaffing = true } label: {
                        HStack(spacing: 10) {
                            DravionIcon(name: "tree-structure", size: 15).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("默认分工").font(.system(size: 13, weight: .medium))
                                Text("新任务默认的总调度、执行、质检和复审").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    Section("员工 · \(employees.count)") {
                        ForEach(employees) { role in
                            rowButton(selected: selected?.id == role.id) { model.employeeID = role.id; showsStaffing = false } label: {
                                HStack(spacing: 10) {
                                    RelayAvatar(role: role, connection: app.store.state.connections.first { $0.id == role.connectionID }, active: status(role) == "执行中", size: 26)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(role.name).font(.system(size: 13, weight: .medium)).foregroundStyle(role.enabled ? .primary : .secondary)
                                        Text("\(role.stage.label) · \(status(role))").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }.listStyle(.sidebar)
                Divider()
                Button { creating = true } label: {
                    Label("新建员工", systemImage: "plus").font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 6)
                }.buttonStyle(.bordered).padding(12).disabled(app.store.state.connections.isEmpty)
            }.frame(width: 250)
            Divider()
            if showsStaffing { staffing } else if let role = selected { detail(role) }
            else { RelayEmpty(symbol: "person", title: "还没有员工", detail: "点左下角“新建员工”。").frame(maxHeight: .infinity) }
        }
        .workbenchCard(creating, close: { creating = false }) {
            RelayRoleEditor(model: app, role: .init(name: "", stage: .executor, connectionID: app.store.state.connections.first?.id ?? ""),
                            onSave: { model.employeeID = $0.id; showsStaffing = false; model.peopleTab = .settings }, close: { creating = false })
        }
        .onAppear { routing = app.store.state.routing }
    }

    private func rowButton<Label: View>(selected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 5)
                .background(selected ? RelayStyle.sidebarSelection : .clear, in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Existing, connected and running are three different facts (FE §5.1).
    private func status(_ role: RelayRole) -> String {
        if !role.enabled { return "已停用" }
        let open = model.host.allAssignments().filter { $0.ownerID == role.id && $0.isOpen }
        if open.contains(where: { model.host.running.contains($0.id) }) { return "执行中" }
        if app.store.state.runs.contains(where: { $0.status.isWorking && $0.currentRoleID == role.id }) { return "执行中" }
        if let waiting = open.first { return waiting.state == .awaitingReceipt ? "等回执被接收" : "排队中" }
        return role.isOnDuty() ? "空闲" : "不在工作时间"
    }

    /// The default staffing of new tasks (formerly the top card of 员工与分工).
    private var staffing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("默认分工").font(.system(size: 22, weight: .semibold))
                Text("新建任务时预填这套分工；每个任务仍可单独调整。只有一位执行员工且不选总调度时直接交给他。").font(.system(size: 12)).foregroundStyle(.secondary)
                RelayCard {
                    RelayAssignmentBoard(roles: app.store.state.roles, connections: app.store.state.connections,
                        planner: $routing.coordinatorID, executors: $routing.executorIDs, tester: $routing.testerID, reviewer: $routing.reviewerID)
                }
                HStack {
                    Spacer()
                    Button("保存默认分工") {
                        app.perform {
                            var next = app.store.state
                            next.routing.coordinatorID = routing.coordinatorID; next.routing.executorIDs = routing.executorIDs
                            next.routing.testerID = routing.testerID; next.routing.reviewerID = routing.reviewerID
                            try app.store.commit(next); app.notice = "默认分工已保存，将用于新任务。"
                        }
                    }.buttonStyle(.borderedProminent).tint(RelayStyle.action)
                }
            }.padding(24)
        }
    }

    private func detail(_ role: RelayRole) -> some View {
        let connection = app.store.state.connections.first { $0.id == role.connectionID }
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    RelayAvatar(role: role, connection: connection, active: status(role) == "执行中", size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(role.name).font(.system(size: 20, weight: .semibold))
                            RelayStatusPill(text: status(role), color: status(role) == "执行中" ? RelayPalette.green : .secondary, pulsing: status(role) == "执行中")
                        }
                        HStack(spacing: 12) {
                            Text("\(role.stage.label) · \(connection?.name ?? "未连接")")
                            Text(app.effectiveModel(role, connection: connection).model).font(.system(size: 11, design: .monospaced))
                            if role.workHours != nil { Text(role.isOnDuty() ? "在工作时间" : "不在工作时间") }
                            if let standIns = role.standIns, !standIns.isEmpty { Text("候补：\(standIns.map(model.host.name).joined(separator: " → "))") }
                        }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Picker("", selection: $model.peopleTab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).frame(width: 260)
                }
            }.padding(20)
            Divider()
            switch tab {
            case .chat: chat(role)
            case .work: work(role)
            case .deliveries: deliveries(role)
            case .settings: settings(role)
            }
        }
    }

    /// The full role editor inline, then the employee's notes; deleting stays here, at the end.
    private func settings(_ role: RelayRole) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                RelayRoleEditor(model: app, role: role, embedded: true).id(role.id)
                memory(role).padding(.horizontal, 20)
                HStack {
                    Spacer()
                    Button("删除员工", role: .destructive) { app.perform { try app.store.deleteRole(role.id); model.employeeID = nil } }
                        .help("历史任务和交付保留；只想暂停他接新工作时，关掉上面的“启用角色”即可。")
                }.padding(20)
            }
        }
    }

    private func chat(_ role: RelayRole) -> some View {
        let channel = RelayWorkforceHost.directChannel(role.id)
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.host.messages(channel)) { message in
                            RelayWorkbenchMessage(message: message, author: role.name, openReceipt: model.open(receipt:)).id(message.id)
                        }
                        RelayDispatchStrip(app: model.app, host: model.host, channelID: channel)
                        Color.clear.frame(height: 1).id("end")
                    }.padding(20)
                }
                .modifier(RelayFollowBottom(atBottom: $atBottom))
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: model.host.messages(channel).count) { if atBottom { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } } }
            }
            Divider()
            RelayWorkbenchComposer(text: Binding(get: { model.drafts[channel] ?? "" }, set: { model.drafts[channel] = $0 }),
                                   placeholder: role.enabled ? "和 \(role.name) 说…；要他完成的工作会建成任务，由他拆解分配" : "\(role.name) 已停用",
                                   send: { model.host.sendDirect(role.id, text: $0) }, sendTask: { model.host.sendDirect(role.id, text: $0, asTask: true) })
                .disabled(!role.enabled)
        }
    }

    private func work(_ role: RelayRole) -> some View {
        let items = model.host.allAssignments().filter { $0.ownerID == role.id }.sorted { $0.updatedAt > $1.updatedAt }
        let tasks = dispatched(role)
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !tasks.isEmpty {
                    Text("他负责的任务 · \(tasks.count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(tasks, id: \.0.id) { record, run in RelayDispatchedRunRow(app: model.app, record: record, run: run) }
                    Text("对话与工作").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 8)
                }
                if items.isEmpty && tasks.isEmpty { RelayEmpty(symbol: "tray", title: "还没有工作", detail: "私聊、群聊和后台工作派给他的事都会出现在这里。") }
                ForEach(items) { item in
                    RelayCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.instruction).font(.system(size: 13)).lineLimit(3)
                            HStack {
                                Text(item.channelID.flatMap { id in model.host.channels().first { $0.id == id }?.name } ?? (item.workflowRunID == nil ? "私聊" : "后台工作"))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                Spacer()
                                RelayResultBadges(result: item.result)
                            }
                        }
                    }
                }
            }.padding(20)
        }
    }

    /// Tasks this employee led (dispatched from a chat), newest first.
    private func dispatched(_ role: RelayRole) -> [(RelayTaskDispatch, RelayRun)] {
        model.host.dispatches().filter { $0.employeeID == role.id }.sorted { $0.createdAt > $1.createdAt }
            .compactMap { record in model.app.store.state.runs.first { $0.id == record.id && $0.archivedAt == nil }.map { (record, $0) } }
    }

    private func deliveries(_ role: RelayRole) -> some View {
        let receipts = model.host.receipts().filter { $0.authorID == role.id }.sorted { $0.createdAt > $1.createdAt }
        let finished = dispatched(role).filter { $0.1.status == .succeeded }
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(finished, id: \.0.id) { record, run in
                    RelayCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            RelayDispatchedRunRow(app: model.app, record: record, run: run)
                            if !run.output.isEmpty { Text(run.output).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled) }
                        }
                    }
                }
                if receipts.isEmpty && finished.isEmpty { RelayEmpty(symbol: "shippingbox", title: "还没有交付", detail: "他负责的任务完成后、或群聊请求提交回执后，会列在这里。") }
                ForEach(receipts) { receipt in RelayReceiptCard(receipt: receipt, host: model.host) { model.open(receipt: receipt.id) } }
            }.padding(20)
        }
    }

    /// Notes are scoped and sourced; a channel's notes never become the employee's own (FE §5.1).
    private func memory(_ role: RelayRole) -> some View {
        var profile = model.host.profile(role.id)
        return VStack(alignment: .leading, spacing: 12) {
            Text("工作笔记与记忆").font(.headline).padding(.top, 8)
            HStack {
                Text("记忆范围").font(.system(size: 12, weight: .medium))
                Picker("", selection: Binding(get: { profile.memoryPolicy }, set: { profile.memoryPolicy = $0; model.host.saveProfile(profile) })) {
                    Text("不保留").tag(RelayEmployeeProfile.MemoryPolicy.none)
                    Text("员工自己的").tag(RelayEmployeeProfile.MemoryPolicy.employee)
                    Text("按群分开").tag(RelayEmployeeProfile.MemoryPolicy.channel)
                }.frame(width: 160)
                Spacer()
                Picker("默认项目", selection: Binding(get: { profile.projectID ?? "" }, set: { profile.projectID = $0.isEmpty ? nil : $0; model.host.saveProfile(profile) })) {
                    Text("第一个项目").tag("")
                    ForEach(model.app.store.state.projects) { Text($0.name).tag($0.id) }
                }.frame(width: 240)
            }
            VStack(alignment: .leading, spacing: 8) {
                if profile.notes.isEmpty { Text("还没有笔记。换新会话时，这里的笔记会带给他。").font(.caption).foregroundStyle(.secondary) }
                ForEach(profile.notes) { item in
                    HStack {
                        Toggle("", isOn: Binding(get: { item.enabled }, set: { value in
                            if let index = profile.notes.firstIndex(where: { $0.id == item.id }) { profile.notes[index].enabled = value; model.host.saveProfile(profile) }
                        })).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.text).font(.system(size: 13))
                            Text("\(item.scope == "employee" ? "员工笔记" : "群笔记") · 来源：\(item.source) · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                TextField("加一条工作笔记（下次换新会话时带给他）", text: $note).relayField()
                Button("添加") {
                    profile.notes.append(.init(text: note, scope: "employee", source: "用户添加")); model.host.saveProfile(profile); note = ""
                }.disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// UI09: one delivery card for employees, channels, branches and the delivery center.
struct RelayReceiptCard: View {
    var receipt: RelayDeliveryReceipt
    var host: RelayWorkforceHost
    var open: () -> Void
    var body: some View {
        RelayCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(receipt.summary).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    Spacer()
                    RelayBadge(text: label, color: receipt.state == .accepted ? RelayPalette.green : receipt.state == .submitted ? RelayPalette.amber : .secondary)
                }
                HStack(spacing: 12) {
                    Text(host.name(receipt.authorID)); Text("\(receipt.items.count) 个文件"); Text(receipt.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if receipt.supersedes != nil { Text("修订版") }
                    Spacer()
                    Button("查看完整报告", action: open).buttonStyle(.link)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
    private var label: String {
        switch receipt.state { case .submitted: "待接收"; case .accepted: "已接收交付"; case .rejected: "已退回"; case .superseded: "已被替代" }
    }
}
