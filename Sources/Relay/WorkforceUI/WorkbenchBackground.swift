import SwiftUI
import RelayCore

/// UI04–UI07: Routines and workflows. The editor keeps a draft apart from the saved version; saving checks the
/// graph and adds a version, and a run always shows the version it started with. "保存", "立即运行", "暂停后续触发"
/// and "取消当前运行" are separate actions; saving never runs anything.
struct RelayWorkbenchBackground: View {
    @Bindable var model: RelayWorkbenchModel
    @State private var draft: RelayWorkflowDefinition?
    @State private var draftBase: (id: String?, version: Int?) = (nil, nil)
    @State private var selectedNode: String?
    @State private var runID: String?

    var body: some View {
        let _ = model.host.revision
        let workflows = model.host.workflows()
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("后台工作").font(.system(size: 15, weight: .semibold)); Spacer()
                    Menu { Button("Routine（定时一位员工）") { edit(nil, template: .routine) }; Button("多步骤工作流") { edit(nil, template: .flow) } } label: { Image(systemName: "plus.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("新建")
                }.padding(14)
                List(selection: Binding(get: { model.workflowID }, set: { id in model.workflowID = id; if let id { edit(workflows.first { $0.id == id }, template: nil) } })) {
                    ForEach(workflows) { flow in
                        let last = model.host.runs(flow.id).first
                        VStack(alignment: .leading, spacing: 2) {
                            Text(flow.definition.title).font(.system(size: 13, weight: .medium))
                            Text([flow.definition.nodes.contains { $0.kind == .agent } && flow.definition.nodes.filter(\.isStep).count <= 3 ? "Routine" : "工作流",
                                  trigger(flow.definition), last.map { "最近：\(label($0.state))" } ?? "未运行"].joined(separator: " · "))
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }.tag(flow.id).padding(.vertical, 3)
                    }
                }
                Text("后台模式未开启：关闭应用会停止后台工作，重开后按触发规则补跑最近一次。").font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
            }.frame(width: 260)
            Divider()
            if let draft { editor(draft) } else if let id = model.workflowID, let flow = workflows.first(where: { $0.id == id }) {
                // Opened from elsewhere (the inbox, a link): load that workflow's saved version as the draft.
                Color.clear.onAppear { edit(flow, template: nil) }
            } else {
                RelayEmpty(symbol: "point.3.connected.trianglepath.dotted", title: "选择或新建后台工作", detail: "Routine 每次在独立线程里运行，结果回到员工和这里；没有新结果时安静记一条成功记录。")
                    .frame(maxHeight: .infinity)
            }
        }
    }

    enum Template { case routine, flow }
    private func edit(_ flow: RelayLocalWorkflow?, template: Template?) {
        selectedNode = nil; runID = nil
        if let flow { draft = flow.definition; draftBase = (flow.id, flow.version); return }
        let employee = model.host.employees().first { $0.enabled }?.id ?? ""
        var definition = RelayWorkflowDefinition(title: template == .routine ? "新 Routine" : "新工作流", nodes: [
            .init(id: "trigger", kind: .trigger), .init(id: "step1", kind: .agent, fields: ["employeeId": employee, "task": "", "completion": "turn"]),
        ], edges: [.init(id: "e1", from: "trigger", to: "step1")])
        if template == .routine {
            var daily = RelayTrigger(id: "daily", kind: .cron); daily.cron = "0 9 * * 1-5"
            definition.triggers = [daily]
        } else {
            definition.nodes += [.init(id: "gate1", kind: .gate, fields: ["title": "阶段确认"]), .init(id: "out", kind: .output, fields: ["target": "notify"])]
            definition.edges += [.init(id: "e2", from: "step1", to: "gate1"), .init(id: "e3", from: "gate1", to: "out")]
            definition.advance = .manual
        }
        draft = definition; draftBase = (nil, nil); model.workflowID = nil
    }

    private func editor(_ definition: RelayWorkflowDefinition) -> some View {
        let binding = Binding(get: { draft ?? definition }, set: { draft = $0 })
        let problems = RelayWorkflowWalk.problems(binding.wrappedValue, employees: Set(model.host.employees().map(\.id)))
        let saved = draftBase.id.flatMap { id in model.host.workflows().first { $0.id == id } }
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("标题", text: binding.title).textFieldStyle(.plain).font(.system(size: 18, weight: .semibold))
                if let saved { RelayBadge(text: "v\(saved.version)\(saved.definition == binding.wrappedValue ? "" : " · 草稿已修改")", color: .secondary) }
                Spacer()
                Button("保存") {
                    if let stored = model.host.saveWorkflow(id: draftBase.id, definition: binding.wrappedValue, expectedVersion: draftBase.version) {
                        draftBase = (stored.id, stored.version); model.workflowID = stored.id
                    }
                }.disabled(!problems.isEmpty)
                Button("立即运行") { if let id = draftBase.id { model.host.runNow(id) } }
                    .buttonStyle(.borderedProminent).tint(RelayStyle.action).disabled(saved == nil)
            }.padding(.horizontal, 20).padding(.vertical, 12)
            if !problems.isEmpty {
                Text(problems.joined(separator: "；")).font(.system(size: 11)).foregroundStyle(RelayPalette.amber).padding(.horizontal, 20).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        RelayWorkflowCanvas(definition: binding.wrappedValue, run: runID.flatMap { id in model.host.runs().first { $0.id == id } }, selected: $selectedNode)
                            .frame(height: 260)
                        settings(binding)
                        runs(saved)
                    }.padding(20)
                }.frame(minWidth: 460)
                if let nodeID = selectedNode, let index = binding.wrappedValue.nodes.firstIndex(where: { $0.id == nodeID }) {
                    RelayWorkflowNodeInspector(model: model, definition: binding, index: index) { selectedNode = nil }.frame(minWidth: 280, maxWidth: 340)
                }
            }
        }
    }

    private func settings(_ definition: Binding<RelayWorkflowDefinition>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("节点").font(.system(size: 13, weight: .semibold)); Spacer()
                Menu("添加节点") {
                    ForEach(RelayWorkflowNode.Kind.allCases.filter { $0 != .trigger }, id: \.self) { kind in
                        Button(Self.kindLabel(kind)) {
                            let id = "\(kind.rawValue)\(definition.wrappedValue.nodes.count + 1)"
                            definition.wrappedValue.nodes.append(.init(id: id, kind: kind, fields: kind == .output ? ["target": "notify"] : kind == .condition ? ["op": "contains"] : kind == .wait ? ["seconds": "600"] : [:]))
                            if let last = definition.wrappedValue.nodes.dropLast().last(where: { $0.kind != .output && $0.kind != .note }) {
                                definition.wrappedValue.edges.append(.init(id: "e\(UUID().uuidString.prefix(6))", from: last.id, to: id, branch: last.kind == .condition ? "yes" : nil))
                            }
                            selectedNode = id
                        }
                    }
                }.fixedSize()
            }
            HStack(spacing: 16) {
                Stepper("每个循环最多 \(definition.wrappedValue.maxIterations) 轮", value: definition.maxIterations, in: 1...50)
                Stepper("最多派发 \(definition.wrappedValue.maxDispatches) 次", value: definition.maxDispatches, in: 1...64)
                Picker("阶段门", selection: definition.advance) { Text("自动推进").tag(RelayWorkflowDefinition.Advance.automatic); Text("人工确认").tag(RelayWorkflowDefinition.Advance.manual) }.fixedSize()
            }.font(.system(size: 12))
            Divider()
            HStack {
                Text("触发").font(.system(size: 13, weight: .semibold)); Spacer()
                Menu("添加触发") {
                    ForEach(RelayTrigger.Kind.allCases.filter { $0 != .manual }, id: \.self) { kind in
                        Button(Self.triggerLabel(kind)) {
                            var trigger = RelayTrigger(id: "\(kind.rawValue)\(definition.wrappedValue.triggers.count + 1)", kind: kind)
                            switch kind { case .cron: trigger.cron = "0 9 * * *"; case .interval: trigger.everySeconds = 3_600; case .once: trigger.at = Date().addingTimeInterval(3_600); case .message: trigger.match = "日报"; case .manual: break }
                            definition.wrappedValue.triggers.append(trigger)
                        }
                    }
                }.fixedSize()
            }
            ForEach(definition.triggers) { $trigger in RelayTriggerRow(trigger: $trigger) { definition.wrappedValue.triggers.removeAll { $0.id == trigger.id } } }
            if definition.wrappedValue.triggers.isEmpty { Text("只在“立即运行”时执行。").font(.system(size: 12)).foregroundStyle(.secondary) }
        }
    }

    private func runs(_ saved: RelayLocalWorkflow?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("运行记录").font(.system(size: 13, weight: .semibold))
            let runs = saved.map { model.host.runs($0.id) } ?? []
            if runs.isEmpty { Text("还没有运行。").font(.system(size: 12)).foregroundStyle(.secondary) }
            ForEach(runs.prefix(20)) { run in
                RelayCard(padding: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            RelayBadge(text: label(run.state), color: run.state == .completed ? RelayPalette.green : run.state == .failed ? .red : run.isOpen ? RelayStyle.accent : .secondary)
                            Text("v\(run.version) · \(run.startedAt.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Button(runID == run.id ? "收起" : "在图上看") { runID = runID == run.id ? nil : run.id }.buttonStyle(.link).font(.system(size: 11))
                            if run.isOpen { Button("取消当前运行") { model.host.cancelRun(run.id) }.buttonStyle(.link).font(.system(size: 11)) }
                        }
                        if let reason = run.reason { Text(reason).font(.system(size: 11)).foregroundStyle(.secondary) }
                        ForEach(run.steps.filter { $0.status == .approval || $0.status == .waiting && $0.reason?.hasPrefix("等到") != true }, id: \.sequence) { step in
                            RelayGatePanel(model: model, run: run, step: step)
                        }
                    }
                }
            }
        }
    }

    private func trigger(_ definition: RelayWorkflowDefinition) -> String {
        guard let first = definition.triggers.first(where: \.enabled) else { return "手动" }
        switch first.kind {
        case .cron: return "cron \(first.cron ?? "") \(first.timeZone)"
        case .interval: return "每 \((first.everySeconds ?? 0) / 60) 分钟"
        case .once: return first.at.map { "一次 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "一次"
        case .message: return "消息含“\(first.match ?? "")”"
        case .manual: return "手动"
        }
    }
    private func label(_ state: RelayLocalRun.State) -> String {
        switch state { case .running: "运行中"; case .waiting: "等你处理"; case .completed: "已完成"; case .failed: "失败"; case .cancelled: "已取消"; case .paused: "已暂停" }
    }
    static func kindLabel(_ kind: RelayWorkflowNode.Kind) -> String {
        switch kind {
        case .trigger: "触发"; case .prompt: "固定文字"; case .agent: "员工执行"; case .condition: "条件"; case .approval: "审批"
        case .gate: "阶段门"; case .wait: "等待"; case .output: "输出"; case .note: "备注"
        }
    }
    static func triggerLabel(_ kind: RelayTrigger.Kind) -> String {
        switch kind { case .manual: "手动"; case .cron: "定时（cron）"; case .interval: "固定间隔"; case .once: "一次性"; case .message: "群消息匹配" }
    }
}

/// A read-only map of the graph (and of one run's node states): the OpenBot canvas laid out natively by depth.
struct RelayWorkflowCanvas: View {
    var definition: RelayWorkflowDefinition
    var run: RelayLocalRun?
    @Binding var selected: String?
    var body: some View {
        let depth = layout()
        let columns = Dictionary(grouping: definition.nodes, by: { depth[$0.id] ?? 0 })
        GeometryReader { geometry in
            let width = max(140, geometry.size.width / CGFloat(max(1, columns.count)))
            let position: (String) -> CGPoint = { id in
                let column = depth[id] ?? 0, rows = columns[column] ?? []
                let row = rows.firstIndex { $0.id == id } ?? 0
                return CGPoint(x: width * (CGFloat(column) + 0.5), y: geometry.size.height / CGFloat(rows.count + 1) * CGFloat(row + 1))
            }
            ZStack {
                Canvas { context, _ in
                    for edge in definition.edges {
                        var path = Path(); path.move(to: position(edge.from)); path.addLine(to: position(edge.to))
                        context.stroke(path, with: .color(edge.branch == "no" ? RelayPalette.amber.opacity(0.6) : Color.secondary.opacity(0.45)), lineWidth: 1.5)
                    }
                }
                ForEach(definition.nodes) { node in
                    let step = run?.steps.last { $0.nodeID == node.id }
                    Button { selected = node.id } label: {
                        VStack(spacing: 2) {
                            Text(RelayWorkbenchBackground.kindLabel(node.kind)).font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(node.fields["title"] ?? (node.kind == .agent ? node.fields["task"].map { String($0.prefix(14)) } : nil) ?? node.id).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            if let step { Text(step.status.rawValue + (step.iteration > 1 ? " ×\(step.iteration)" : "")).font(.system(size: 9)).foregroundStyle(color(step.status)) }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6).frame(width: min(width - 16, 150))
                        .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected == node.id ? RelayStyle.action : step.map { color($0.status) } ?? RelayStyle.border, lineWidth: selected == node.id ? 2 : 1))
                    }.buttonStyle(.plain).position(position(node.id)).accessibilityLabel("\(RelayWorkbenchBackground.kindLabel(node.kind)) \(node.id)")
                }
            }
        }
        .background(RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 12))
    }
    private func layout() -> [String: Int] {
        let loops = RelayWorkflowWalk.loopEdges(definition.nodes, definition.edges)
        var depth: [String: Int] = [:]
        for _ in definition.nodes {
            for edge in definition.edges where !loops.contains(edge.id) { depth[edge.to] = max(depth[edge.to] ?? 0, (depth[edge.from] ?? 0) + 1) }
        }
        return depth
    }
    private func color(_ status: RelayNodeAttempt.Status) -> Color {
        switch status { case .done: RelayPalette.green; case .failed: .red; case .running: RelayStyle.accent; case .approval, .waiting: RelayPalette.amber; default: .secondary }
    }
}

/// Properties of one node; edges are edited as "next steps" so the graph can be built with the keyboard.
struct RelayWorkflowNodeInspector: View {
    @Bindable var model: RelayWorkbenchModel
    @Binding var definition: RelayWorkflowDefinition
    var index: Int
    var close: () -> Void
    var body: some View {
        let node = $definition.nodes[index]
        Form {
            Section(RelayWorkbenchBackground.kindLabel(node.wrappedValue.kind) + " · " + node.wrappedValue.id) {
                TextField("名称", text: field(node, "title"))
                switch node.wrappedValue.kind {
                case .agent:
                    Picker("员工", selection: field(node, "employeeId")) { ForEach(model.host.employees()) { Text($0.name).tag($0.id) } }
                    TextField("这一步做什么", text: field(node, "task"), axis: .vertical).lineLimit(3...8)
                    Picker("完成方式", selection: field(node, "completion")) {
                        Text(RelayCompletionPolicy.turn.label).tag("turn"); Text(RelayCompletionPolicy.receipt.label).tag("receipt")
                    }
                case .condition:
                    Picker("比较", selection: field(node, "op")) {
                        Text("包含").tag("contains"); Text("不包含").tag("not_contains"); Text("等于").tag("equals"); Text("不等于").tag("not_equals"); Text("为空").tag("empty"); Text("不为空").tag("not_empty")
                    }
                    TextField("文字", text: field(node, "value"))
                case .prompt: TextField("文字", text: field(node, "text"), axis: .vertical)
                case .wait: TextField("等待秒数", text: field(node, "seconds"))
                case .output:
                    Picker("输出到", selection: field(node, "target")) { Text("通知").tag("notify"); Text("群聊").tag("channel") }
                    if node.wrappedValue.fields["target"] == "channel" {
                        Picker("群", selection: field(node, "channelId")) { ForEach(model.host.channels()) { Text($0.name).tag($0.id) } }
                    }
                case .approval, .gate: Text(node.wrappedValue.kind == .approval ? "审批总要等人确认；确认时可改写交给下一步的内容。" : "阶段门在“人工确认”时等你推进，“自动推进”时直接通过。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                default: EmptyView()
                }
            }
            Section("下一步") {
                ForEach(definition.edges.filter { $0.from == node.wrappedValue.id }) { edge in
                    HStack {
                        Text((edge.branch.map { $0 == "yes" ? "是 → " : "否 → " } ?? "→ ") + edge.to)
                        Spacer()
                        Button("删除") { definition.edges.removeAll { $0.id == edge.id } }.buttonStyle(.link)
                    }
                }
                Menu("连到…") {
                    ForEach(definition.nodes.filter { $0.id != node.wrappedValue.id && $0.kind != .trigger }) { target in
                        if node.wrappedValue.kind == .condition {
                            Button("是 → \(target.id)") { connect(node.wrappedValue.id, target.id, "yes") }
                            Button("否 → \(target.id)") { connect(node.wrappedValue.id, target.id, "no") }
                        } else { Button(target.id) { connect(node.wrappedValue.id, target.id, nil) } }
                    }
                }
            }
            if node.wrappedValue.kind != .trigger {
                Button("删除节点", role: .destructive) {
                    let id = node.wrappedValue.id
                    close(); definition.edges.removeAll { $0.from == id || $0.to == id }; definition.nodes.removeAll { $0.id == id }
                }
            }
        }.formStyle(.grouped)
    }
    private func field(_ node: Binding<RelayWorkflowNode>, _ name: String) -> Binding<String> {
        Binding(get: { node.wrappedValue.fields[name] ?? "" }, set: { node.wrappedValue.fields[name] = $0.isEmpty ? nil : $0 })
    }
    private func connect(_ from: String, _ to: String, _ branch: String?) {
        definition.edges.append(.init(id: "e\(UUID().uuidString.prefix(6))", from: from, to: to, branch: branch))
    }
}

struct RelayTriggerRow: View {
    @Binding var trigger: RelayTrigger
    var remove: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $trigger.enabled).labelsHidden().help("关闭只暂停后续触发，不取消已在运行的")
            Text(RelayWorkbenchBackground.triggerLabel(trigger.kind)).font(.system(size: 12, weight: .medium)).frame(width: 90, alignment: .leading)
            switch trigger.kind {
            case .cron:
                TextField("分 时 日 月 周", text: Binding(get: { trigger.cron ?? "" }, set: { trigger.cron = $0 })).relayField().frame(width: 140)
                TextField("时区", text: $trigger.timeZone).relayField().frame(width: 130)
                if let cron = RelayCron(trigger.cron ?? ""), let zone = TimeZone(identifier: trigger.timeZone), let next = cron.next(after: Date(), timeZone: zone) {
                    Text("下次 \(next.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            case .interval:
                Stepper("每 \((trigger.everySeconds ?? 3_600) / 60) 分钟", value: Binding(get: { (trigger.everySeconds ?? 3_600) / 60 }, set: { trigger.everySeconds = $0 * 60 }), in: 1...44_640)
            case .once: DatePicker("", selection: Binding(get: { trigger.at ?? Date() }, set: { trigger.at = $0 })).labelsHidden()
            case .message: TextField("消息包含", text: Binding(get: { trigger.match ?? "" }, set: { trigger.match = $0 })).relayField().frame(width: 160)
            case .manual: EmptyView()
            }
            Picker("", selection: $trigger.overlap) { Text("上次未完就跳过").tag(RelayTrigger.Overlap.skip); Text("只排下一次").tag(RelayTrigger.Overlap.queueOne); Text("最多并行 2 个").tag(RelayTrigger.Overlap.parallel) }
                .labelsHidden().fixedSize()
            Spacer()
            Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless).accessibilityLabel("删除触发")
        }.font(.system(size: 12))
    }
}

/// UI07: a stage gate or approval waiting for the person. The draft of the next stage's goal is editable; closing
/// the panel or refreshing never counts as confirming.
struct RelayGatePanel: View {
    @Bindable var model: RelayWorkbenchModel
    var run: RelayLocalRun
    var step: RelayNodeAttempt
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(step.status == .approval ? "审批：确认这一步的内容" : "阶段门：确认后进入下一阶段").font(.system(size: 12, weight: .semibold))
            Text("上一阶段交付").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(step.output ?? "（无）").font(.system(size: 12)).lineLimit(8).textSelection(.enabled)
            TextField("下一阶段目标（可改写，不填则原样交给下一步）", text: $text, axis: .vertical).lineLimit(2...6).relayField()
            HStack {
                Spacer()
                Button("拒绝") { model.host.decideGate(run.id, nodeID: step.nodeID, approve: false, text: text.isEmpty ? nil : text) }
                Button("确认并继续") { model.host.decideGate(run.id, nodeID: step.nodeID, approve: true, text: text.isEmpty ? nil : text) }
                    .buttonStyle(.borderedProminent).tint(RelayStyle.action)
            }
        }.padding(12).background(RelayPalette.amber.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}
