import SwiftUI
import RelayCore

/// UI03: everything that waits for the person, across employees, channels and background work. Each card names
/// its object and the exact action; the host confirms the result, so a second window's click shows the real state.
struct RelayWorkbenchInbox: View {
    @Bindable var model: RelayWorkbenchModel
    enum Item: Identifiable {
        case receipt(RelayDeliveryReceipt), gate(RelayLocalRun, RelayNodeAttempt), handoff(RelayHandoffRecord), unconfirmed(RelayWorkAssignment), paused(RelayLocalRun)
        var id: String {
            switch self {
            case .receipt(let r): "r-\(r.id)"; case .gate(let run, let step): "g-\(run.id)-\(step.sequence)"; case .handoff(let h): "h-\(h.id)"
            case .unconfirmed(let a): "u-\(a.id)"; case .paused(let run): "p-\(run.id)"
            }
        }
    }
    @MainActor static func pending(_ host: RelayWorkforceHost) -> Int { _ = host.revision; return items(host).count }
    @MainActor static func items(_ host: RelayWorkforceHost) -> [Item] {
        var items: [Item] = host.receipts().filter { $0.state == .submitted }.map(Item.receipt)
        for run in host.runs() {
            for step in run.steps where step.status == .approval || (step.status == .waiting && step.reason?.hasPrefix("等到") != true) {
                items.append(.gate(run, step))
            }
            if run.state == .paused { items.append(.paused(run)) }
        }
        items += host.handoffs().filter { $0.state == .pending }.map(Item.handoff)
        items += host.allAssignments().filter { $0.callState == .unconfirmed }.map(Item.unconfirmed)
        return items
    }
    var body: some View {
        let _ = model.host.revision
        let items = Self.items(model.host)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("需要你接收、确认或核实的事项；普通进度不在这里打扰你。").font(.system(size: 12)).foregroundStyle(.secondary)
                if items.isEmpty { RelayEmpty(symbol: "tray", title: "没有待处理的事", detail: "回执、审批、阶段门、移交和未确认的调用会出现在这里。") }
                ForEach(items) { item in card(item) }
            }.padding(24)
        }
    }
    @ViewBuilder private func card(_ item: Item) -> some View {
        switch item {
        case .receipt(let receipt):
            RelayCard(padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { RelayBadge(text: "回执待接收", color: RelayPalette.amber); Text(model.host.name(receipt.authorID)).font(.system(size: 12, weight: .medium)); Spacer() }
                    Text(receipt.summary).font(.system(size: 13))
                    HStack {
                        Button("查看完整报告") { model.open(receipt: receipt.id) }.buttonStyle(.link)
                        Spacer()
                        Button("退回") { model.host.decideReceipt(receipt.id, accept: false, note: "请改进后重新提交") }
                        Button("接收交付") { model.host.decideReceipt(receipt.id, accept: true) }.buttonStyle(.borderedProminent).tint(RelayStyle.action)
                    }
                    Text("接收只表示交付已收下，不会提交、合并或推送代码。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        case .gate(let run, let step):
            let title = model.host.workflows().first { $0.id == run.workflowID }?.definition.title ?? run.workflowID
            RelayCard(padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { RelayBadge(text: step.status == .approval ? "审批" : "阶段门", color: RelayPalette.violet); Text("\(title) · v\(run.version)").font(.system(size: 12, weight: .medium)) }
                    RelayGatePanel(model: model, run: run, step: step)
                }
            }
        case .handoff(let handoff):
            RelayCard(padding: 14) {
                HStack {
                    Text("\(model.host.name(handoff.fromID)) → \(model.host.name(handoff.toID))：\(handoff.note)").font(.system(size: 13))
                    Spacer()
                    Button("拒绝") { model.host.decideHandoff(handoff.id, accept: false) }
                    Button("接手") { model.host.decideHandoff(handoff.id, accept: true) }.buttonStyle(.borderedProminent).tint(RelayStyle.action)
                }
            }
        case .unconfirmed(let assignment):
            RelayCard(padding: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { RelayBadge(text: "调用未确认", color: RelayPalette.amber); Text(model.host.name(assignment.ownerID)).font(.system(size: 12, weight: .medium)) }
                    Text(assignment.instruction).font(.system(size: 13)).lineLimit(2)
                    Text("应用退出时这次调用还在进行，无法确认是否完成。不会自动重试；请在原客户端确认后再继续或移交。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        case .paused(let run):
            RelayCard(padding: 14) {
                HStack {
                    RelayBadge(text: "已暂停", color: .secondary)
                    Text(run.reason ?? "").font(.system(size: 12))
                    Spacer()
                    Button("打开") { model.open(workflow: run.workflowID) }.buttonStyle(.link)
                }
            }
        }
    }
}

/// UI08–UI11: deliveries. Report and summary are labelled apart; files preview with Quick Look; the Diff scopes
/// are the five of E §9.2 and a turn's diff comes only from its own snapshot.
struct RelayWorkbenchDelivery: View {
    @Bindable var model: RelayWorkbenchModel
    @State private var scope = RelayCheckpointStore.Scope.lastTurn
    @State private var patch: Result<String, Error>?
    @State private var previewPath: String?
    @State private var reviewed: Set<String> = []
    /// Requests are tagged; a late answer for an older selection never replaces the current one (FE §7.3).
    @State private var generation = 0

    var body: some View {
        let _ = model.host.revision
        let receipts = model.host.receipts().sorted { $0.createdAt > $1.createdAt }
        let selected = receipts.first { $0.id == (model.receiptID ?? receipts.first?.id) }
        HStack(spacing: 0) {
            List(selection: Binding(get: { selected?.id }, set: { model.receiptID = $0; patch = nil })) {
                ForEach(receipts) { receipt in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(receipt.summary).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        Text("\(model.host.name(receipt.authorID)) · \(label(receipt.state))").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.tag(receipt.id).padding(.vertical, 3)
                }
            }.frame(width: 260)
            Divider()
            if let selected { detail(selected) } else {
                RelayEmpty(symbol: "shippingbox", title: "还没有交付", detail: "群聊里的请求完成后，员工的回执、文件和本轮改动都在这里。").frame(maxHeight: .infinity)
            }
        }
    }

    private func detail(_ receipt: RelayDeliveryReceipt) -> some View {
        let assignment = model.host.allAssignments().first { $0.id == receipt.assignmentID }
        let checkpoint = (receipt.checkpointIDs.last ?? assignment?.checkpointIDs.last).flatMap(model.host.checkpoint)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(receipt.summary).font(.system(size: 18, weight: .semibold)).lineLimit(3)
                    Spacer()
                    if receipt.state == .submitted {
                        Button("退回") { model.host.decideReceipt(receipt.id, accept: false, note: "请改进后重新提交") }
                        Button("接收交付") { model.host.decideReceipt(receipt.id, accept: true) }.buttonStyle(.borderedProminent).tint(RelayStyle.action)
                    }
                }
                if let assignment { RelayResultBadges(result: assignment.result) }
                HStack(spacing: 14) {
                    Text("作者 \(model.host.name(receipt.authorID))"); Text("负责人第 \(receipt.ownerRevision) 任"); Text("报告 sha256 \(receipt.reportSHA256.prefix(12))")
                    if let old = receipt.supersedes { Text("替代 \(old)") }
                    if let channelID = assignment?.channelID { Button("回到群聊") { model.open(channel: channelID) }.buttonStyle(.link) }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                RelayCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("完整报告").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Text(model.host.report(receipt)).font(.system(size: 13)).textSelection(.enabled)
                    }
                }
                if !receipt.items.isEmpty {
                    Text("文件").font(.system(size: 13, weight: .semibold))
                    ForEach(receipt.items, id: \.artifactID) { item in
                        HStack {
                            Text(item.path).font(.system(size: 12, weight: .medium))
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)) · \(item.sha256.prefix(10))").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Button(previewPath == item.storageRef ? "收起" : "预览") { previewPath = previewPath == item.storageRef ? nil : item.storageRef }.buttonStyle(.link)
                        }
                        if previewPath == item.storageRef {
                            if FileManager.default.fileExists(atPath: item.storageRef) { RelayQuickLook(url: URL(fileURLWithPath: item.storageRef)).frame(height: 360) }
                            else { Text("文件已不在原位置，不读取同名的其他文件代替。").font(.system(size: 12)).foregroundStyle(.red) }
                        }
                    }
                }
                changes(checkpoint)
            }.padding(24)
        }
    }

    private func changes(_ checkpoint: RelayTurnCheckpoint?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("改动").font(.system(size: 13, weight: .semibold))
                Picker("", selection: $scope) { ForEach(RelayCheckpointStore.Scope.allCases, id: \.self) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 340)
                Spacer()
                Button("刷新") { load(checkpoint) }
            }
            if let checkpoint {
                Text("第 \(checkpoint.turn) 轮 · \(checkpoint.workspacePath) · 快照\(stateLabel(checkpoint.state)) · 来源 \(checkpoint.source)\(checkpoint.exclusions.isEmpty ? "" : " · 排除 \(checkpoint.exclusions.count) 项")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            switch patch {
            case .none: Text("选择范围后点“刷新”。“本轮”只来自这一轮的快照，其余范围读当前工作区。").font(.system(size: 12)).foregroundStyle(.secondary)
            case .failure(let error): Text(error.localizedDescription).font(.system(size: 12)).foregroundStyle(RelayPalette.amber)
            case .success(let text):
                let files = RelayCheckpointStore.files(of: text)
                if files.isEmpty { Text("没有改动。").font(.system(size: 12)).foregroundStyle(.secondary) }
                ForEach(files, id: \.path) { file in
                    HStack {
                        Toggle("", isOn: Binding(get: { reviewed.contains(file.path + text.count.description) }, set: { on in
                            // A reviewed mark belongs to this exact patch; new content clears it.
                            let key = file.path + text.count.description
                            if on { reviewed.insert(key) } else { reviewed.remove(key) }
                        })).labelsHidden().help("已查看")
                        Text(file.path).font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Text(file.added < 0 ? "二进制" : "+\(file.added) −\(file.removed)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                ScrollView(.horizontal) {
                    Text(text.prefix(200_000)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(12)
                }.background(RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 10))
                if text.count > 200_000 { Text("差异较长，只显示前 200k 字符。").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }.onChange(of: scope) { load(checkpoint) }.task(id: checkpoint?.id) { load(checkpoint) }
    }

    private func load(_ checkpoint: RelayTurnCheckpoint?) {
        generation += 1
        let mine = generation, scope = scope, store = model.host.checkpoints
        let workspace = checkpoint?.workspacePath ?? model.host.project(for: nil)?.path ?? ""
        Task.detached(priority: .userInitiated) {
            let result = Result { try store.diff(scope, workspace: workspace, checkpoint: checkpoint) }
            await MainActor.run { if mine == generation { patch = result } }
        }
    }
    private func label(_ state: RelayDeliveryReceipt.State) -> String {
        switch state { case .submitted: "待接收"; case .accepted: "已接收"; case .rejected: "已退回"; case .superseded: "已替代" }
    }
    private func stateLabel(_ state: RelayTurnCheckpoint.State) -> String {
        switch state { case .open: "捕获中"; case .finalized: "完整"; case .interrupted: "中断"; case .unavailable: "不可用" }
    }
}
