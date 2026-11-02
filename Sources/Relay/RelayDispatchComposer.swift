import SwiftUI
import RelayCore

/// 派任务 (user requirement, 2026-11-01): the 新建任务 button hands work to one employee or one group. That employee
/// (or the group's lead) splits and assigns it as a scheduled task — project chosen or created by them — and its
/// progress shows in 工作台, in the project's 会话 and back in this chat. The old manual staffing stays under 高级.
struct RelayDispatchComposer: View {
    @Bindable var model: RelayAppModel
    @State private var target = ""            // "e:<employee>" or "c:<channel>"
    @State private var text = ""
    @State private var projectID = ""         // empty = the employee decides (and may create one)
    @State private var staged = false
    @State private var error: String?

    private var host: RelayWorkforceHost? { model.workforce }
    private var employees: [RelayRole] { (host?.employees() ?? []).filter(\.enabled) }
    private var channels: [RelayChannel] { host?.channels() ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            RelaySheetHeader(title: "派任务", close: close)
            Form {
                Section {
                    Picker("交给", selection: $target) {
                        Section("员工") { ForEach(employees) { Text("\($0.name) · \($0.stage.label)").tag("e:" + $0.id) } }
                        if !channels.isEmpty { Section("群") { ForEach(channels) { Text("群 · \($0.name)").tag("c:" + $0.id) } } }
                    }
                    Text(target.hasPrefix("c:") ? "群负责人拆解并分给群里的成员；进度回到这个群。"
                         : "由他担任总调度：拆解、分配给需要的员工（你在要求里点名的会加入），进度回到你们的私聊。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("要求") {
                    TextEditor(text: $text).font(.system(size: 13)).frame(minHeight: 150)
                }
                Section {
                    Picker("项目", selection: $projectID) {
                        Text("由员工决定（没有合适的就新建）").tag("")
                        ForEach(model.store.state.projects) { Text($0.name).tag($0.id) }
                    }
                    Toggle("分阶段推进（每期做完等我确认）", isOn: $staged)
                }
                if let error { Text(error).foregroundStyle(.orange) }
            }.formStyle(.grouped)
            HStack {
                Button("高级：手动分工") { model.legacyComposer = true }.buttonStyle(.link)
                    .help("按原来的方式自己选总调度、执行、质检和复审")
                Spacer()
                Button("取消", action: close)
                Button("派出去", action: send).buttonStyle(.borderedProminent).tint(RelayStyle.action)
                    .disabled(target.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }.padding(20)
        }
        .frame(width: 620).tint(RelayStyle.action)
        .onAppear {
            if text.isEmpty { text = model.draftGoal }
            if let id = model.draftProjectID { projectID = id }
            if target.isEmpty {
                let lead = employees.first { $0.id == model.store.state.routing.coordinatorID } ?? employees.first
                target = lead.map { "e:" + $0.id } ?? ""
            }
        }
    }

    private func close() { model.showsComposer = false; model.draftGoal = ""; model.draftProjectID = nil }

    private func send() {
        guard let host, let workbench = model.workbench else { error = model.workforceError ?? "协作数据没有打开。"; return }
        var message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let project = model.store.state.projects.first(where: { $0.id == projectID }) { message += "\n\n项目：\(project.name)" }
        if staged { message += "\n分阶段推进：每期做完停下等我确认。" }
        let id = String(target.dropFirst(2))
        if target.hasPrefix("e:") {
            host.sendDirect(id, text: message, asTask: true)
            workbench.employeeID = id; workbench.peopleTab = .chat
            model.openWorkbench(.people)
        } else {
            host.post(id, text: message, asTask: true)
            workbench.channelID = id; workbench.taskRunID = nil
            model.openWorkbench(.channels)
        }
        if let failure = host.lastError { error = failure; return }
        close()
    }
}
