import SwiftUI
import RelayCore

struct RelayConnectionsView: View {
    @Bindable var model: RelayAppModel
    @State private var tab = 0
    @State private var editing: RelayConnection?
    @State private var probing: Set<String> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                RelayPageTitle(title: "连接器与常驻会话", subtitle: "配置客户端如何接单，查看每个席位属于哪个项目。")
                if !model.store.state.connections.contains(where: { $0.kind == .doubaoApp }),
                   NSWorkspace.shared.urlForApplication(withBundleIdentifier: RelayDoubaoApp.bundleID) != nil {
                    Button("添加豆包 App") { editing = .init(name: "豆包", kind: .doubaoApp) }.buttonStyle(.bordered)
                        .help("检测到本机装了豆包 App，可以直接接入")
                }
                Button("添加连接", systemImage: "plus") { editing = .init(name: "", kind: .api) }.buttonStyle(.bordered)
            }
            Picker("查看", selection: $tab) {
                Text("连接器").tag(0)
                Text("常驻会话 · \(model.store.state.sessionList.count)").tag(1)
            }.pickerStyle(.segmented).frame(maxWidth: 340).accessibilityIdentifier("connector-tabs")
            if tab == 0 {
                ForEach(model.store.state.connections) { connection in connectionCard(connection) }
            } else { RelayManagedSessionsView(model: model) }
        }.sheet(item: $editing) { RelayConnectionEditor(model: model, connection: $0) }
        // Fill empty model directories once, quietly: reading names from local files never calls a model.
        .task {
            guard !model.isUITest else { return }
            for connection in model.store.state.connections where connection.models.isEmpty && connection.kind != .api {
                guard let catalog = try? await model.catalog(connection), !catalog.ids.isEmpty,
                      var current = model.store.state.connections.first(where: { $0.id == connection.id }), current.models.isEmpty else { continue }
                current.models = catalog.ids
                try? model.store.saveConnection(current)
            }
        }
    }
    @State private var reading: Set<String> = []
    @State private var binding: Set<String> = []
    private func doubaoBinding(_ connection: RelayConnection) -> some View {
        HStack(spacing: 8) {
            Text("绑定的对话").foregroundStyle(.secondary)
            Text(connection.appConversationTitle ?? "未绑定").font(.system(size: 12, weight: .medium))
                .foregroundStyle(connection.appConversationID == nil ? .orange : .primary)
            Spacer()
            if connection.probeOK == false, connection.probeMessage?.contains("辅助功能") == true {
                Button("打开辅助功能设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }.controlSize(.small)
            }
            Button(binding.contains(connection.id) ? "读取中…" : (connection.appConversationID == nil ? "绑定豆包当前对话" : "改绑为豆包当前对话")) {
                binding.insert(connection.id)
                Task { await model.bindDoubao(connection); binding.remove(connection.id) }
            }.controlSize(.small).disabled(binding.contains(connection.id) || model.isUITest)
            .help("先在豆包里打开要用的对话，再点这里。只读取对话编号和标题，不发送消息。")
        }.font(.system(size: 11))
    }
    private func connectionCard(_ connection: RelayConnection) -> some View {
        RelayCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    RelayIconTile(icon: "cpu")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(connection.name).font(.system(size: 15, weight: .semibold))
                        Text(connection.kind == .api ? "API · OpenCode 执行器" : connection.kind == .doubaoApp ? "App 直连 · 辅助功能" : connection.connectorTransport.label)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    RelayBadge(text: connection.probeOK == true ? "已检测" : connection.probeOK == false ? "检测失败" : "尚未检测",
                        color: connection.probeOK == false ? .orange : .secondary)
                    Button(probing.contains(connection.id) ? "检测中…" : "检测连接") {
                        probing.insert(connection.id)
                        Task { await model.probe(connection); probing.remove(connection.id) }
                    }.disabled(probing.contains(connection.id)).accessibilityIdentifier("probe-\(connection.id)")
                    // A split button: the main action, then the Element Plus arrow for the rest.
                    HStack(spacing: 0) {
                        Button("配置") { editing = connection }.buttonStyle(.plain)
                            .padding(.leading, 12).padding(.trailing, 10).frame(height: 26).contentShape(Rectangle())
                        Rectangle().fill(RelayStyle.border).frame(width: 1, height: 14)
                        Menu {
                            Button("编辑配置…") { editing = connection }
                            Button(reading.contains(connection.id) ? "正在读取模型目录…" : "读取模型目录") {
                                reading.insert(connection.id)
                                Task { await model.models(for: connection.id); reading.remove(connection.id) }
                            }.disabled(reading.contains(connection.id))
                            Divider()
                            Button("删除连接", role: .destructive) { model.perform { try model.store.deleteConnection(connection.id) } }
                        } label: {
                            // Drawn by SwiftUI (button menu style + plain button): a borderless Menu hands the
                            // label to AppKit, which ignores the SVG's size and tint, so the arrow rendered wrong.
                            DravionIcon(name: "arrow-down", size: 11, set: "element-plus").foregroundStyle(.secondary)
                                .frame(width: 30, height: 26).contentShape(Rectangle())
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("更多连接操作")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(RelayStyle.border))
                    .disabled(probing.contains(connection.id))
                }
                Text(connection.kind == .api ? "通过当前 API 与模型执行任务；会话和执行事件保存在 Dravion 的 OpenCode 数据目录。"
                     : connection.kind == .doubaoApp ? "直接操作你电脑上的豆包 App（和 Lancer 一样，经 macOS 辅助功能）：把消息填进绑定的对话并发送，再读回豆包的回答。用的是你豆包账号，不需要 API 密钥。豆包只能聊天、读写不了项目文件，所以只在群聊、私聊和后台工作里用，不接开发任务；发送时会把豆包窗口切到前台，一次只发一条。"
                     : connection.connectorTransport.detail)
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if connection.kind == .doubaoApp { doubaoBinding(connection) }
                let current = model.clientModels[connection.kind]
                if connection.kind != .doubaoApp { HStack(spacing: 8) {
                    Text("当前模型").foregroundStyle(.secondary)
                    Text(current?.model ?? (connection.kind == .api ? "按角色指定" : "读取中…")).font(.system(size: 12, weight: .medium, design: .monospaced))
                    if let source = current?.source, !source.isEmpty { Text(source).foregroundStyle(.tertiary) }
                    Spacer()
                    Text(connection.models.isEmpty ? "模型目录未读取" : "模型目录 \(connection.models.count) 个").foregroundStyle(.secondary)
                }.font(.system(size: 11)).lineLimit(1) }
                if let message = connection.probeMessage {
                    Text(message).font(.system(size: 11)).foregroundStyle(connection.probeOK == false ? .orange : .secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if connection.kind == .workbuddy, connection.connectorTransport == .cli {
                    Text("WorkBuddy 安装包自带的命令行只能由应用启动时带上登录，Dravion 用不上。装了独立的 CodeBuddy 命令行（npm install -g @tencent-ai/codebuddy-code）并在终端运行 codebuddy 登录一次后，这个连接器会自动改用它。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if connection.kind == .doubaoApp { Text("一次只发一条，豆包答完再发下一条") } else {
                        Text("同时调用 ≤ \(connection.maxConcurrentSessions ?? 1)")
                        Text("· \(connection.kind.label) 全局托管 ≤ \(model.store.state.routing.sessionLimit(for: connection.kind))")
                    }
                    Spacer()
                    if let date = connection.probedAt { Text(date, style: .relative); Text("前检测") }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

struct RelayManagedSessionsView: View {
    @Bindable var model: RelayAppModel
    private var state: RelayState { model.store.state }
    private var providers: [RelayProviderKind] {
        // 豆包 App has no client sessions to hold: it talks in the one conversation bound on its connection.
        RelayProviderKind.allCases.filter { kind in kind != .doubaoApp && (state.connections.contains { $0.kind == kind } || state.sessionList.contains { $0.key.provider == kind }) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Claude 固定为文档与审查、执行各一个席位。换项目时由你释放旧席位；预约换新会等当前调用退出后生效。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(providers, id: \.self) { provider in
                let slots = state.sessionList.filter { $0.key.provider == provider }
                RelayCard {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack {
                            Text(provider.label).font(.system(size: 14, weight: .semibold))
                            RelayBadge(text: "\(slots.count) / \(state.routing.sessionLimit(for: provider)) 席位", color: .secondary)
                            Spacer()
                            if provider == .claude { Text("每个用途最多 1 个").font(.caption).foregroundStyle(.secondary) }
                            else {
                                Stepper("上限 \(state.routing.sessionLimit(for: provider))", value: Binding(
                                    get: { state.routing.sessionLimit(for: provider) }, set: { limit in
                                        model.perform {
                                            var next = state; var limits = next.routing.sessionLimits ?? [:]
                                            limits[provider.rawValue] = limit; next.routing.sessionLimits = limits
                                            try model.store.commit(next)
                                        }
                                    }), in: 1...32).font(.caption).fixedSize()
                            }
                        }
                        if slots.isEmpty {
                            Text("席位空闲，首次派活时建立；空闲期间不调用模型。").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        ForEach(slots) { slot in Divider().opacity(0.5); sessionRow(slot) }
                    }
                }
            }
            Text("释放席位保留原客户端的历史记录。Dravion 仅统计自己托管的席位，无法限制你在其他客户端手动开启的会话。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private func sessionRow(_ slot: RelayManagedSession) -> some View {
        let busy = model.scheduler.sessions.busyIDs.contains(slot.id)
        let unknown = model.scheduler.sessions.isUnconfirmed(slot.id)
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(slot.key.purpose.label).font(.system(size: 13, weight: .medium))
                RelayBadge(text: unknown ? "原调用待确认" : busy ? "执行中" : "可复用", color: unknown ? .orange : busy ? RelayStyle.accent : .secondary)
                if slot.replacementRequested { RelayBadge(text: "已预约换新", color: .orange) }
                Spacer()
                if slot.replacementRequested {
                    Button("取消换新") { model.perform { try model.scheduler.sessions.cancelReplacement(slot.id) } }
                } else {
                    Button(busy ? "调用后换新" : "下次派活换新") { model.perform { try model.scheduler.sessions.requestReplacement(slot.id) } }.disabled(unknown)
                }
                Button("释放席位") { model.perform { try model.scheduler.sessions.retire(slot.id) } }.disabled(busy || unknown)
            }
            Text(slot.key.projectPath).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            HStack {
                Text(state.connections.first { $0.id == slot.key.connectionID }?.name ?? slot.key.connectionID)
                Text("· \(slot.key.model.isEmpty ? "沿用客户端配置" : slot.key.model)")
                Spacer()
                Text("\(slot.usage.calls) 次调用 · \(slot.usage.resumedCalls) 次复用 · \(RelayTokens.text(slot.usage.tokens.total))")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            if let id = slot.clientSessionID {
                HStack {
                    Text(id).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    RelaySessionActions(model: model, provider: slot.key.provider, sessionID: id)
                }
            } else { Text("尚未建立客户端会话").font(.caption).foregroundStyle(.secondary) }
            if slot.usage.unreportedCalls > 0 {
                Text("\(slot.usage.unreportedCalls) 次调用未报告用量").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct RelaySessionActions: View {
    let model: RelayAppModel
    let provider: RelayProviderKind
    let sessionID: String
    var body: some View {
        HStack(spacing: 10) {
            Button("复制 ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sessionID, forType: .string) }
            if provider == .codex {
                Button("在 Codex 中打开") { model.openClientSession(provider: provider, id: sessionID) }
            } else if let record = model.sessions.first(where: { $0.provider == provider && $0.sessionID == sessionID }) {
                Button("显示原生记录") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.recordPath)]) }
            }
        }.font(.system(size: 11)).buttonStyle(.borderless)
    }
}
