import SwiftUI
import RelayCore

/// 流程模块: 小红书 / Boss 直聘 business flows. Install with the employee who does the steps (it becomes a 后台工作),
/// run with this time's input, confirm when it stops for you, then finish on the platform yourself.
struct RelayFlowModulesView: View {
    @Bindable var model: RelayAppModel
    var cards: Bool
    private var host: RelayAutomationHost { model.automations }
    private var employees: [RelayRole] { (model.workforce?.employees() ?? []).filter { $0.enabled && Self.canWrite($0, model) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.workforce == nil { Text(model.workforceError ?? "协作数据没有打开。").foregroundStyle(.orange) }
            ForEach(Array(Dictionary(grouping: RelayFlowCatalog.builtIn, by: \.platform).sorted { $0.key > $1.key }), id: \.key) { platform, flows in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle().fill(RelayPalette.client(platform)).frame(width: 8, height: 8)
                        Text(platform).font(.system(size: 13, weight: .semibold))
                        Text("\(flows.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if cards {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10, alignment: .top)], spacing: 10) {
                            ForEach(flows) { tile($0) }
                        }
                    } else {
                        ForEach(flows) { row($0) }
                    }
                }
            }
            Text("合规：流程不登录平台、不自动发布、不代发消息、不批量操作。员工产出可以直接用的内容，最后一步由你在小红书、Boss 直聘的官方 App 或网页里完成。")
                .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// App-driven and chat-only employees cannot be relied on for multi-step writing; everyone else can.
    static func canWrite(_ role: RelayRole, _ model: RelayAppModel) -> Bool {
        model.store.state.connections.first { $0.id == role.connectionID } != nil
    }

    private func row(_ flow: RelayFlowModule) -> some View {
        let install = host.flowInstall(of: flow.id)
        return RelayCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    RelayIconTile(icon: "flow-arrow")
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(flow.name).font(.system(size: 15, weight: .semibold))
                            RelayBadge(text: flow.platform, color: .secondary)
                            if install != nil { RelayBadge(text: "已安装", color: .green) }
                        }
                        Text(flow.summary).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    actions(flow, install)
                }
                steps(flow)
                if let install { employeePicker(flow, install) }
                lastRun(flow, install)
            }
        }
    }

    private func tile(_ flow: RelayFlowModule) -> some View {
        let install = host.flowInstall(of: flow.id)
        let tint = RelayPalette.client(flow.platform)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DravionIcon(name: "flow-arrow", size: 13).foregroundStyle(tint)
                Text(flow.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Spacer()
                Text("\(flow.steps.count) 步").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(flow.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if let install { Text("由 \(model.workforce?.name(install.employeeID) ?? install.employeeID) 执行").foregroundStyle(.secondary) }
                else { Text("未安装").foregroundStyle(.tertiary) }
                Spacer()
                actions(flow, install, compact: true)
            }.font(.system(size: 10.5))
        }
        .padding(11).frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(install == nil ? Color.primary.opacity(0.03) : tint.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(install == nil ? RelayStyle.border : tint.opacity(0.18)))
        .help(flow.steps.enumerated().map { "\($0.offset + 1). \($0.element.title)" }.joined(separator: "\n"))
    }

    @ViewBuilder private func actions(_ flow: RelayFlowModule, _ install: RelayFlowInstall?, compact: Bool = false) -> some View {
        if install == nil {
            Button("安装") { installFlow(flow) }
                .buttonStyle(compact ? AnyButtonStyle(.borderless) : AnyButtonStyle(.prominent)).tint(RelayStyle.action)
                .disabled(employees.isEmpty).help(employees.isEmpty ? "先在“员工”里添加一位员工" : "生成一条后台工作，由默认总调度执行；装好后可换人")
        } else {
            Button(compact ? "运行" : "运行…") { run(flow) }
                .buttonStyle(compact ? AnyButtonStyle(.borderless) : AnyButtonStyle(.prominent)).tint(RelayStyle.action)
            Menu {
                Button("在后台工作里查看") { model.openWorkbench(.background) }
                Button("打开\(flow.platform)") { if let url = URL(string: flow.finishURL) { NSWorkspace.shared.open(url) } }
                Divider()
                Button("卸载", role: .destructive) { if let workforce = model.workforce { host.uninstallFlow(flow.id, workforce: workforce) } }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).frame(width: 22)
        }
    }

    private func steps(_ flow: RelayFlowModule) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(flow.steps.enumerated()), id: \.offset) { index, step in
                if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary) }
                HStack(spacing: 4) {
                    Image(systemName: step.kind == .confirm ? "hand.raised" : "person.crop.circle").font(.system(size: 9))
                    Text(step.title).lineLimit(1)
                }
                .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 4)
                .background(step.kind == .confirm ? Color.orange.opacity(0.1) : RelayStyle.sunken, in: Capsule())
            }
            Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary)
            Text("你在\(flow.platform)完成").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func employeePicker(_ flow: RelayFlowModule, _ install: RelayFlowInstall) -> some View {
        HStack {
            Text("执行员工").font(.system(size: 12)).frame(width: 80, alignment: .leading)
            Picker("", selection: Binding(get: { install.employeeID }, set: { id in
                guard let workforce = model.workforce else { return }
                model.perform { try host.installFlow(flow, employeeID: id, workforce: workforce) }
            })) { ForEach(employees) { Text($0.name).tag($0.id) } }.labelsHidden().fixedSize()
            Spacer()
        }
    }

    @ViewBuilder private func lastRun(_ flow: RelayFlowModule, _ install: RelayFlowInstall?) -> some View {
        if let install, let run = model.workforce?.runs(install.workflowID).first {
            Button { model.openWorkbench(.background) } label: {
                HStack(spacing: 6) {
                    Circle().fill(run.isOpen ? Color.orange : .green).frame(width: 7, height: 7)
                    Text("最近一次：\(run.isOpen ? (run.steps.contains { $0.status == .approval } ? "等你确认" : "进行中") : "已结束") · \(run.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    Text("在后台工作里查看").foregroundStyle(.tertiary)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }
    }

    private func installFlow(_ flow: RelayFlowModule) {
        guard let workforce = model.workforce else { return }
        let lead = employees.first { $0.id == model.store.state.routing.coordinatorID } ?? employees.first
        guard let lead else { return }
        model.perform { try host.installFlow(flow, employeeID: lead.id, workforce: workforce) }
    }

    private func run(_ flow: RelayFlowModule) {
        model.present("flow-run-\(flow.id)", width: 600) { RelayFlowRunPanel(model: model, flow: flow) }
    }
}

/// This time's input for a flow, then off it goes to 后台工作.
struct RelayFlowRunPanel: View {
    let model: RelayAppModel
    let flow: RelayFlowModule
    @State private var input = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RelaySheetHeader(title: "运行 · \(flow.platform) · \(flow.name)", close: { model.dismissOverlay() })
            VStack(alignment: .leading, spacing: 12) {
                Text("需要：\(flow.inputHint)").font(.system(size: 12)).foregroundStyle(.secondary)
                TextEditor(text: $input).font(.system(size: 13)).frame(minHeight: 160).padding(6)
                    .background(RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 8))
                Text("员工会按步骤处理，走到“你来确认”时会弹出确认卡片；结果在后台工作和收件箱里。").font(.system(size: 11)).foregroundStyle(.tertiary)
                if let error { Text(error).foregroundStyle(.orange).font(.system(size: 12)) }
                HStack {
                    Spacer()
                    Button("取消") { model.dismissOverlay() }
                    Button("开始") {
                        guard let workforce = model.workforce else { return }
                        do {
                            try model.automations.runFlow(flow.id, input: input, workforce: workforce)
                            model.dismissOverlay(); model.openWorkbench(.background)
                        } catch { self.error = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).tint(RelayStyle.action)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(20)
        }
    }
}

/// Lets one call site switch between two button styles.
struct AnyButtonStyle: PrimitiveButtonStyle {
    enum Kind { case borderless, prominent }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    func makeBody(configuration: Configuration) -> some View {
        switch kind {
        case .borderless: Button(configuration).buttonStyle(.borderless)
        case .prominent: Button(configuration).buttonStyle(.borderedProminent)
        }
    }
}

/// 业务模块 (sidebar, below 自动化; user request 2026-11-02): business flows on their own page — 小红书, Boss 直聘,
/// and whatever business comes next — as a list or as cards.
struct RelayBusinessView: View {
    @Bindable var model: RelayAppModel
    @AppStorage("business.layout") private var layout = "list"
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                RelayPageTitle(title: "业务模块", subtitle: "做业务的现成流程：员工按步骤调研、撰写、整理，关键处停下等你确认；最后由你在平台官方 App 或网页里发布、发送。")
                Spacer()
            }
            HStack {
                Text("已安装 \(model.automations.flowInstalls.count) / \(RelayFlowCatalog.builtIn.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $layout) { Label("列表", systemImage: "list.bullet").tag("list"); Label("卡片", systemImage: "square.grid.2x2").tag("cards") }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            RelayFlowModulesView(model: model, cards: layout == "cards")
        }
        .id(model.automations.flowRevision)
    }
}
