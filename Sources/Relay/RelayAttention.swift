import SwiftUI
import RelayCore

/// Something a run cannot get past without a person (user requirement, 2026-11-01): it pops up as a card wherever
/// the user is, and floats over the project's 会话 like Codex's approval layer, instead of sitting in the page.
enum RelayAttention {
    enum Kind: Equatable { case sandbox([String]), question, external, milestone, budget, goal, paused }

    static func kind(_ run: RelayRun, events: [RelayEvent]) -> Kind? {
        guard run.archivedAt == nil, !run.status.isTerminal else { return nil }
        let denied = RelaySandboxHint.directories(for: run, events: events)
        if !denied.isEmpty { return .sandbox(denied) }
        if run.pendingQuestion != nil { return .question }
        if run.externalTurnUnconfirmed == true { return .external }
        guard run.status == .paused || run.status == .interrupted, let pause = run.pause else { return nil }
        switch pause.reason {
        case .milestone: return .milestone
        case .budget: return .budget
        case .awaitingGoal: return .goal
        // Waiting for a time window, quota reset or a free seat resolves itself: no one has to act.
        case .schedule, .sessionLimit: return nil
        default: return pause.automatic && pause.resumeAt != nil ? nil : .paused
        }
    }

    /// Identifies one occurrence, so the same wait pops up once and a new one pops up again.
    static func key(_ run: RelayRun, events: [RelayEvent]) -> String? {
        guard let kind = kind(run, events: events) else { return nil }
        switch kind {
        case .sandbox(let directories): return "\(run.id):sandbox:\(directories.joined(separator: "|"))"
        case .question: return "\(run.id):question:\(run.pendingQuestion?.id ?? "")"
        case .external: return "\(run.id):external"
        case .milestone: return "\(run.id):milestone:\(run.nextMilestone ?? -1)"
        case .budget: return "\(run.id):budget:\(run.pause?.message ?? "")"
        case .goal: return "\(run.id):goal"
        case .paused: return "\(run.id):paused:\(run.pause?.reason.rawValue ?? ""):\(run.pause?.message ?? "")"
        }
    }

    /// A chat line, not a log: raw client JSON is dropped and the rest kept short (full text is in 执行记录).
    static func readable(_ message: String) -> String {
        let lines = message.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("{") && !$0.hasPrefix("[") && !$0.contains("\"_meta\"") }
        let text = lines.joined(separator: "\n")
        return text.count > 400 ? String(text.prefix(400)) + "…" : (text.isEmpty ? "详见执行记录。" : text)
    }
}

/// The decision itself: the matching existing card (question, sandbox grant, milestone, external call) or the
/// budget / goal / resume choices, under one orange “需要你确认” header.
struct RelayAttentionPanel: View {
    @Bindable var model: RelayAppModel
    let runID: String
    /// In the popup: offer to open the 会话 and to postpone.
    var popup = false
    @State private var text = ""

    private var run: RelayRun? { model.store.state.runs.first { $0.id == runID } }

    var body: some View {
        if let run, let kind = RelayAttention.kind(run, events: model.store.events[run.id] ?? []) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange).font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("需要你确认").font(.system(size: 15, weight: .semibold))
                        Text("\(run.input.title) · \(run.project.name)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if popup {
                        Button("打开会话") { model.overlay = nil; model.openThread(run.id) }.buttonStyle(.bordered)
                        Button("稍后") { model.overlay = nil }.buttonStyle(.bordered)
                    }
                }
                content(run, kind)
            }
            .padding(18)
            .tint(RelayStyle.action)
        } else if popup {
            // Answered elsewhere (or it resolved itself): the popup closes on its own.
            Color.clear.frame(height: 1).onAppear { model.overlay = nil }
        }
    }

    @ViewBuilder private func content(_ run: RelayRun, _ kind: RelayAttention.Kind) -> some View {
        switch kind {
        case .sandbox(let directories): RelaySandboxCard(model: model, run: run, directories: directories)
        case .question: if let question = run.pendingQuestion { RelayQuestionCard(model: model, run: run, question: question).id(question.id) }
        case .external: RelayExternalTurnCard(model: model, run: run)
        case .milestone: RelayMilestoneConfirmCard(model: model, run: run).id(run.nextMilestone)
        case .budget:
            VStack(alignment: .leading, spacing: 10) {
                Text("时间预算用完了，已在步骤之间暂停。要继续吗？").font(.system(size: 13))
                HStack(spacing: 8) {
                    ForEach([30, 60, 120], id: \.self) { minutes in
                        Button("追加 \(RelayCountdown.short(Double(minutes * 60)))") { model.perform { try model.scheduler.extendBudget(run.id, minutes: minutes) } }
                    }
                    Button("不限时") { model.perform { try model.scheduler.extendBudget(run.id, minutes: nil) } }
                    Spacer()
                    Button("到此结束", role: .destructive) { model.perform { try model.scheduler.stop(run.id) } }
                }.buttonStyle(.bordered)
            }
        case .goal:
            VStack(alignment: .leading, spacing: 10) {
                Text("任务已建好，等你说要做什么。").font(.system(size: 13))
                TextField("写下要完成什么…", text: $text, axis: .vertical).relayField().lineLimit(2...6)
                HStack {
                    Spacer()
                    Button("开始") { model.perform { try model.scheduler.instructAndContinue(run.id, text: text, roleID: nil); text = "" } }
                        .buttonStyle(.borderedProminent).tint(RelayStyle.action)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        case .paused:
            VStack(alignment: .leading, spacing: 10) {
                Text(RelayAttention.readable(run.pause?.message ?? "任务已暂停。")).font(.system(size: 13)).textSelection(.enabled)
                Text("处理好原因后点“继续”；也可以补一句要求再继续。").font(.caption).foregroundStyle(.secondary)
                TextField("补充要求（可选）", text: $text, axis: .vertical).relayField().lineLimit(1...4)
                HStack {
                    Button("停止任务", role: .destructive) { model.perform { try model.scheduler.stop(run.id) } }.buttonStyle(.bordered)
                    Spacer()
                    Button("继续") {
                        model.perform {
                            let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if note.isEmpty { try model.scheduler.resume(run.id) }
                            else { try model.scheduler.instructAndContinue(run.id, text: note, roleID: nil) }
                            text = ""
                        }
                    }.buttonStyle(.borderedProminent).tint(RelayStyle.action)
                }
            }
        }
    }
}

/// Codex-style layer over a 会话: pinned above the input, elevated, with an orange edge.
struct RelayAttentionLayer: View {
    @Bindable var model: RelayAppModel
    let run: RelayRun
    var body: some View {
        if RelayAttention.kind(run, events: model.store.events[run.id] ?? []) != nil {
            RelayAttentionPanel(model: model, runID: run.id)
                .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.orange.opacity(0.55), lineWidth: 1.2))
                .shadow(color: .black.opacity(0.22), radius: 22, y: 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("attention-layer")
        }
    }
}

/// Pops the card up once per new wait, wherever the user is (unless that 会话 is already open — its layer shows it,
/// or another card is open — it waits its turn).
struct RelayAttentionWatcher: ViewModifier {
    @Bindable var model: RelayAppModel
    @State private var shown: Set<String> = []
    private var pending: [(key: String, runID: String)] {
        model.store.state.runs.compactMap { run in
            RelayAttention.key(run, events: model.store.events[run.id] ?? []).map { (key: $0, runID: run.id) }
        }
    }
    func body(content: Content) -> some View {
        content.onChange(of: pending.map(\.key)) { _, _ in check() }
            .onChange(of: model.overlay == nil) { _, _ in check() }
            .onAppear { check() }
    }
    private func check() {
        guard model.overlay == nil, !model.showsComposer else { return }
        for item in pending where !shown.contains(item.key) {
            shown.insert(item.key)
            if model.section == .thread, model.selectedRunID == item.runID, !model.showsWorkbench { continue }
            let runID = item.runID
            model.present("attention-\(runID)", width: 640) { RelayAttentionPanel(model: model, runID: runID, popup: true) }
            return
        }
    }
}
