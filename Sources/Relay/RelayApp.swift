import AppKit
import SwiftUI
import Observation
import UserNotifications
import RelayCore
import DravionKit

enum RelayHostPaths {
    static var root: URL {
        if let path = ProcessInfo.processInfo.environment["RELAY_DATA_DIR"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RelayNative")
    }
    static var usage: URL { root.appendingPathComponent("APIUse") }
    static var sidecars: URL { Bundle.main.resourceURL!.appendingPathComponent("sidecars") }
}

@MainActor @Observable
final class RelayAppModel {
    let store: RelayStore
    let providers: RelayProviders
    /// 自动化模块 (R41): installable, model-free jobs; employees call them from chats instead of spending turns.
    let automations: RelayAutomationHost
    let scheduler: RelayScheduler
    /// Runs tasks the Dravion platform dispatches to this Mac (D6); off until the user turns it on.
    let runner: DravionRunner
    /// Employees, channels and background work (E); shared by the main window and the workbench. Nil when its
    /// store could not be opened (for example another Dravion process is its writer) — the rest of the app runs on.
    let workforce: RelayWorkforceHost?
    let workforceError: String?
    /// 个人知识库 (K, ADR-037): the single writer of this account's cards and index. Nil when another Dravion
    /// process already holds the writer lock — the rest of the app keeps working.
    let knowledge: RelayKnowledgeStore?
    let knowledgeError: String?
    /// Bumped on every knowledge write (page, “记下来”, undo, an edit made outside Dravion), so the page re-reads.
    var knowledgeTick = 0
    /// Choosing an original section leaves the collaboration pages.
    var section = RelaySection.dashboard { didSet { showsWorkbench = false } }
    /// The collaboration pages (员工、群聊、后台工作、待处理、交付) shown in this same window; their own
    /// selection and drafts live in `workbench`.
    var showsWorkbench = false
    @ObservationIgnored private(set) lazy var workbench: RelayWorkbenchModel? = workforce.map { RelayWorkbenchModel(app: self, host: $0) }
    /// The outer row that is current: deliveries belong to 收件箱, every settings page to the 设置 row.
    var nav: RelayNav {
        if showsWorkbench { return .work(workbench?.section == .delivery ? .inbox : workbench?.section ?? .channels) }
        return RelayNav.settingsPages.contains(section) ? .page(.settings) : .page(section)
    }
    /// The settings page last open, so the 设置 row returns to it.
    @ObservationIgnored private var lastSettingsPage = RelaySection.settings
    func go(_ nav: RelayNav) {
        switch nav {
        case .page(.settings): section = lastSettingsPage
        case .page(let page):
            if RelayNav.settingsPages.contains(page) { lastSettingsPage = page }
            section = page
        case .work(let page): openWorkbench(page)
        }
    }
    func openWorkbench(_ page: RelayWorkbenchModel.Section) {
        guard let workbench else { error = workforceError ?? "协作数据没有打开。"; return }
        workbench.section = page; showsWorkbench = true
    }
    var selectedRunID: String?
    var showsComposer = false { didSet { if !showsComposer { legacyComposer = false } } }
    /// 新建任务 opens 派任务 (hand work to an employee or group); this switches the card to the old manual staffing.
    var legacyComposer = false
    /// The card or drawer open above the page (see `RelayOverlayHost`).
    var overlay: RelayOverlay?
    /// Text typed in the dashboard prompt box; the task sheet takes it over when it opens.
    var draftGoal = ""
    var draftDictation = false
    /// Project (folder) the task sheet opens with, when started from a project in the sidebar.
    var draftProjectID: String?
    var sessions: [RelayExternalSession] = []
    var sessionIssues: [String] = []
    var scanning = false
    var clientModels: [RelayProviderKind: RelayClientModels.Configuration] = [:]
    var usageStore: UsageStore?
    var usageSettings: AppSettings?
    var error: String?
    var notice: String?
    var openUsage: () -> Void = {}
    var toggleUsagePanel: () -> Void = {}
    var focusWindow: () -> Void = {}
    let isUITest: Bool
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// Local automation entry (inbox folder in the data directory); see RelayInbox.
    @ObservationIgnored private var inbox: RelayInbox?

    init(isUITest: Bool = false) throws {
        self.isUITest = isUITest
        store = try RelayStore(directory: RelayHostPaths.root, secrets: isUITest ? RelayPreviewSecrets() : RelayKeychain())
        providers = RelayProviders(store: store, sidecars: RelayHostPaths.sidecars)
        scheduler = RelayScheduler(store: store, executor: providers)
        automations = RelayAutomationHost(store: store)
        runner = DravionRunner(store: store, executor: providers,
                               secrets: isUITest ? RelayPreviewSecrets() : RelayKeychain(service: "ai.dravion.desktop.device"),
                               defaults: isUITest ? UserDefaults(suiteName: "ai.dravion.desktop.uitest") ?? .standard : .standard)
        do {
            let host = try RelayWorkforceHost(store: store, scheduler: scheduler, executor: providers)
            workforce = host; workforceError = nil
        } catch { workforce = nil; workforceError = error.localizedDescription }
        // The knowledge base belongs to this account; “记下来” in a direct chat or a channel writes through the host.
        var knowledgeStore: RelayKnowledgeStore?
        var knowledgeFailure: String?
        do {
            let opened = try RelayKnowledgeStore(root: RelayHostPaths.root, redact: store.redact)
            knowledgeStore = opened
            workforce?.knowledge = opened
        } catch { knowledgeFailure = error.localizedDescription }
        knowledge = knowledgeStore
        knowledgeError = knowledgeFailure
        knowledgeStore?.onChange = { [weak self] in Task { @MainActor in self?.knowledgeTick &+= 1 } }
        // Startup check (K §4): cards edited, added, moved or deleted in Obsidian or the Finder are re-indexed, and a
        // card the user deleted outside Dravion becomes a tombstone so automatic capture will not bring it back.
        if let opened = knowledgeStore {
            Task.detached(priority: .utility) { _ = try? opened.reconcile() }
        }
        scheduler.onSession = { [weak self] connection, id in
            guard connection.revealInClient == true, self?.isUITest == false else { return }
            self?.openClientSession(provider: connection.kind, id: id)
        }
        scheduler.onFinished = { [weak self] run in
            guard let self, run.status != .cancelled, run.status == .failed || RelayWeChat.notifyFinished else { return }
            RelayWeChat.notify(run, model: self)
        }
        scheduler.onAttention = { [weak self] run in
            if let self { RelayWeChat.notify(run, model: self) }
            self?.notice = "\(run.input.title)：\(run.pause?.message ?? run.status.label)"
            NSApp.dockTile.badgeLabel = "!"
            guard UserDefaults.standard.bool(forKey: "relay.notifications") else { return }
            let content = UNMutableNotificationContent()
            content.title = "Dravion · 任务需要处理"
            content.body = "\(run.input.title) · \(run.status.label)"
            content.sound = .default
            UNUserNotificationCenter.current().add(.init(identifier: run.id, content: content, trigger: nil)) { error in
                if let error { Task { @MainActor in self?.error = error.localizedDescription } }
            }
        }
        scheduler.start()
        // 指向性任务: a run dispatched from a chat becomes the one 工作台 shows (the chat stays where it is).
        workforce?.onRunDispatched = { [weak self] id in
            guard let self else { return }
            self.selectedRunID = id
            self.perform { _ = try self.store.loadEvents(id, fullHistory: true) }
        }
        workforce?.onNotify = { title, body in
            guard UserDefaults.standard.bool(forKey: "relay.notifications") else { return }
            let content = UNMutableNotificationContent()
            content.title = "Dravion · \(title)"; content.body = body
            UNUserNotificationCenter.current().add(.init(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if !isUITest { workforce?.start() }
        workforce?.automations = automations
        // Quit from the next run-loop turn, never from inside the running script's task: terminating there waits for
        // a shutdown task that cannot start, and the app hangs half-quit (user report, 2026-11-02).
        automations.onQuit = { NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.3) }
        automations.onFinished = { [weak self] run in
            guard run.trigger == .schedule, run.status == .failed else { return }
            self?.notice = run.summary
        }
        if !isUITest { automations.start() }
        // Task executors (Claude Code, Codex…) run scripts themselves through `--run-automation`, no model steps.
        scheduler.automationGuide = { [weak self] in
            self?.automations.agentGuide(executable: Bundle.main.executablePath ?? "")
        }
        if !isUITest {
            inbox = RelayInbox(model: self, root: RelayHostPaths.root)
            inbox?.start()
        }
        // Screenshot checks open a given page in --ui-test mode only: RELAY_UI_SECTION=chat, RELAY_UI_RUN=<id prefix>.
        if isUITest, let name = ProcessInfo.processInfo.environment["RELAY_UI_SECTION"],
           let wanted = RelaySection.allCases.first(where: { "\($0)" == name }) { section = wanted }
        if isUITest, let prefix = ProcessInfo.processInfo.environment["RELAY_UI_RUN"],
           let run = store.state.runs.first(where: { $0.id.hasPrefix(prefix) }) { selectedRunID = run.id; perform { _ = try store.loadEvents(run.id, fullHistory: true) } }
    }

    var selectedRun: RelayRun? { store.state.runs.first { $0.id == selectedRunID } }
    /// A task from 项目: its conversation (每位员工的过程与回复), not the 工作台 graph.
    func openThread(_ id: String) {
        selectedRunID = id; section = .thread
        perform { _ = try store.loadEvents(id, fullHistory: true) }
    }
    func selectRun(_ id: String) {
        selectedRunID = id; section = .dashboard
        perform { _ = try store.loadEvents(id, fullHistory: true) }
    }
    func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { self.error = store.redact(error.localizedDescription) }
    }
    func refreshSessions() {
        guard !scanning, !isUITest else { return }
        scanning = true
        scanTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { (RelayClientSessions.read(), RelayClientModels.read()) }.value
            guard let self else { return }
            self.sessions = result.0.sessions; self.sessionIssues = result.0.issues
            self.clientModels = result.1; self.scanning = false
        }
    }
    func effectiveModel(_ role: RelayRole, connection: RelayConnection?) -> RelayClientModels.Effective {
        RelayClientModels.effective(role: role, connection: connection, configuration: connection.flatMap { clientModels[$0.kind] })
    }
    func openClientSession(provider: RelayProviderKind, id: String) {
        perform {
            try RelaySessionPool.validateClientID(id)
            guard provider == .codex, let url = URL(string: "codex://threads/\(id)") else {
                throw RelayError.invalid("此客户端尚未提供可验证的会话直达链接。请使用会话 ID 在原客户端查找。")
            }
            guard NSWorkspace.shared.open(url) else { throw RelayError.invalid("未找到能打开此会话的 Codex 客户端。") }
        }
    }
    func models(for connectionID: String) async {
        guard let connection = store.state.connections.first(where: { $0.id == connectionID }) else { return }
        do {
            let catalog = try await catalog(connection)
            var updated = connection; updated.models = catalog.ids
            try store.saveConnection(updated)
            notice = catalog.source
        } catch { self.error = store.redact(error.localizedDescription) }
    }
    /// The client's model list: what the connector itself reports, plus the client's own groups (cc-switch
    /// providers, DSH profiles, WorkBuddy families). Claude Code and DSH report nothing on their own.
    func catalog(_ connection: RelayConnection) async throws -> (ids: [String], groups: [RelayClientCatalog.Group], source: String) {
        var reported: RelayModelCatalog?
        var failure: Error?
        do { reported = try await providers.models(connection) } catch { failure = error }
        var probe = connection; probe.models = reported?.ids ?? []
        let groups = await Task.detached(priority: .utility) { RelayClientCatalog.groups(for: probe) }.value
        var seen = Set<String>()
        let ids = ((reported?.ids ?? []) + groups.flatMap { $0.entries.map(\.id) }).filter { seen.insert($0).inserted }
        if ids.isEmpty, let failure { throw failure }
        let source = groups.isEmpty ? (reported?.source ?? "") : "已读取 \(ids.count) 个模型，\(groups.count) 个分组" + (reported.map { " · \($0.source)" } ?? "")
        return (ids, groups, source)
    }
    /// 豆包 App: remember the conversation open in Doubao right now as the one its employees talk in.
    func bindDoubao(_ connection: RelayConnection) async {
        guard Self.requestAccessibility() else { error = RelayDoubaoApp.explain("E_ACCESSIBILITY_REQUIRED"); return }
        do {
            let view = try await providers.doubao.snapshot()
            guard let id = view.conversationId else { error = RelayDoubaoApp.explain("E_APP_WINDOW_MISSING"); return }
            guard var current = store.state.connections.first(where: { $0.id == connection.id }) else { return }
            current.appConversationID = id
            current.appConversationTitle = view.title.isEmpty ? "未命名对话" : view.title
            current.probeOK = true; current.probedAt = Date()
            current.probeMessage = "已绑定豆包对话「\(current.appConversationTitle ?? id)」· 这个连接的员工都在这个对话里收发消息"
            perform { try store.saveConnection(current) }
        } catch { self.error = store.redact(error.localizedDescription) }
    }
    /// Doubao is driven through Accessibility, granted to Dravion (the bridge runs as its child). Asking here puts
    /// Dravion in System Settings' list with the system prompt, instead of failing silently.
    static func requestAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    func probe(_ connection: RelayConnection) async {
        if connection.kind == .doubaoApp, !isUITest, !Self.requestAccessibility() {
            var updated = connection
            updated.probeOK = false; updated.probedAt = Date(); updated.probeMessage = RelayDoubaoApp.explain("E_ACCESSIBILITY_REQUIRED")
            perform { try store.saveConnection(updated) }
            return
        }
        var updated = connection
        do { updated.probeMessage = try await providers.probe(connection); updated.probeOK = true }
        catch { updated.probeMessage = store.redact(error.localizedDescription); updated.probeOK = false }
        updated.probedAt = Date()
        guard let current = store.state.connections.first(where: { $0.id == connection.id }),
              current == connection else { notice = "连接配置已变化，请重新检测。"; return }
        perform { try store.saveConnection(updated) }
    }
    func submit(_ input: RelayRunInput) async -> Bool {
        do {
            let run = try await scheduler.create(input)
            selectRun(run.id); showsComposer = false; return true
        } catch { self.error = store.redact(error.localizedDescription); return false }
    }
    func shutdown() async { scanTask?.cancel(); workforce?.shutdown(); await scheduler.shutdown() }
}

enum RelaySection: String, CaseIterable, Identifiable {
    case dashboard = "工作台", projects = "项目与会话"
    case knowledge = "知识库"
    case connectors = "连接器与会话", thread = "会话"
    case policies = "模型时段", usage = "额度与用量", settings = "调度设置"
    case automation = "自动化"
    case business = "业务模块"
    var id: String { rawValue }
    /// Phosphor icon (Sources/Relay/Icons/phosphor); see AGENTS.md "界面规范" for the rules.
    var icon: String {
        switch self {
        case .dashboard: return "tree-structure"
        case .knowledge: return "books"
        case .thread: return "chats-circle"
        case .projects: return "folders"
        case .connectors: return "cpu"
        case .policies: return "clock-countdown"
        case .usage: return "chart-bar"
        case .settings: return "sliders-horizontal"
        case .automation: return "lightning"
        case .business: return "briefcase"
        }
    }
    var symbol: String {
        switch self {
        case .dashboard: return "point.3.connected.trianglepath.dotted"
        case .knowledge: return "books.vertical"
        case .thread: return "bubble.left.and.text.bubble.right"
        case .projects: return "folder"
        case .connectors: return "link"
        case .policies: return "clock"
        case .usage: return "chart.bar.xaxis"
        case .settings: return "slider.horizontal.3"
        case .automation: return "bolt"
        case .business: return "briefcase"
        }
    }
}

/// Two-level navigation, as in the Codex app (user request, 2026-11-01). The outer sidebar holds only where work
/// happens, then the projects with their tasks; configuration and resources sit behind one 设置 row at the bottom,
/// with their own inner list. Pages with several parts keep an inner level of their own (收件箱: 待处理 · 交付).
enum RelayNav: Hashable {
    case page(RelaySection)
    case work(RelayWorkbenchModel.Section)
    static let primary: [RelayNav] = [.page(.dashboard), .work(.channels), .work(.people), .work(.background), .page(.automation), .page(.business), .work(.inbox),
                                      .page(.knowledge)]
    /// The inner list of 设置.
    static let settingsPages: [RelaySection] = [.settings, .connectors, .policies, .usage, .projects]
    var title: String {
        switch self {
        case .page(let page): page.rawValue
        case .work(.inbox): "收件箱"
        case .work(let page): page.rawValue
        }
    }
    var icon: String { switch self { case .page(let s): s.icon; case .work(let w): w.icon } }
}

@main
enum RelayNativeApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains(StatusLineHook.modeArgument) {
            StatusLineHook.runAsStatusLine(); exit(0)
        }
        if CommandLine.arguments.contains("--install-statusline") {
            let installed = StatusLineHook.install()
            print(installed ? "installed" : "failed"); exit(installed ? 0 : 1)
        }
        if CommandLine.arguments.contains("--uninstall-statusline") {
            let removed = StatusLineHook.uninstall()
            print(removed ? "uninstalled" : "failed"); exit(removed ? 0 : 1)
        }
        if CommandLine.arguments.contains(UsageReport.modeArgument) { exit(UsageReport.run()) }
        if CommandLine.arguments.contains(RecapReport.modeArgument) { RecapReport.run(arguments: CommandLine.arguments) }
        if let index = CommandLine.arguments.firstIndex(of: "--run-automation") { RelayAutomationCLI.run(Array(CommandLine.arguments[(index + 1)...])) }
        if CommandLine.arguments.contains("--render-fixture") {
            do { try RelayFixtureRenderer.render(); exit(0) }
            catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
        }
        let app = NSApplication.shared
        let delegate = RelayAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

private final class RelayPreviewSecrets: RelaySecretStorage {
    func read(_ id: String) throws -> String? { nil }
    func write(_ value: String?, for id: String) throws { throw RelayError.invalid("界面验证不读取或写入真实凭据。") }
}

@MainActor
final class RelayAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var model: RelayAppModel?
    private var usage: AppDelegate?
    private var quitting = false
    private var widgetTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        signal(SIGPIPE, SIG_IGN)
        installMenu()
        do {
            let testing = CommandLine.arguments.contains("--ui-test")
            if testing, let appearance = ProcessInfo.processInfo.environment["RELAY_UI_APPEARANCE"] {
                NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            }
            let model = try RelayAppModel(isUITest: testing)
            self.model = model
            if !testing {
                let usage = AppDelegate(settings: .restored(), hosted: true)
                self.usage = usage
                usage.applicationDidFinishLaunching(notification)
                model.openUsage = { [weak usage] in usage?.showSettings() }
                model.toggleUsagePanel = { [weak usage] in usage?.settings.isPanelVisible.toggle() }
                model.usageStore = usage.store
                model.usageSettings = usage.settings
                RelayQuotaFeed.start(model: model)
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = testing ? "Dravion · 界面验证" : "Dravion"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.minSize = NSSize(width: 1020, height: 700)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName(testing ? "RelayValidationWindow" : "RelayMainWindow")
            window.contentView = NSHostingView(rootView: RelayRootView(model: model))
            self.window = window
            model.focusWindow = { [weak self] in self?.showWindow() }
            window.center(); showWindow()
            // Screenshot checks only: RELAY_UI_WORKBENCH=<员工|群聊|后台工作|待处理|交付> opens that collaboration page.
            if testing, let name = ProcessInfo.processInfo.environment["RELAY_UI_WORKBENCH"] {
                model.openWorkbench(RelayWorkbenchModel.Section(rawValue: name) ?? .channels)
            }
            model.refreshSessions()
            if !testing {
                widgetTask = Task { [weak model] in
                    while !Task.isCancelled {
                        if let model {
                            do { try RelayWidgetPublisher.publish(model.store.state.runs) }
                            catch { model.error = "小组件快照保存失败：\(error.localizedDescription)"; break }
                        }
                        do { try await Task.sleep(for: .seconds(15)) } catch { break }
                    }
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Dravion 无法启动"
            alert.informativeText = "\(error.localizedDescription)\n原有数据保留在：\(RelayHostPaths.root.path)"
            alert.addButton(withTitle: "退出"); alert.runModal(); NSApp.terminate(nil)
        }
    }
    private func showWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "relay" {
            if PulseLink(url: url) != nil {
                usage?.application(application, open: [url])
                continue
            }
            guard url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { continue }
            if url.host == "run", url.pathComponents.count == 2,
               let id = url.pathComponents.last, model?.store.state.runs.contains(where: { $0.id == id }) == true {
                model?.selectRun(id)
            } else if url.host == "usage" { model?.openUsage() }
            else if url.host == "dashboard" { model?.section = .dashboard }
        }
        showWindow()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateNow }
        quitting = true
        widgetTask?.cancel()
        Task {
            await model?.shutdown()
            usage?.stopForHost()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    @objc private func newTask() { model?.showsComposer = true; showWindow() }
    @objc private func settings() { model?.section = .settings; showWindow() }
    private func installMenu() {
        let bar = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "关于 Dravion", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(withTitle: "调度设置…", action: #selector(settings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "退出 Dravion", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenu(title: "文件")
        file.addItem(withTitle: "新建任务", action: #selector(newTask), keyEquivalent: "n").target = self
        file.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"), ("剪切", "cut:", "x"),
                                       ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        for menu in [app, file, edit] { let item = NSMenuItem(); item.submenu = menu; bar.addItem(item) }
        NSApp.mainMenu = bar
    }
}
