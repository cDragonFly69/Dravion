import SwiftUI
import RelayCore

/// The live status bar along the bottom of the dashboard: the run's heartbeat, the latest log line rolling in,
/// and every employee's state with a running timer. Clicking it opens a tray with the recent log and one card per
/// employee; the full log stays in the drawer (⇧⌘L).
struct RelayActivityBar: View {
    let model: RelayAppModel
    let run: RelayRun
    @AppStorage("dashboard.activityExpanded") private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var live: Bool { run.status.isWorking && run.waitingForSession == nil }

    var body: some View {
        let lines = RelayActivity.lines(model.store.events[run.id] ?? [], limit: expanded ? 12 : 1)
        let agents = RelayActivity.agents(run)
        VStack(spacing: 0) {
            if expanded {
                tray(lines: lines, agents: agents)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                Divider().opacity(0.5)
            }
            strip(latest: lines.last, agents: agents)
        }
        .background(RelayStyle.canvas)
        .overlay(alignment: .top) {
            ZStack {
                Divider().opacity(0.6)
                // A thin band of light runs along the top edge while someone is working.
                if live && !reduceMotion { RelaySweep(color: RelayStyle.accent, band: 0.25, period: 2.8, strength: 0.7).frame(height: 1.5) }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: expanded)
        .accessibilityIdentifier("activity-bar")
    }

    // MARK: Strip

    private func strip(latest: RelayEventLine?, agents: [RelayActivity.Agent]) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                if live { RelayPulseDot(color: RelayStyle.accent, size: 5) }
                else { Circle().fill(RelayStyle.status(run.status)).frame(width: 6, height: 6) }
                Text(run.activityLabel).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }.fixedSize()
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 12)
            ZStack(alignment: .leading) {
                if let latest {
                    RelayActivityLine(line: latest, roles: run.roles, compact: true)
                        .id(latest.id)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity.combined(with: .offset(y: -10))))
                } else {
                    Text("还没有执行记录").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).clipped()
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: latest?.id)
            HStack(spacing: 4) {
                ForEach(agents.prefix(6)) { agent in RelayActivityAgentChip(agent: agent) }
                if agents.count > 6 { Text("+\(agents.count - 6)").font(.system(size: 10.5)).foregroundStyle(.secondary) }
            }.fixedSize()
            let running = (run.callRecords ?? []).filter { $0.status == .running }.count
            if running > 0 {
                Text("\(running) 个调用进行中").font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit().fixedSize()
            }
            Button {
                model.present("log", style: .drawer, width: 760) { RelayRunLogPanel(model: model, runID: run.id) }
            } label: { DravionIcon(name: "terminal-window", size: 12) }
                .buttonStyle(.borderless).help("打开完整执行记录（⇧⌘L）")
            Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 180 : 0))
        }
        .padding(.horizontal, 20).frame(height: 30)
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
        .help(expanded ? "收起" : "展开最近的执行记录和员工状态")
    }

    // MARK: Tray

    private func tray(lines: [RelayEventLine], agents: [RelayActivity.Agent]) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("最近执行").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                // Scrolls inside the tray (newest at the bottom) instead of spilling over the strip below.
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(lines) { line in
                            RelayActivityLine(line: line, roles: run.roles, compact: false)
                                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                        }
                        if lines.isEmpty { Text("还没有执行记录").font(.system(size: 11)).foregroundStyle(.tertiary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never).defaultScrollAnchor(.bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: lines.last?.id)
            VStack(alignment: .leading, spacing: 6) {
                Text("员工状态").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(agents) { agent in RelayActivityAgentCard(model: model, run: run, agent: agent) }
                    }
                }.scrollIndicators(.never)
            }
            .frame(width: 300).frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(height: 236, alignment: .top)
        .clipped()
    }
}

/// What the bar shows, worked out from the run.
enum RelayActivity {
    enum State: Equatable {
        case working(since: Date?), waiting(String), queued, failed, done, idle
        var label: String {
            switch self {
            case .working: return "执行中"
            case .waiting(let reason): return reason
            case .queued: return "排队"
            case .failed: return "失败"
            case .done: return "已完成"
            case .idle: return "空闲"
            }
        }
        var color: Color {
            switch self {
            case .working: return RelayStyle.accent
            case .waiting: return .orange
            case .queued: return .secondary
            case .failed: return .red
            case .done: return RelayPalette.green
            case .idle: return Color.secondary.opacity(0.6)
            }
        }
    }

    struct Agent: Identifiable {
        var role: RelayRole
        var state: State
        var call: RelayCallRecord?
        var task: String?
        var id: String { role.id }
    }

    /// The latest readable lines, oldest first. Only the tail of the log is looked at.
    static func lines(_ events: [RelayEvent], limit: Int) -> [RelayEventLine] {
        let kinds: Set<RelayEventKind> = [.tool, .text, .test, .error, .status, .input]
        var result: [RelayEventLine] = []
        for event in events.suffix(200).reversed() where kinds.contains(event.kind) {
            let line = RelayEventLine.from(event)
            guard !line.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            result.append(line)
            if result.count == limit { break }
        }
        return result.reversed()
    }

    /// Everyone with work in this run (a task, a call, or the current turn), busiest first.
    static func agents(_ run: RelayRun) -> [Agent] {
        let calls = run.callRecords ?? []
        let involved = run.roles.filter { role in
            role.id == run.currentRoleID || run.tasks.contains { $0.task.roleId == role.id } || calls.contains { $0.roleID == role.id }
        }
        let agents = (involved.isEmpty ? run.roles : involved).map { role -> Agent in
            let call = calls.last { $0.roleID == role.id }
            let tasks = run.tasks.filter { $0.task.roleId == role.id }
            let current = tasks.first { $0.status == .running } ?? (role.id == run.currentRoleID ? run.tasks.first { $0.id == run.currentTaskID } : nil)
            let state: State
            if let waiting = run.waitingForSession, role.id == run.currentRoleID { state = .waiting(waiting.isEmpty ? "等待名额" : "等待名额") }
            else if call?.status == .waitingUser { state = .waiting("等你回复") }
            else if call?.status == .running, run.status.isWorking { state = .working(since: call?.startedAt) }
            else if tasks.contains(where: { $0.status == .running }), run.status.isWorking { state = .working(since: nil) }
            else if tasks.contains(where: { $0.status == .failed }) || call?.status == .failed { state = .failed }
            else if !tasks.isEmpty, tasks.allSatisfy({ $0.status == .succeeded }) { state = .done }
            else if !role.isOnDuty() { state = .waiting("不在岗") }
            else if tasks.contains(where: { $0.status == .pending || $0.status == .paused }) { state = .queued }
            else { state = .idle }
            return Agent(role: role, state: state, call: call, task: current?.task.title)
        }
        let rank: (State) -> Int = {
            switch $0 { case .working: 0; case .waiting: 1; case .failed: 2; case .queued: 3; case .idle: 4; case .done: 5 }
        }
        return agents.enumerated().sorted { (rank($0.element.state), $0.offset) < (rank($1.element.state), $1.offset) }.map(\.element)
    }
}

/// One log line: time, employee, coloured verb, first line of the details.
private struct RelayActivityLine: View {
    let line: RelayEventLine
    let roles: [RelayRole]
    var compact: Bool
    var body: some View {
        let role = roles.first { $0.id == line.roleID }
        HStack(spacing: 6) {
            Text(line.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            if let role {
                HStack(spacing: 4) {
                    Circle().fill(RelayStyle.color(role.color)).frame(width: 5, height: 5)
                    Text(role.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                }.fixedSize()
            }
            if !line.verb.isEmpty {
                Text(line.verb).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color(nsColor: line.logColor)).fixedSize()
            }
            Text(line.body.components(separatedBy: "\n").first ?? "")
                .font(.system(size: 11, design: line.tone == .text ? .default : .monospaced))
                .foregroundStyle(line.tone == .error ? Color.red : .secondary)
                .lineLimit(1).truncationMode(compact ? .middle : .tail)
        }
    }
}

/// An employee in the strip: a state dot (pulsing while working), the name, and how long the call has run.
private struct RelayActivityAgentChip: View {
    let agent: RelayActivity.Agent
    var body: some View {
        let color = RelayStyle.color(agent.role.color)
        HStack(spacing: 4) {
            RelayActivityDot(state: agent.state, color: color)
            Text(agent.role.name).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                .foregroundStyle(agent.state == .idle || agent.state == .done ? .secondary : .primary)
            if case .working(let since?) = agent.state {
                RelayActivityTimer(since: since).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7).frame(height: 20)
        .background(agent.state.isWorking ? color.opacity(0.1) : Color.primary.opacity(0.04), in: Capsule())
        .help("\(agent.role.name)：\(agent.state.label)" + (agent.task.map { " · \($0)" } ?? ""))
    }
}

/// An employee in the tray: state, model, current task and how long the call has run.
private struct RelayActivityAgentCard: View {
    let model: RelayAppModel
    let run: RelayRun
    let agent: RelayActivity.Agent
    var body: some View {
        let color = RelayStyle.color(agent.role.color)
        let connection = run.connections.first { $0.id == agent.role.connectionID }
        HStack(alignment: .top, spacing: 8) {
            RelayActivityDot(state: agent.state, color: color).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.role.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Text(agent.state.label).font(.system(size: 10.5)).foregroundStyle(agent.state.color)
                    if agent.state.isWorking { RelayTypingDots(color: color, size: 3) }
                    Spacer(minLength: 0)
                    if case .working(let since?) = agent.state {
                        RelayActivityTimer(since: since).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Text(agent.call?.reportedModel ?? model.effectiveModel(agent.role, connection: connection).model)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                if let task = agent.task { Text(task).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(agent.state.isWorking ? color.opacity(0.07) : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if agent.state.isWorking { RelaySweep(color: color, band: 0.3, period: 2.4, strength: 0.12).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)) }
        }
    }
}

private struct RelayActivityDot: View {
    let state: RelayActivity.State
    let color: Color
    var body: some View {
        switch state {
        case .working: RelayPulseDot(color: color, size: 5)
        case .done: Image(systemName: "checkmark").font(.system(size: 7.5, weight: .heavy)).foregroundStyle(RelayPalette.green).frame(width: 6, height: 6)
        case .failed: Circle().fill(Color.red).frame(width: 6, height: 6)
        case .waiting: Circle().stroke(Color.orange, lineWidth: 1.2).frame(width: 6, height: 6)
        case .queued, .idle: Circle().fill(state.color).frame(width: 5, height: 5)
        }
    }
}

/// "1:23" since a call started, ticking every second.
private struct RelayActivityTimer: View {
    let since: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            Text(seconds >= 3600 ? "\(seconds / 3600):" + String(format: "%02d:%02d", seconds % 3600 / 60, seconds % 60)
                                 : "\(seconds / 60):" + String(format: "%02d", seconds % 60)).monospacedDigit()
        }
    }
}

extension RelayActivity.State {
    var isWorking: Bool { if case .working = self { return true } else { return false } }
}
