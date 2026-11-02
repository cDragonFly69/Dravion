import SwiftUI
import RelayCore

// MARK: - Roadmap

/// The project's milestones for this run: what is done (with the reviewer's summary), what is being worked on
/// (with its task progress), and what has not started.
struct RelayMilestoneRoadmap: View {
    let run: RelayRun
    var framed = true
    /// Single-line goals, for the narrow column beside the task steps.
    var compact = false
    private var milestones: [RelayMilestone] { run.displayMilestones }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let done = milestones.filter { $0.status == .done }.count
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("项目里程碑").font(.system(size: 15, weight: .semibold))
                    Text(run.milestones == nil ? "单阶段任务 · 一次交付" : "\(done) / \(milestones.count) 已完成").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                RelayProgressRing(fraction: Double(done) / Double(max(1, milestones.count)), color: RelayPalette.green, size: 30)
            }
            if milestones.isEmpty {
                Text(run.status.isTerminal ? "这次任务没有生成方案。" : "总调度拆分方案后显示里程碑。").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(milestones.enumerated()), id: \.offset) { index, milestone in
                    row(index, milestone, last: index == milestones.count - 1)
                }
            }
        }
        .relayFramed(framed, padding: 20)
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85), value: milestones.map(\.status))
    }

    private func row(_ index: Int, _ milestone: RelayMilestone, last: Bool) -> some View {
        let tasks = run.milestoneTasks(index)
        let finished = tasks.filter { $0.status == .succeeded }.count
        let color: Color = milestone.status == .done ? RelayPalette.green : milestone.status == .active ? RelayPalette.ember : .secondary
        return HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                RelayStepMark(state: milestone.status == .done ? .done : milestone.status == .active ? (run.status.isWorking ? .active : .waiting) : .pending,
                              number: index + 1, color: color)
                if !last {
                    Rectangle().fill(milestone.status == .done ? RelayPalette.green.opacity(0.5) : Color.primary.opacity(0.1))
                        .frame(width: 2).frame(minHeight: 22, maxHeight: .infinity)
                }
            }.frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(milestone.title).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(milestone.status == .pending ? .secondary : .primary)
                    RelayBadge(text: milestone.status == .done ? "已完成" : milestone.status == .active ? "进行中" : "未开始", color: color)
                    Spacer()
                    if !tasks.isEmpty { Text("\(finished)/\(tasks.count) 子任务").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
                }
                Text(milestone.goal).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(compact ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                if milestone.status == .active, !tasks.isEmpty {
                    RelaySegmentBar(total: tasks.count, done: finished, running: tasks.filter { $0.status == .running }.count, color: color)
                        .frame(height: 5).padding(.top, 2)
                }
                if let summary = milestone.summary, milestone.status == .done {
                    Label(summary, systemImage: "checkmark.seal").font(.system(size: 11)).foregroundStyle(RelayPalette.green)
                        .lineLimit(compact ? 2 : 6).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.bottom, last ? 0 : 16)
        }
    }
}

/// "Stage done — here is the next one": confirm (or rewrite) the next goal, or end here.
struct RelayMilestoneConfirmCard: View {
    let model: RelayAppModel
    let run: RelayRun
    @State private var goal = ""
    var body: some View {
        if let index = run.nextMilestone, let milestones = run.milestones {
            let finished = milestones.filter { $0.status == .done }
            RelayCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        RelayStepMark(state: .done, number: finished.count, color: RelayPalette.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("第 \(finished.count) 阶段「\(finished.last?.title ?? "")」已完成").font(.system(size: 14, weight: .semibold))
                            Text("已停止调用，不再消耗额度。确认下一阶段目标后，总调度才会拆具体任务。").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        RelayBadge(text: "等你确认", color: RelayPalette.violet)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("下一阶段 · 第 \(index + 1) 阶段「\(milestones[index].title)」").font(.system(size: 12, weight: .medium)).foregroundStyle(RelayPalette.violet)
                        TextField("下一阶段目标", text: $goal, axis: .vertical).relayField().lineLimit(2...6)
                            .accessibilityIdentifier("milestone-goal")
                    }
                    HStack {
                        Text("可以直接修改目标或补充要求。").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("到此结束") { model.perform { try model.scheduler.endAtMilestone(run.id) } }
                        Button("确认，拆下一阶段任务") { model.perform { try model.scheduler.confirmMilestone(run.id, goal: goal) } }
                            .buttonStyle(.borderedProminent).disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("confirm-milestone")
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(RelayPalette.violet.opacity(0.35)))
            .onAppear { goal = milestones[index].goal }
            .onChange(of: index) { _, value in goal = milestones[value].goal }
        }
    }
}

// MARK: - Task stepper

/// The run's sub-tasks as a vertical stepper: done steps carry a drawn check, running steps pulse and shimmer
/// in their stage colour, waiting steps are dimmed. Staged runs group steps under their milestone.
struct RelayTaskStepper: View {
    let run: RelayRun
    var framed = true
    let select: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !run.tasks.isEmpty {
            let done = run.tasks.filter { $0.status == .succeeded }.count
            SwiftUI.Group {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 12) {
                        RelayProgressRing(fraction: Double(done) / Double(run.tasks.count), color: RelayPalette.ember, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("任务步骤").font(.system(size: 15, weight: .semibold))
                            Text(currentLine).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("点击查看输出、代码和验收标准").font(.caption).foregroundStyle(.tertiary)
                    }
                    RelayPhaseRail(run: run)
                    ForEach(groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            if let title = group.title.isEmpty ? nil : group.title {
                                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(group.color).padding(.bottom, 6).padding(.top, 4)
                            }
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                step(item, number: group.offset + index + 1, last: index == group.items.count - 1, color: group.color)
                            }
                        }
                    }
                    Divider().opacity(0.5)
                    HStack(spacing: 14) {
                        evidence("实际测试", run.testExitCode.map { $0 == 0 ? "通过" : "退出码 \($0)" }, ok: run.testExitCode.map { $0 == 0 })
                        evidence("质检", run.quality.map { $0.passed ? "通过" : "需返工" }, ok: run.quality?.passed)
                        evidence("复审", run.review.map { $0.passed ? "通过" : "需返工" }, ok: run.review?.passed)
                        Spacer()
                        if run.round > 0 { RelayBadge(text: "第 \(run.round) 轮返工", color: .orange) }
                    }
                }
            }
            .relayFramed(framed, padding: 22)
            .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.85), value: run.tasks.map(\.status))
        }
    }

    private struct Group { var title: String; var color: Color; var offset: Int; var items: [RelayWorkItem] }
    private var groups: [Group] {
        guard let milestones = run.milestones else { return [.init(title: "", color: RelayPalette.ember, offset: 0, items: run.tasks)] }
        var offset = 0
        return milestones.enumerated().compactMap { index, milestone in
            let items = run.tasks.filter { $0.task.stage == index }
            guard !items.isEmpty else { return nil }
            defer { offset += items.count }
            return .init(title: "第 \(index + 1) 阶段 · \(milestone.title)", color: milestone.status == .done ? RelayPalette.green : RelayPalette.ember, offset: offset, items: items)
        }
    }
    private var currentLine: String {
        let running = run.tasks.filter { $0.status == .running }
        if !running.isEmpty { return "正在执行：" + running.map(\.task.title).joined(separator: "、") }
        if run.status == .testing { return "正在验证：实际测试与质量检查" }
        if run.status == .reviewing { return "正在复审" }
        if run.status == .succeeded { return "全部完成" }
        return "\(run.tasks.filter { $0.status == .succeeded }.count) / \(run.tasks.count) 已完成 · \(run.activityLabel)"
    }

    private func step(_ item: RelayWorkItem, number: Int, last: Bool, color: Color) -> some View {
        let state: RelayNodeState = switch item.status {
        case .succeeded: .done
        case .running: run.status.isWorking ? .active : .waiting
        case .paused: .waiting
        case .failed: .failed
        case .pending: .pending
        }
        let role = run.roles.first { $0.id == item.task.roleId }
        return Button { select(item.id) } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    RelayStepMark(state: state, number: number, color: state == .done ? RelayPalette.green : color)
                    if !last {
                        Rectangle().fill(state == .done ? RelayPalette.green.opacity(0.45) : Color.primary.opacity(0.1))
                            .frame(width: 2).frame(minHeight: 14, maxHeight: .infinity)
                    }
                }.frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if state == .active { RelayShimmerText(text: item.task.title).font(.system(size: 13, weight: .semibold)) }
                        else { Text(item.task.title).font(.system(size: 13, weight: state == .pending ? .regular : .medium)).foregroundStyle(state == .pending ? .secondary : .primary) }
                        Spacer()
                        if state == .active { RelayTypingDots(color: color, size: 4) }
                        Text(item.status.label).font(.system(size: 11, weight: .medium)).foregroundStyle(state.color)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 6) {
                        if let role {
                            Circle().fill(RelayStyle.color(role.color)).frame(width: 6, height: 6)
                            Text(role.name).font(.system(size: 11)).foregroundStyle(RelayStyle.color(role.color))
                        }
                        if let started = item.startedAt, let ended = item.endedAt {
                            Text("· 用时 \(RelayCountdown.short(ended.timeIntervalSince(started)))").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                    if !item.task.dependsOn.isEmpty, state == .pending {
                        Text("等待：" + item.task.dependsOn.map { id in run.tasks.first { $0.id == id }?.task.title ?? id }.joined(separator: "、"))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .padding(10)
                .background(state == .active ? color.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(state == .active ? color.opacity(0.35) : .clear))
                .padding(.bottom, last ? 0 : 6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("task-detail-\(item.id)")
    }

    private func evidence(_ label: String, _ value: String?, ok: Bool?) -> some View {
        HStack(spacing: 5) {
            Circle().fill(ok == true ? RelayPalette.green : ok == false ? Color.orange : Color.primary.opacity(0.2)).frame(width: 6, height: 6)
            Text("\(label)：\(value ?? "尚未执行")").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// Plan → execute → test → review as four coloured segments; the current one glows.
struct RelayPhaseRail: View {
    let run: RelayRun
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let index = run.stageIndex
        HStack(spacing: 6) {
            ForEach(Array(["规划", "执行", "测试", "复审"].enumerated()), id: \.offset) { step, title in
                let color = RelayPalette.stages[step]
                let current = step == index && !run.status.isTerminal
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(step < index ? color.opacity(0.75) : current ? color : Color.primary.opacity(0.08))
                        .frame(height: 6)
                        .overlay {
                            if current && run.status.isWorking && !reduceMotion {
                                RelaySweep(color: .white, band: 0.4, period: 1.6, strength: 0.75).clipShape(Capsule())
                            }
                        }
                    Text(title).font(.system(size: 11, weight: current ? .semibold : .regular))
                        .foregroundStyle(current ? AnyShapeStyle(color) : step < index ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8), value: index)
    }
}

// MARK: - Marks

/// A step's round mark: number when pending, a pulsing ring when active, a check that draws itself when done.
struct RelayStepMark: View {
    var state: RelayNodeState
    var number: Int
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0
    @State private var pulse = false

    var body: some View {
        ZStack {
            if state == .active {
                Circle().stroke(color.opacity(pulse ? 0 : 0.5), lineWidth: 2).scaleEffect(pulse ? 1.7 : 1)
            }
            Circle().fill(state == .pending ? Color.primary.opacity(0.06) : color.opacity(state == .done ? 1 : 0.14))
            Circle().stroke(state == .pending ? Color.primary.opacity(0.15) : color, lineWidth: state == .done ? 0 : 1.5)
            switch state {
            case .done:
                RelayCheckShape().trim(from: 0, to: drawn).stroke(.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    .frame(width: 11, height: 9)
            case .failed: Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.red)
            case .waiting: Image(systemName: "pause.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.orange)
            case .active: Circle().fill(color).frame(width: 8, height: 8)
            case .pending: Text("\(number)").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
        // Already-done steps show their check at once; only a step finishing on screen draws it.
        .onAppear { drawn = state == .done ? 1 : 0; startPulse() }
        .onChange(of: state) { _, _ in animate() }
    }

    private func animate() {
        if state == .done {
            if reduceMotion { drawn = 1 } else { drawn = 0; withAnimation(.easeOut(duration: 0.45).delay(0.05)) { drawn = 1 } }
        }
        startPulse()
    }
    private func startPulse() {
        pulse = false
        if state == .active && !reduceMotion {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

struct RelayCheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width * 0.38, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// A ring that fills (trim) to `fraction`, with the percentage inside.
struct RelayProgressRing: View {
    var fraction: Double
    var color: Color
    var size: CGFloat = 32
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.14), lineWidth: 3.5)
            Circle().trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((fraction * 100).rounded()))").font(.system(size: size * 0.3, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.85), value: fraction)
    }
}

/// `total` segments: done ones solid, running ones shimmering, the rest faint.
struct RelaySegmentBar: View {
    var total: Int
    var done: Int
    var running: Int
    var color: Color
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(1, total), id: \.self) { index in
                Capsule().fill(index < done ? color : index < done + running ? color.opacity(0.45) : Color.primary.opacity(0.08))
                    .overlay { if index >= done && index < done + running { RelaySweep(color: .white, band: 0.6, period: 1.3, strength: 0.8).clipShape(Capsule()) } }
            }
        }
    }
}

extension RelayRun {
    /// The roadmap to show: a staged run's milestones, or — for a single-stage run — the whole run as one milestone,
    /// so the roadmap and its tile never come up empty once there is a plan.
    var displayMilestones: [RelayMilestone] {
        if let milestones { return milestones }
        guard plan != nil || !tasks.isEmpty else { return [] }
        var single = RelayMilestone(title: "完成目标", goal: plan?.summary ?? input.goal,
                                    status: status == .succeeded ? .done : .active)
        if status == .succeeded { single.summary = review?.summary }
        return [single]
    }
    /// Sub-tasks under the `index`-th displayed milestone.
    func milestoneTasks(_ index: Int) -> [RelayWorkItem] {
        milestones == nil ? tasks : tasks.filter { $0.task.stage == index }
    }
}

extension View {
    /// Wraps the view in a `RelayCard` when it stands alone on the page; inside a panel it is drawn bare.
    @ViewBuilder func relayFramed(_ framed: Bool, padding: CGFloat = 20) -> some View {
        if framed { RelayCard(padding: padding) { self } } else { self }
    }
}
