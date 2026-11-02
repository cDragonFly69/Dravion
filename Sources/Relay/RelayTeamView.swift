import SwiftUI
import RelayCore

/// What one employee (role) is doing right now, derived from the runs; nothing is stored separately.
struct RelayEmployeeState {
    enum Kind { case working, waitingQuota, waitingUser, waitingSession, paused, queued, idle }
    var kind: Kind
    var headline: String
    var detail: String?
    var runID: String?
    var resumeAt: Date?

    static func of(_ role: RelayRole, in state: RelayState, events: [String: [RelayEvent]]) -> RelayEmployeeState {
        let runs = state.runs.sorted { ($0.status.isWorking ? 1 : 0) > ($1.status.isWorking ? 1 : 0) }
        for run in runs where !run.status.isTerminal {
            let involved = [run.input.plannerID, run.input.testerID, run.input.reviewerID, run.input.directRoleID ?? ""].contains(role.id)
                || run.input.executorIDs.contains(role.id)
            guard involved else { continue }
            if run.status.isWorking && run.currentRoleID == role.id {
                if let waiting = run.waitingForSession { return .init(kind: .waitingSession, headline: waiting, detail: run.input.title, runID: run.id) }
                let task = run.tasks.first { $0.id == run.currentTaskID }?.task.title
                let last = events[run.id]?.last { $0.roleID == role.id && $0.kind != .usage }.map { RelayEventLine.from($0).summary }
                return .init(kind: .working, headline: task ?? run.status.label, detail: last, runID: run.id)
            }
            if run.status == .paused || run.status == .interrupted, let pause = run.pause, pause.modelKey == role.modelKey || run.currentRoleID == role.id {
                let quota = RelayRecovery.isSubscriptionLimit(pause.message) || RelayRecovery.isQuotaFailure(pause.message)
                let kind: Kind = run.pendingQuestion != nil ? .waitingUser : pause.reason == .sessionLimit ? .waitingSession : quota ? .waitingQuota : .paused
                return .init(kind: kind,
                             headline: pause.message.components(separatedBy: "\n").first ?? "已暂停", detail: run.input.title,
                             runID: run.id, resumeAt: pause.resumeAt)
            }
        }
        if let queued = state.runs.first(where: { $0.status == .queued && ($0.input.executorIDs.contains(role.id) || $0.input.plannerID == role.id) }) {
            return .init(kind: .queued, headline: "排队：\(queued.input.title)", runID: queued.id)
        }
        return .init(kind: .idle, headline: "暂无分配的任务")
    }

    var label: String {
        switch kind {
        case .working: return "工作中"
        case .waitingQuota: return "等待额度"
        case .waitingUser: return "等你回复"
        case .waitingSession: return "等待会话"
        case .paused: return "已暂停"
        case .queued: return "排队中"
        case .idle: return "空闲"
        }
    }
    var color: Color {
        switch kind {
        case .working: return Color(red: 0.16, green: 0.62, blue: 0.38)
        case .waitingQuota, .waitingUser: return .orange
        case .paused, .waitingSession: return .secondary
        case .queued: return RelayStyle.accent
        case .idle: return Color.secondary.opacity(0.6)
        }
    }
}

/// A task's group chat (merged into 群聊, 2026-11-01): the plan, every employee's plain-language reports, the pinned
/// goal and assignments, questions, and a composer whose messages reach the task as instructions at the employee's
/// next call (no extra model calls while nobody is working).
struct RelayTaskGroupChat: View {
    @Bindable var model: RelayAppModel
    var runID: String
    @State private var message = ""
    @State private var recipient: String?
    @State private var attachments: [URL] = []

    var body: some View {
        if let run = model.store.state.runs.first(where: { $0.id == runID }) {
            chat(run)
                .onAppear { model.perform { _ = try model.store.loadEvents(run.id, fullHistory: true) } }
                .onChange(of: runID) { _, id in
                    recipient = nil; message = ""; attachments = []
                    model.perform { _ = try model.store.loadEvents(id, fullHistory: true) }
                }
        } else { RelayEmpty(symbol: "bubble.left.and.bubble.right", title: "任务已不存在", detail: "它可能已被删除。").frame(maxHeight: .infinity) }
    }

    // MARK: Group chat

    private func chat(_ run: RelayRun) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(run.input.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                RelayStatusPill(text: run.status.label, color: RelayStyle.status(run.status), pulsing: run.status.isWorking)
                Spacer()
                Text("\(run.roles.count) 位成员 · \(run.finishedTasks)/\(run.tasks.count) 子任务").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("在工作台查看") { model.selectRun(run.id) }.buttonStyle(.borderless)
            }.padding(14)
            Divider().opacity(0.5)
            RelayGroupStatusBar(model: model, run: run)
            Divider().opacity(0.5)
            RelayPinnedGoal(model: model, run: run)
            let feed = RelayChatFeed.items(run, events: model.store.events[run.id] ?? [])
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if feed.isEmpty {
                            Text("还没有人汇报。员工完成一项工作后，会在这里说明做了什么、改了哪些文件。")
                                .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 40)
                        }
                        ForEach(feed) { item in RelayChatReportView(model: model, run: run, item: item).id(item.id) }
                    }.padding(16)
                }
                .frame(minHeight: 240, maxHeight: .infinity)
                .onChange(of: model.store.events[run.id]?.count) { _, _ in
                    if let last = feed.last?.id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) } }
                }
                .onAppear { if let last = feed.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
            }
            Divider().opacity(0.5)
            if let question = run.pendingQuestion { RelayQuestionCard(model: model, run: run, question: question).padding(14).id(question.id) }
            if run.externalTurnUnconfirmed == true { RelayExternalTurnCard(model: model, run: run).padding(14) }
            composer(run)
        }
    }

    private func composer(_ run: RelayRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments, id: \.path) { url in
                            if RelayChatFeed.imageExtensions.contains(url.pathExtension.lowercased()) {
                                RelayThumbnail(url: url).frame(width: 64, height: 44).clipShape(RoundedRectangle(cornerRadius: 7))
                                    .overlay(alignment: .topTrailing) {
                                        Button { attachments.removeAll { $0 == url } } label: {
                                            Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.55))
                                        }.buttonStyle(.plain).padding(2)
                                    }
                                    .help(url.path)
                            } else {
                                RelayAttachmentChip(url: url) { attachments.removeAll { $0 == url } }
                            }
                        }
                    }.padding(.horizontal, 12).padding(.top, 10)
                }
            }
            composerRow(run)
        }
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

    private func composerRow(_ run: RelayRun) -> some View {
        HStack(spacing: 10) {
            Button {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
                panel.message = "选择要发到群里的图片或文件（只发送路径，员工按路径读取）"
                if panel.runModal() == .OK { attachments += panel.urls.filter { !attachments.contains($0) } }
            } label: { Image(systemName: "paperclip").font(.system(size: 14)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("添加图片或附件（也可以直接拖进来）")
                .disabled(run.status.isTerminal)
            RelayPillMenu(title: recipient.flatMap { id in run.roles.first { $0.id == id }?.name } ?? "所有人", icon: "at") {
                Button("所有人") { recipient = nil }
                Divider()
                ForEach(run.roles) { role in Button(role.name) { recipient = role.id } }
            }.disabled(run.pendingQuestion != nil)
            TextField(run.pendingQuestion != nil ? "回答当前问题，发送后继续原步骤…" : run.status.isTerminal ? "这个任务已结束；发送将新建后续任务" : "发给团队：补充要求、调整方向…", text: $message, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4).frame(minHeight: 22).onSubmit { send(run) }
            Button { send(run) } label: {
                DravionIcon(name: "paper-plane-tilt", size: 15).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(message.isEmpty ? Color.secondary.opacity(0.35) : RelayStyle.action, in: Circle())
            }.buttonStyle(.plain).disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
        }.padding(12)
    }

    private func send(_ run: RelayRun) {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !attachments.isEmpty {
            text += (text.isEmpty ? "" : "\n\n") + RelayChatFeed.attachmentHeader + "\n" + attachments.map(\.path).joined(separator: "\n")
        }
        guard !text.isEmpty else { return }
        if run.status.isTerminal {
            model.draftGoal = text; model.showsComposer = true
            message = ""
        } else {
            do {
                if let question = run.pendingQuestion { try model.scheduler.answer(run.id, questionID: question.id, text: text) }
                else { try model.scheduler.addInstruction(run.id, text: text, roleID: recipient) }
                message = ""; attachments = []
            } catch { model.error = error.localizedDescription }
        }
    }
}


/// Task count, success rate and tokens of a set of tasks (a project group, or all of them).
struct RelayGroupStatsRow: View {
    var runs: [RelayRun]
    var body: some View {
        let stats = RelayGroupStats.overall(runs: runs)
        HStack(spacing: 8) {
            cell("任务", "\(stats.runs)", "成功 \(stats.succeeded) · 失败 \(stats.failed)")
            cell("成功率", percent(stats.successRate), "已结束任务")
            cell("Token", RelayTokens.number(stats.totalTokens), "缓存命中 \(percent(stats.cacheHitRate))")
        }
    }
    private func cell(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8).background(RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 8))
    }
    private func percent(_ value: Double) -> String { value.isFinite ? value.formatted(.percent.precision(.fractionLength(0))) : "—" }
}

/// One employee's card: client, full model name, live status and what they are doing (or waiting for).
struct RelayEmployeeCard: View {
    @Bindable var model: RelayAppModel
    var role: RelayRole
    var open: (String) -> Void = { _ in }
    var body: some View {
        employeeCard(role, RelayEmployeeState.of(role, in: model.store.state, events: model.store.events))
    }
    private var state: RelayState { model.store.state }
    private func employeeCard(_ role: RelayRole, _ status: RelayEmployeeState) -> some View {
        let connection = state.connections.first { $0.id == role.connectionID }
        let effective = model.effectiveModel(role, connection: connection)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                RelayAvatar(role: role, connection: connection, active: status.kind == .working)
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("\(role.stage.label) · \(connection?.kind.label ?? "未连接")").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                RelayStatusPill(text: status.label, color: status.color, pulsing: status.kind == .working)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(effective.model).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1)
                if !effective.detail.isEmpty { Text(effective.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            .background(RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(status.headline).font(.system(size: 12)).lineLimit(2)
                if let resume = status.resumeAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("将于 \(resume.formatted(date: .omitted, time: .shortened)) 自动继续 · 还剩 \(RelayCountdown.text(resume.timeIntervalSince(context.date)))")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.orange)
                    }
                }
                if let detail = status.detail {
                    Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(16)
        .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(status.kind == .working ? status.color.opacity(0.45) : RelayStyle.border, lineWidth: 1))
        .shadow(color: .black.opacity(status.kind == .working ? 0.06 : 0.02), radius: 8, y: 3)
        .onTapGesture { if let id = status.runID { open(id) } }
    }

}

/// Round avatar per client: the client's initial on a tinted disc, with a live ring while working.
struct RelayAvatar: View {
    var role: RelayRole?
    var connection: RelayConnection?
    var active: Bool
    var size: CGFloat = 38
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var pulse = false
    private var tint: Color {
        switch connection?.kind {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(red: 0.2, green: 0.2, blue: 0.22)
        case .deepseekHarness: return Color(red: 0.30, green: 0.42, blue: 0.99)
        case .workbuddy: return Color(red: 0.0, green: 0.57, blue: 0.45)
        case .doubaoApp: return Color(red: 0.93, green: 0.55, blue: 0.16)
        default: return .gray
        }
    }
    private var initial: String {
        switch connection?.kind {
        case .claude: return "C"
        case .codex: return "X"
        case .deepseekHarness: return "D"
        case .workbuddy: return "W"
        case .doubaoApp: return "豆"
        default: return String(role?.name.prefix(1) ?? "?")
        }
    }
    var body: some View {
        ZStack {
            Circle().fill(tint.gradient)
            Text(initial).font(.system(size: size * 0.42, weight: .bold, design: .rounded)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Color(red: 0.16, green: 0.62, blue: 0.38), lineWidth: 2).scaleEffect(pulse ? 1.18 : 1).opacity(active ? (pulse ? 0 : 0.9) : 0))
        .onAppear {
            guard active, !reducedMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityLabel(role?.name ?? "调度器")
    }
}

struct RelayStatusPill: View {
    var text: String
    var color: Color
    var pulsing = false
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 4).background(color.opacity(0.1), in: Capsule())
    }
}

enum RelayCountdown {
    static func text(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60) : String(format: "%02d:%02d", total / 60, total % 60)
    }
}
