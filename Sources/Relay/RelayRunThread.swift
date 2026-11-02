import SwiftUI
import RelayCore

/// A task opened from 项目, shown as a conversation like the Claude and Codex apps (user request, 2026-11-01):
/// your goal and instructions as your messages, then each employee's turns — a collapsible process (reasoning,
/// reads, searches, edits, commands, errors) and the reply. The graph view stays in 工作台.
struct RelayRunThread: View {
    @Bindable var model: RelayAppModel
    let run: RelayRun
    /// Show one employee's turns only; nil = everyone.
    @State private var employee: String?
    /// Turns the user opened or closed; the running turn is open unless closed.
    @State private var toggled: Set<String> = []
    @State private var atBottom = true
    /// The trajectory panel beside the thread (R38); open by default, because seeing how the work unfolded is the
    /// point of opening a task.
    @State private var showTrajectory = true
    @State private var selectedNodeID: String?
    @State private var selectedThreadID: String?
    @State private var scrollRequest = 0
    @State private var historyReady = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let events = model.store.events[run.id] ?? []
        let items = RelayThreadItem.items(run, events: events)
        let graph = RelayTrajectory.build(run: run, events: events)
        let shown = items.filter { item in
            guard let employee else { return true }
            if case .turn(let turn) = item { return (turn.roleID ?? RelayTrajectory.systemLane) == employee }
            return true
        }
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                thread(shown, events: events, proxy: proxy)
                if showTrajectory {
                    Divider().opacity(0.6)
                    RelayTrajectoryPanel(graph: graph, highlightLaneID: employee,
                                         selectedNodeID: selectedNodeID, onSelect: { node in
                        selectedNodeID = node.id
                        if employee != nil && employee != node.laneID { employee = nil }
                        selectedThreadID = node.threadItemID
                        scrollRequest += 1
                    }, onSelectRecord: { record in
                        selectedNodeID = record.nodeID
                        if employee != nil && employee != record.laneID { employee = nil }
                        selectedThreadID = record.threadItemID
                        scrollRequest += 1
                    }, onFocusLane: { id in
                        employee = employee == id ? nil : id
                    }, onClose: {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)) { showTrajectory = false }
                    })
                    // 352 = three 112-wide lanes plus equal margins, so a chip never touches the panel edge.
                    .frame(width: 352)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlayPreferenceValue(RelayLightAnchors.self) { anchors in
                if showTrajectory {
                    GeometryReader { geometry in
                        RelayLightLayer(graph: graph, frames: anchors.mapValues { geometry[$0] },
                                        selectedNodeID: selectedNodeID, historyReady: historyReady).id(run.id)
                    }.allowsHitTesting(false)
                }
            }
        }
        .background(RelayStyle.canvas)
        .onAppear { loadHistory(run.id) }
        .onChange(of: run.id) { _, id in
            employee = nil; toggled = []; selectedNodeID = nil; selectedThreadID = nil
            loadHistory(id)
        }
    }

    private func thread(_ shown: [RelayThreadItem], events: [RelayEvent], proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(shown) { item in
                        row(item).id(item.id)
                            .background(selectedThreadID == item.id ? RelayStyle.sidebarSelection.opacity(0.6) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    // Room for the confirmation layer, so it never hides the last turn.
                    Color.clear.frame(height: RelayAttention.kind(run, events: events) == nil ? 8 : 260).id("end")
                }
                .padding(.horizontal, 28).padding(.vertical, 24)
                .frame(maxWidth: 860).frame(maxWidth: .infinity)
            }
            .relayLightAnchor("thread-viewport")
            .modifier(RelayFollowBottom(atBottom: $atBottom))
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: events.count) { _, _ in
                if atBottom { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
            }
            .task(id: scrollRequest) {
                guard let id = selectedThreadID else { return }
                await Task.yield() // Let a changed employee filter install its rows before resolving the scroll ID.
                guard !Task.isCancelled else { return }
                atBottom = false
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
            .overlay(alignment: .bottom) {
                RelayAttentionLayer(model: model, run: run)
                    .padding(.horizontal, 28).padding(.bottom, 14).frame(maxWidth: 860)
                    .animation(.spring(response: 0.3, dampingFraction: 0.9), value: RelayAttention.key(run, events: events))
            }
            RelayInstructionBar(model: model, run: run).id(run.id)
                .padding(.horizontal, 28).padding(.vertical, 12).frame(maxWidth: 860).frame(maxWidth: .infinity)
                .overlay(alignment: .top) { Divider().opacity(0.6) }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(run.input.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                RelayStatusPill(text: run.status.label, color: RelayStyle.status(run.status), pulsing: run.status.isWorking)
                Spacer()
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)) { showTrajectory.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        DravionIcon(name: "flow-arrow", size: 13)
                        Text("轨迹").font(.system(size: 12))
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(showTrajectory ? RelayStyle.sidebarSelection : Color.clear, in: Capsule())
                    .overlay(Capsule().stroke(RelayStyle.border))
                }
                .buttonStyle(.plain)
                .help(showTrajectory ? "收起右侧的执行轨迹" : "在右侧展开执行轨迹：每一步按员工和时间铺开")
                .accessibilityAddTraits(showTrajectory ? .isSelected : [])
                Button { model.selectRun(run.id) } label: {
                    Label { Text("图谱") } icon: { DravionIcon(name: "tree-structure", size: 13) }.font(.system(size: 12))
                }.buttonStyle(.bordered).help("在工作台查看执行图谱、任务步骤和完整记录")
            }
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip(nil, title: "全部", role: nil)
                        ForEach(run.roles) { role in chip(role.id, title: role.name, role: role) }
                    }
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(RelayCountdown.text(run.elapsed(at: context.date))).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }.fixedSize()
                Text("\(RelayTokens.text((run.usage?.tokens.totalInput ?? 0) + (run.usage?.tokens.output ?? 0))) token")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
            }
        }.padding(.horizontal, 24).padding(.vertical, 12)
    }

    private func chip(_ id: String?, title: String, role: RelayRole?) -> some View {
        let selected = employee == id
        return Button { employee = id } label: {
            HStack(spacing: 5) {
                if let role { RelayAvatar(role: role, connection: run.connections.first { $0.id == role.connectionID }, active: false, size: 16) }
                Text(title).font(.system(size: 11.5, weight: selected ? .semibold : .regular)).lineLimit(1)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(selected ? RelayStyle.sidebarSelection : Color.clear, in: Capsule())
            .overlay(Capsule().stroke(RelayStyle.border))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Rows

    @ViewBuilder private func row(_ item: RelayThreadItem) -> some View {
        switch item {
        case .user(let id, let text, let date):
            HStack {
                Spacer(minLength: 120)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(RelayChatReportView.markdown(text)).font(.system(size: 13.5)).textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Text(date.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .relayLightAnchor("message:\(id)")
            }.id(id)
        case .system(_, let text):
            HStack(spacing: 8) {
                Rectangle().fill(RelayStyle.border).frame(height: 1)
                Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Rectangle().fill(RelayStyle.border).frame(height: 1)
            }.padding(.vertical, 2)
        case .turn(let turn):
            turnView(turn)
        }
    }

    private func turnView(_ turn: RelayThreadTurn) -> some View {
        let role = run.roles.first { $0.id == turn.roleID }
        let live = run.status.isWorking && turn.isLast
        let open = toggled.contains(turn.id) ? !live : live
        let stageColor = role.map { RelayPalette.stages[min(RelayPalette.stages.count - 1, max(0, RelayStage.allCases.firstIndex(of: $0.stage) ?? 0))] } ?? .secondary
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                RelayAvatar(role: role, connection: run.connections.first { $0.id == role?.connectionID }, active: live, size: 26)
                Text(role?.name ?? "调度器").font(.system(size: 13, weight: .semibold))
                if let role {
                    Text(role.stage.label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(stageColor)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(stageColor.opacity(0.1), in: Capsule())
                }
                if let title = turn.taskID.flatMap({ id in run.tasks.first { $0.id == id }?.task.title }) {
                    Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(turn.start.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .relayLightAnchor("message:\(turn.id)")
            if !turn.steps.isEmpty || live {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        if toggled.contains(turn.id) { toggled.remove(turn.id) } else { toggled.insert(turn.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0))
                            Text(turn.summary(live: live)).font(.system(size: 12))
                            if live { ProgressView().controlSize(.mini) }
                        }.foregroundStyle(.secondary).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(open ? "收起过程" : "展开过程")
                    if open {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(turn.steps) { step in RelayThreadStep(line: step) }
                            if live { Text("正在处理…").font(.system(size: 11.5)).foregroundStyle(RelayStyle.accent) }
                        }
                        .padding(.leading, 14).padding(.top, 8)
                        .overlay(alignment: .leading) { Rectangle().fill(RelayStyle.border).frame(width: 1).padding(.top, 8) }
                    }
                }.padding(.leading, 35)
            }
            if let reply = turn.reply {
                Text(RelayChatReportView.markdown(reply)).font(.system(size: 13.5)).lineSpacing(3).textSelection(.enabled)
                    .padding(.leading, 35).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func loadHistory(_ id: String) {
        historyReady = false
        do { _ = try model.store.loadEvents(id, fullHistory: true); historyReady = true }
        catch { model.error = error.localizedDescription }
    }
}

/// One step of a turn's process: reasoning in a quiet style, actions as a verb and target, with long output folded.
private struct RelayThreadStep: View {
    let line: RelayEventLine
    @State private var expanded = false
    var body: some View {
        let lines = line.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let head = lines.first ?? ""
        let rest = lines.dropFirst().joined(separator: "\n")
        switch line.tone {
        case .text:
            Text(RelayChatReportView.markdown(line.body)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(expanded ? nil : 4)
                .onTapGesture { expanded.toggle() }.textSelection(.enabled)
        default:
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(color).frame(width: 14)
                    Text(line.verb).font(.system(size: 11.5, weight: .medium)).foregroundStyle(color)
                    Text(head).font(.system(size: 11.5, design: line.tone == .command ? .monospaced : .default)).lineLimit(1).truncationMode(.middle)
                    if line.tone == .write, case let (added, removed) = counts(rest), added + removed > 0 {
                        Text("+\(added)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(RelayPalette.green)
                        Text("−\(removed)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.red)
                    }
                    if !rest.isEmpty {
                        Button(expanded ? "收起" : "展开") { expanded.toggle() }.buttonStyle(.link).font(.system(size: 10.5))
                    }
                }
                if expanded, !rest.isEmpty {
                    ScrollView(.horizontal) {
                        Text(rest.prefix(20_000)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(10)
                    }.frame(maxHeight: 260).background(RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
    private func counts(_ diff: String) -> (Int, Int) {
        let rows = diff.split(separator: "\n")
        return (rows.filter { $0.hasPrefix("+") }.count, rows.filter { $0.hasPrefix("-") }.count)
    }
    private var symbol: String {
        switch line.tone {
        case .command: "terminal"; case .read: "doc.text"; case .write: "pencil"; case .search: "magnifyingglass"
        case .error: "exclamationmark.triangle"; case .test: "checkmark.seal"; case .skill: "sparkles"; default: "circle.fill"
        }
    }
    private var color: Color {
        switch line.tone { case .error: .red; case .write: RelayPalette.ember; case .test: RelayPalette.teal; default: .secondary }
    }
}

/// The thread of a run, derived from its events; nothing is stored separately.
struct RelayThreadTurn: Identifiable {
    var id: String
    var roleID: String?
    var taskID: String?
    var start: Date
    var end: Date
    var steps: [RelayEventLine] = []
    var reply: String?
    var isLast = false
    func summary(live: Bool) -> String {
        let seconds = Int(end.timeIntervalSince(start))
        let time = seconds >= 60 ? "\(seconds / 60) 分 \(seconds % 60) 秒" : "\(max(1, seconds)) 秒"
        var parts = [live ? "正在处理 · 已用 \(time)" : "处理了 \(time)"]
        let count = { (tone: RelayEventLine.Tone) in steps.filter { $0.tone == tone }.count }
        if count(.command) > 0 { parts.append("运行 \(count(.command)) 条命令") }
        if count(.write) > 0 { parts.append("修改 \(count(.write)) 处") }
        if count(.read) + count(.search) > 0 { parts.append("查看 \(count(.read) + count(.search)) 次") }
        if count(.test) > 0 { parts.append("测试 \(count(.test)) 次") }
        if count(.error) > 0 { parts.append("\(count(.error)) 个错误") }
        return parts.joined(separator: " · ")
    }
}

enum RelayThreadItem: Identifiable {
    case user(id: String, text: String, date: Date)
    case system(id: String, text: String)
    case turn(RelayThreadTurn)
    var id: String {
        switch self { case .user(let id, _, _), .system(let id, _): id; case .turn(let turn): turn.id }
    }

    static func items(_ run: RelayRun, events: [RelayEvent]) -> [RelayThreadItem] {
        RelayRunTimeline.items(run: run, events: events).compactMap { item in
            switch item {
            case .user(let id, let text, let date):
                return .user(id: id, text: text, date: date)
            case .status(let event):
                return .system(id: event.id, text: RelayChatFeed.plainStatus(event.message, run: run))
            case .turn(let source):
                guard let first = source.events.first, let last = source.events.last else { return nil }
                var turn = RelayThreadTurn(id: source.id, roleID: source.roleID, taskID: source.taskID,
                                           start: first.date, end: last.date, steps: source.events.map(RelayEventLine.from),
                                           isLast: source.isLast)
                if let index = turn.steps.lastIndex(where: { $0.tone == .text && !$0.body.isEmpty }) {
                    turn.reply = turn.steps[index].body; turn.steps.remove(at: index)
                }
                return .turn(turn)
            }
        }
    }
}
