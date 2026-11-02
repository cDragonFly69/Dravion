import SwiftUI
import RelayCore

/// 流程画布 (R40): the run as Lancer's research canvas — executors on the left (grouped by client), the lead in the
/// middle with one row per subtask branch, where the results go on the right; dotted curves between them that
/// flow (with a travelling light) while work runs, and a hand-over strip at the bottom. “暂停动效” stops only motion.
struct RelayFlowCanvas: View {
    @Bindable var model: RelayAppModel
    let run: RelayRun
    var openTask: (String) -> Void
    @AppStorage("flow.paused") private var paused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animating: Bool { !paused && !reduceMotion && !run.status.isTerminal }
    private var leadID: String? { run.input.plannerID.isEmpty ? run.input.directRoleID : run.input.plannerID }
    private func role(_ id: String?) -> RelayRole? { id.flatMap { id in run.roles.first { $0.id == id } } }
    private func connection(_ role: RelayRole?) -> RelayConnection? { role.flatMap { r in run.connections.first { $0.id == r.connectionID } } }
    private func tint(_ role: RelayRole?) -> Color { RelayStyle.color(role?.color ?? "gray") }
    private var executors: [RelayRole] {
        let ids = (run.input.directRoleID.map { [$0] } ?? run.input.executorIDs) + run.tasks.map(\.task.roleId)
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }.compactMap(role)
    }
    private var groups: [(String, [RelayRole])] {
        Dictionary(grouping: executors) { connection($0)?.kind.label ?? "其他" }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            HStack(alignment: .top, spacing: 64) {
                executorColumn.frame(width: 250)
                leadColumn.frame(width: 300)
                resultColumn.frame(width: 270)
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
            .frame(maxWidth: .infinity)
            .backgroundPreferenceValue(RelayFlowPorts.self) { ports in
                GeometryReader { geometry in
                    TimelineView(.animation(paused: !animating)) { timeline in
                        Canvas { context, _ in
                            draw(&context, ports: ports.mapValues { geometry[$0] }, time: timeline.date.timeIntervalSinceReferenceDate)
                        }
                    }
                }
            }
            handoverStrip
        }
    }

    // MARK: Columns

    private var topBar: some View {
        let runningCount = run.tasks.filter { $0.status == .running }.count
        return HStack(spacing: 14) {
            Text("\(executors.count) 执行者").font(.system(size: 12, weight: .medium))
            Text("\(run.tasks.count) 条分支").font(.system(size: 12, weight: .medium))
            if runningCount > 0 {
                HStack(spacing: 5) { Circle().fill(.green).frame(width: 6, height: 6); Text("\(runningCount) 个员工执行中") }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { paused.toggle() } label: {
                Label(paused ? "播放动效" : "暂停动效", systemImage: paused ? "play.fill" : "pause.fill").font(.system(size: 11))
            }.buttonStyle(.bordered).controlSize(.small).help("只停动画，不影响任务")
        }
        .padding(.horizontal, 24).padding(.top, 14)
    }

    private var executorColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            columnTitle("执行员工", count: executors.count)
            ForEach(groups, id: \.0) { group, roles in
                HStack { Text(group).font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Text("\(roles.count) 位").font(.system(size: 11)).foregroundStyle(.tertiary) }
                    .padding(.top, 4)
                ForEach(roles) { role in executorCard(role) }
            }
        }
    }

    private func executorCard(_ role: RelayRole) -> some View {
        let tasks = run.tasks.filter { $0.task.roleId == role.id }
        let running = tasks.contains { $0.status == .running } || (run.currentRoleID == role.id && run.status.isWorking)
        let failed = tasks.contains { $0.status == .failed }
        let done = !tasks.isEmpty && tasks.allSatisfy { $0.status == .succeeded }
        return HStack(alignment: .top, spacing: 10) {
            RelayAvatar(role: role, connection: connection(role), active: running, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(role.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    statePill(running: running, failed: failed, done: done)
                }
                Text("\(role.stage.label) · \(role.model.isEmpty ? (connection(role)?.kind.label ?? "") : role.model)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Label("\(tasks.count) 条分支", systemImage: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(RelayStyle.border))
        .overlay { if running { border(tint(role), radius: 12) } }
        .anchorPreference(key: RelayFlowPorts.self, value: .trailing) { ["exec:\(role.id)": $0] }
    }

    private var leadColumn: some View {
        let lead = role(leadID)
        return VStack(alignment: .leading, spacing: 10) {
            columnTitle("拆解与整合", count: nil).frame(maxWidth: .infinity, alignment: .center)
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    RelayAvatar(role: lead, connection: connection(lead), active: run.status == .planning, size: 46)
                    Text(lead?.name ?? "总调度").font(.system(size: 15, weight: .semibold))
                    Text(run.input.plannerID.isEmpty ? "直接执行 · 交付" : "拆解 · 分配 · 整合").font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.vertical, 16).frame(maxWidth: .infinity)
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    Text("当前会话").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(run.input.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                }.padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RelayStyle.sunken)
                ForEach(run.tasks) { item in branchRow(item) }
                if run.tasks.isEmpty {
                    Text(run.status == .planning ? "正在拆解…" : "还没有分支").font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    outPort("结构化结果", key: "out:checks")
                    outPort("交付输出", key: "out:delivery")
                }.padding(.horizontal, 14).padding(.vertical, 10)
            }
            .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(RelayStyle.border))
            .overlay { if run.status == .planning { border(tint(lead), radius: 14) } }
            Text("— 执行结果汇入，交付分流").font(.system(size: 11)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
        }
    }

    private func branchRow(_ item: RelayWorkItem) -> some View {
        let owner = role(item.task.roleId)
        return Button { openTask(item.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(tint(owner))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.task.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(owner?.name ?? item.task.roleId).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(item.status.label).font(.system(size: 10)).foregroundStyle(color(item.status))
            }
            .padding(.horizontal, 14).padding(.vertical, 8).contentShape(Rectangle())
            .background(item.status == .running ? tint(owner).opacity(0.08) : .clear)
        }
        .buttonStyle(.plain)
        .anchorPreference(key: RelayFlowPorts.self, value: .leading) { ["branch:\(item.id)": $0] }
    }

    private func outPort(_ title: String, key: String) -> some View {
        HStack { Text(title).font(.system(size: 11)).foregroundStyle(.secondary); Spacer() }
            .anchorPreference(key: RelayFlowPorts.self, value: .trailing) { [key: $0] }
    }

    private var resultColumn: some View {
        let changed = run.tasks.filter { $0.status == .succeeded }.count
        return VStack(alignment: .leading, spacing: 14) {
            columnTitle("结果去向", count: 2)
            resultCard(icon: "folder", title: "测试与复审", subtitle: "本机测试、质检与复审结论", key: "dest:checks",
                       rows: [("本机测试", run.testExitCode.map { $0 == 0 ? "通过" : "失败（\($0)）" } ?? (run.project.testCommand.isEmpty ? "未配置" : "尚未执行")),
                              ("质检", run.quality.map { $0.passed ? "通过" : "需返工" } ?? (run.input.testerID.isEmpty ? "未安排" : "尚未执行")),
                              ("复审", run.review.map { $0.passed ? "通过" : "需返工" } ?? (run.input.reviewerID.isEmpty ? "未安排" : "尚未执行"))],
                       footer: run.status == .testing || run.status == .reviewing ? "正在检查…" : run.status.isTerminal ? "检查结束" : "等待执行完成")
            resultCard(icon: "shippingbox", title: "交付输出", subtitle: "完成的分支与最终说明", key: "dest:delivery",
                       rows: [("完成分支", "\(changed)/\(run.tasks.count)"), ("最终说明", run.output.isEmpty ? "尚未生成" : String(run.output.prefix(24)) + "…")],
                       footer: run.status == .succeeded ? "已交付" : run.status.isTerminal ? run.status.label : "等待整合并交付")
        }
    }

    private func resultCard(icon: String, title: String, subtitle: String, key: String, rows: [(String, String)], footer: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            ForEach(rows, id: \.0) { row in
                HStack { Text(row.0).font(.system(size: 11)); Spacer(); Text(row.1).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Divider()
            Label(footer, systemImage: run.status.isTerminal ? "checkmark.circle" : "pause.circle").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(RelayStyle.border))
        .anchorPreference(key: RelayFlowPorts.self, value: .leading) { [key: $0] }
    }

    private var handoverStrip: some View {
        let latest = run.tasks.filter { $0.startedAt != nil || $0.endedAt != nil }.max { ($0.endedAt ?? $0.startedAt ?? .distantPast) < ($1.endedAt ?? $1.startedAt ?? .distantPast) }
        let lead = role(leadID)?.name ?? "总调度"
        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Circle().fill(RelayStyle.accent).frame(width: 6, height: 6)
                Text("材料交接").font(.system(size: 12, weight: .semibold))
            }.padding(.horizontal, 24).padding(.top, 6)
            if let latest {
                let owner = role(latest.task.roleId)?.name ?? latest.task.roleId
                let finished = latest.status == .succeeded || latest.status == .failed
                HStack(alignment: .top, spacing: 40) {
                    field("执行者", finished ? "\(owner) → \(lead)" : "\(lead) → \(owner)")
                    field("内容", (finished ? "交回 " : "派发 ") + "「\(latest.task.title)」")
                    field("状态", latest.status.label)
                }.padding(.horizontal, 24).padding(.bottom, 12)
            } else {
                Text("还没有交接").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 12)
            }
        }
    }
    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12)).lineLimit(1)
        }
    }

    private func columnTitle(_ title: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            if let count { Text("\(count)").font(.system(size: 11)).foregroundStyle(.tertiary) }
        }
    }
    private func statePill(running: Bool, failed: Bool, done: Bool) -> some View {
        let (text, color): (String, Color) = failed ? ("失败", .red) : running ? ("运行中", .green) : done ? ("完成", .secondary) : ("待命", .secondary)
        return HStack(spacing: 3) { Circle().fill(color).frame(width: 5, height: 5); Text(text) }
            .font(.system(size: 10)).foregroundStyle(color == .secondary ? .secondary : color)
    }
    private func color(_ status: RelayTaskStatus) -> Color {
        switch status { case .running: .green; case .failed: .red; case .succeeded: .secondary; case .paused: .orange; case .pending: .secondary }
    }

    // MARK: Links

    private func draw(_ context: inout GraphicsContext, ports: [String: CGPoint], time: TimeInterval) {
        for item in run.tasks {
            guard let a = ports["exec:\(item.task.roleId)"], let b = ports["branch:\(item.id)"] else { continue }
            link(&context, a, b, color: tint(role(item.task.roleId)), status: item.status, time: time, seed: Double(abs(item.id.hashValue % 1000)) / 1000)
        }
        let checksStatus: RelayTaskStatus = run.status == .testing || run.status == .reviewing ? .running : run.status.isTerminal ? .succeeded : .pending
        let deliveryStatus: RelayTaskStatus = run.status == .succeeded ? .succeeded : run.status == .failed ? .failed : run.status.isTerminal ? .succeeded : .pending
        for (from, to, status, seed) in [("out:checks", "dest:checks", checksStatus, 0.3), ("out:delivery", "dest:delivery", deliveryStatus, 0.7)] {
            guard let a = ports[from], let b = ports[to] else { continue }
            link(&context, CGPoint(x: a.x + 14, y: a.y), b, color: RelayStyle.accent, status: status, time: time, seed: seed)
        }
    }

    /// Lancer's running border (shared `RelayRunningBorder`); a still outline while motion is paused.
    @ViewBuilder private func border(_ color: Color, radius: CGFloat) -> some View {
        if animating { RelayRunningBorder(color: color, radius: radius).allowsHitTesting(false) }
        else { RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(color.opacity(0.55), lineWidth: 1.2) }
    }

    /// A canvas link: horizontal tangents between two ports (the research canvas's dotted curves).
    private func curve(_ a: CGPoint, _ b: CGPoint) -> RelayLightGeometry.Curve {
        let pull = max(40, abs(b.x - a.x) * 0.5)
        return .init(a: a, c1: CGPoint(x: a.x + pull, y: a.y), c2: CGPoint(x: b.x - pull, y: b.y), b: b)
    }

    private func link(_ context: inout GraphicsContext, _ a: CGPoint, _ b: CGPoint, color: Color, status: RelayTaskStatus, time: TimeInterval, seed: Double) {
        let line = curve(a, b)
        var path = Path(); path.move(to: a); path.addCurve(to: b, control1: line.c1, control2: line.c2)
        let tone: Color = status == .failed ? .red : color
        switch status {
        case .running:
            let phase = CGFloat(time * 18).truncatingRemainder(dividingBy: 8)
            context.stroke(path, with: .color(tone.opacity(0.85)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [4, 4], dashPhase: -phase))
            // A light travelling along the link, Lancer-style (head and glow), restarting every 2.4 s.
            if animating {
                let progress = ((time / 2.4) + seed).truncatingRemainder(dividingBy: 1)
                let point = line.point(RelayLightGeometry.smoothstep(CGFloat(progress)))
                context.fill(Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)), with: .color(tone.opacity(0.16)))
                context.fill(Path(ellipseIn: CGRect(x: point.x - 2.6, y: point.y - 2.6, width: 5.2, height: 5.2)), with: .color(tone))
            }
        case .succeeded:
            context.stroke(path, with: .color(tone.opacity(0.45)), lineWidth: 1.2)
        case .failed:
            context.stroke(path, with: .color(tone.opacity(0.8)), style: StrokeStyle(lineWidth: 1.3, dash: [2, 2]))
        case .pending, .paused:
            context.stroke(path, with: .color(tone.opacity(0.35)), style: StrokeStyle(lineWidth: 1.1, dash: [4, 4]))
        }
        for point in [a, b] {
            context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(tone.opacity(status == .pending ? 0.5 : 0.9)))
        }
    }
}

/// Port positions (card edges) collected from the columns, drawn as links behind them.
struct RelayFlowPorts: PreferenceKey {
    static let defaultValue: [String: Anchor<CGPoint>] = [:]
    static func reduce(value: inout [String: Anchor<CGPoint>], nextValue: () -> [String: Anchor<CGPoint>]) {
        value.merge(nextValue()) { $1 }
    }
}
