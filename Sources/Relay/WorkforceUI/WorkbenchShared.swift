import AppKit
import SwiftUI
import Observation
import RelayCore

/// The collaboration pages (FE1, revised 2026-11-01: one window, the main sidebar's “协作” group). Their selection
/// and drafts live here, apart from the dashboard's selected run and overlay; all commands go to the shared host.
@MainActor @Observable
final class RelayWorkbenchModel {
    enum Section: String, CaseIterable, Identifiable {
        case people = "员工", channels = "群聊", background = "后台工作", inbox = "待处理", delivery = "交付"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .people: "user-circle"; case .channels: "chats-circle"; case .background: "flow-arrow"; case .inbox: "tray"; case .delivery: "package"
            }
        }
    }
    let app: RelayAppModel
    let host: RelayWorkforceHost
    var section: Section = .channels { didSet { app.showsWorkbench = true } }
    var employeeID: String?
    enum PeopleTab: String, CaseIterable { case chat = "私聊", work = "工作", deliveries = "交付", settings = "设置" }
    var peopleTab = PeopleTab.chat
    var channelID: String?
    /// The task group open in 群聊 instead of a channel (one or the other is shown).
    var taskRunID: String?
    /// The 任务群 list's project-group filter: "all", "none" (no group) or a project group id.
    var groupFilter = "all"
    var workflowID: String?
    var receiptID: String?
    /// Unsent text per conversation (employee DM or channel id); kept while the app runs.
    var drafts: [String: String] = [:]
    init(app: RelayAppModel, host: RelayWorkforceHost) { self.app = app; self.host = host }

    /// Typed navigation (FE §4.3): a target is checked before the jump; a missing one says so.
    func open(receipt id: String) {
        guard host.receipts().contains(where: { $0.id == id }) else { host.reportMissing("回执已不存在或无权查看。"); return }
        receiptID = id; section = .delivery
    }
    func open(channel id: String) { channelID = id; taskRunID = nil; section = .channels }
    func open(taskGroup id: String) { taskRunID = id; section = .channels }
    func open(employee id: String) { employeeID = id; section = .people }
    func open(workflow id: String) { workflowID = id; section = .background }
}

extension RelayWorkforceHost {
    func reportMissing(_ message: String) { onNotify?("无法打开", message) }
}

/// The collaboration page in the main window's detail area; the main sidebar's “协作” group picks the section.
struct RelayWorkbenchContent: View {
    @Bindable var model: RelayWorkbenchModel
    var body: some View {
        Group {
            switch model.section {
            case .people: RelayWorkbenchPeople(model: model)
            case .channels: RelayWorkbenchChannels(model: model)
            case .background: RelayWorkbenchBackground(model: model)
            case .inbox, .delivery: RelayWorkbenchMailbox(model: model)
            }
        }
        .background(RelayStyle.canvas)
        .overlay(alignment: .bottom) {
            if let error = model.host.lastError {
                HStack {
                    Text(error).font(.system(size: 12)).lineLimit(3)
                    Button("知道了") { model.host.clearError() }.buttonStyle(.borderless)
                }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(16)
                .modifier(RelayAutoDismiss(key: error, seconds: 10) { model.host.clearError() })
            }
        }
    }
}

/// 收件箱: what waits for you (待处理) and what was delivered (交付), one outer row with an inner tab.
struct RelayWorkbenchMailbox: View {
    @Bindable var model: RelayWorkbenchModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $model.section) {
                    Text("待处理 \(RelayWorkbenchInbox.pending(model.host))").tag(RelayWorkbenchModel.Section.inbox)
                    Text("交付").tag(RelayWorkbenchModel.Section.delivery)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Spacer()
            }.padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            if model.section == .delivery { RelayWorkbenchDelivery(model: model) } else { RelayWorkbenchInbox(model: model) }
        }
    }
}

/// The four result dimensions side by side (FE §7.5, UI12): read from the host's single reduction, never derived here.
struct RelayResultBadges: View {
    var result: RelayResultProjection
    var body: some View {
        HStack(spacing: 6) {
            RelayBadge(text: result.executionLabel, color: color(for: result.execution))
            if result.businessResult.state != .notReported || result.completionPolicy == .turn {
                RelayBadge(text: "业务：\(result.businessLabel)", color: result.businessResult.state == .failed ? .red : .secondary)
            }
            if result.completionPolicy == .receipt || result.receipt != .none {
                RelayBadge(text: result.receiptLabel, color: result.receipt == .accepted ? RelayPalette.green : result.receipt == .submitted ? RelayPalette.amber : .secondary)
            }
            RelayBadge(text: result.verificationLabel, color: result.verification == .passed ? RelayPalette.green : .secondary)
        }
    }
    private func color(for execution: RelayExecutionState) -> Color {
        switch execution {
        case .running: RelayStyle.accent
        case .ended: RelayPalette.teal
        case .failed, .timedOut: .red
        case .interrupted: RelayPalette.amber
        default: .secondary
        }
    }
}

/// A chat bubble shared by DMs, channels and run logs.
struct RelayWorkbenchMessage: View {
    var message: RelayChannelMessage
    var author: String
    var openReceipt: (String) -> Void
    /// For image previews and attachment chips (the main window's gallery and Quick Look).
    var app: RelayAppModel? = nil
    var root = ""
    var body: some View {
        let (text, attached) = RelayChatFeed.splitAttachments(message.text)
        let images = message.authorKind == .employee ? RelayChatFeed.imagePaths(in: text, root: root) : attached.filter { RelayChatFeed.imageExtensions.contains($0.pathExtension.lowercased()) }
        VStack(alignment: message.authorKind == .user ? .trailing : .leading, spacing: 4) {
            Text(message.authorKind == .user ? "你" : message.authorKind == .system ? "系统" : author).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 13)).textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(message.authorKind == .user ? RelayStyle.sunken : message.authorKind == .system ? Color.clear : RelayStyle.surface,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(message.authorKind == .system ? Color.clear : RelayStyle.border))
                .foregroundStyle(message.authorKind == .system ? .secondary : .primary)
            if let app, !images.isEmpty { RelayImageStrip(model: app, images: images) }
            if let app {
                ForEach(attached.filter { !images.contains($0) }, id: \.path) { url in
                    RelayAttachmentChip(url: url, model: app)
                }
            }
            ForEach(message.receiptIDs, id: \.self) { id in
                Button("查看交付") { openReceipt(id) }.buttonStyle(.link).font(.system(size: 12))
            }
        }.frame(maxWidth: .infinity, alignment: message.authorKind == .user ? .trailing : .leading)
    }
}

/// The fixed composer at the bottom of every conversation; the draft lives in the workbench, not the main window.
struct RelayWorkbenchComposer: View {
    @Binding var text: String
    var placeholder: String
    var send: (String) -> Void
    /// When set, a “作为任务” switch appears: the message is handed over as work and must become a scheduled task.
    var sendTask: ((String) -> Void)? = nil
    /// Files and images go as paths (the employee reads them), like the task groups' composer.
    @State private var attachments: [URL] = []
    @State private var asTask = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(attachments, id: \.path) { url in RelayAttachmentChip(url: url) { attachments.removeAll { $0 == url } } } }
                }
            }
            row
        }
        .padding(14).background(RelayStyle.canvas)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in if !attachments.contains(url) { attachments.append(url) } }
                }
            }
            return true
        }
    }
    private var row: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
                panel.message = "选择要发到群里的图片或文件（只发送路径，员工按路径读取）"
                if panel.runModal() == .OK { attachments += panel.urls.filter { !attachments.contains($0) } }
            } label: { Image(systemName: "paperclip").font(.system(size: 14)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("添加图片或附件（也可以直接拖进来）").padding(.bottom, 8)
            TextField(placeholder, text: $text, axis: .vertical).lineLimit(1...6).relayField()
                .onSubmit(submit)
            if sendTask != nil {
                Toggle("作为任务", isOn: $asTask).toggleStyle(.button).controlSize(.small).padding(.bottom, 6)
                    .help("打开后这条消息一定会建成任务：由他拆解、分配，在工作台和项目会话里实时显示进度")
            }
            Button(action: submit) { DravionIcon(name: "paper-plane-tilt", size: 15) }
                .buttonStyle(.borderedProminent).tint(RelayStyle.action)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                .keyboardShortcut(.return, modifiers: .command).accessibilityLabel("发送")
        }
    }
    private func submit() {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !attachments.isEmpty {
            value += (value.isEmpty ? "" : "\n\n") + RelayChatFeed.attachmentHeader + "\n" + attachments.map(\.path).joined(separator: "\n")
        }
        guard !value.isEmpty else { return }
        if asTask, let sendTask { sendTask(value) } else { send(value) }
        text = ""; attachments = []
    }
}

/// What a chat turn is doing right now, and the tasks this chat dispatched with their live status (指向性任务).
struct RelayDispatchStrip: View {
    let app: RelayAppModel
    let host: RelayWorkforceHost
    let channelID: String
    var body: some View {
        let live = host.allAssignments().filter { host.running.contains($0.id) && (Self.channel(of: $0) == channelID) }
        // Queued and not started: say so (and why), instead of a “thinking” that never ends.
        let waiting = host.allAssignments().filter { $0.state == .queued && $0.callState == .idle && !host.running.contains($0.id) && Self.channel(of: $0) == channelID }
        // Only work in progress stays under the chat; finished tasks live in the employee's 工作 and 交付 tabs.
        let runs = host.dispatches().filter { $0.channelID == channelID }.sorted { $0.createdAt > $1.createdAt }
            .compactMap { record in app.store.state.runs.first { $0.id == record.id && $0.archivedAt == nil }.map { (record, $0) } }
            .filter { !$0.1.status.isTerminal }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(live) { assignment in
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("\(host.name(assignment.ownerID))：\(host.liveNotes[assignment.id] ?? "正在思考…")")
                        .lineLimit(1).truncationMode(.tail)
                }.font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(waiting) { assignment in
                HStack(spacing: 6) {
                    Image(systemName: "hourglass").font(.system(size: 10))
                    Text("\(host.name(assignment.ownerID))：排队中——\(host.waitReason(assignment))").lineLimit(2)
                }.font(.system(size: 12)).foregroundStyle(.orange)
            }
            ForEach(runs, id: \.0.id) { record, run in RelayDispatchedRunRow(app: app, record: record, run: run) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private static func channel(of assignment: RelayWorkAssignment) -> String {
        assignment.channelID ?? RelayWorkforceHost.directChannel(assignment.ownerID)
    }
}

/// One task an employee dispatched: status, project, progress; opens it in 工作台.
struct RelayDispatchedRunRow: View {
    let app: RelayAppModel
    let record: RelayTaskDispatch
    let run: RelayRun
    var body: some View {
        Button { app.selectRun(run.id) } label: {
            HStack(spacing: 8) {
                Circle().fill(run.status.isTerminal ? (run.status == .succeeded ? Color.green : Color.orange) : RelayStyle.accent).frame(width: 7, height: 7)
                Text(run.input.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("\(record.projectName) · \(run.status == .paused ? RelayAttention.readable(run.pause?.message ?? "已暂停") : run.status.label)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                let done = run.tasks.filter { $0.status == .succeeded }.count
                if !run.tasks.isEmpty { Text("\(done)/\(run.tasks.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                Text((run.endedAt ?? run.createdAt).formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(.tertiary)
                Text("在工作台查看").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(RelayStyle.border))
        }.buttonStyle(.plain).help("打开工作台查看执行图谱和任务步骤")
    }
}

extension View {
    /// A card above the page, like the main window's overlays: no `.sheet`, so the window controls stay live.
    func workbenchCard<Card: View>(_ shown: Bool, close: @escaping () -> Void, @ViewBuilder card: () -> Card) -> some View {
        overlay {
            if shown {
                ZStack {
                    Color.black.opacity(0.16).ignoresSafeArea().onTapGesture(perform: close)
                    card().background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(RelayStyle.border))
                        .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
                }.onExitCommand(perform: close)
            }
        }
    }
}

/// Follows new content only while the reader is at the bottom (user feedback, 2026-11-01: the chat kept jumping while
/// they scrolled). Scrolling up stops following; coming back to the bottom resumes it.
struct RelayFollowBottom: ViewModifier {
    @Binding var atBottom: Bool
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 60
            } action: { _, bottom in atBottom = bottom }
        } else { content }
    }
}
