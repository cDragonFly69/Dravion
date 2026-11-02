import AppKit
import SwiftUI
import RelayCore

/// Renders new fixture views in memory. It never captures or operates the user's desktop/windows.
@MainActor enum RelayFixtureRenderer {
    static func render() throws {
        let env = ProcessInfo.processInfo.environment
        guard CommandLine.arguments.contains("--ui-test"), env["RELAY_DATA_DIR"]?.hasPrefix("/") == true,
              let destination = env["RELAY_RENDER_DIR"], destination.hasPrefix("/") else {
            throw RelayError.invalid("Fixture rendering requires --ui-test, an isolated RELAY_DATA_DIR and RELAY_RENDER_DIR.")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let model = try RelayAppModel(isUITest: true)
        guard model.store.state.runs.allSatisfy({ !$0.status.isWorking && $0.status != .queued }),
              model.store.state.connections.allSatisfy({ $0.binaryPath == "/usr/bin/false" }) else {
            throw RelayError.invalid("Only inert UI fixture data may be rendered.")
        }
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        if env["RELAY_RENDER_READING"] != nil { return try renderReading(model, to: destination) }
        if env["RELAY_RENDER_WORKBENCH"] != nil { return try renderWorkbench(model, to: destination) }
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            NSApp.appearance = appearance
            for page in ["dashboard", "node", "sessions", "usage", "output", "policies", "connectors", "window",
                         "window-dashboard", "window-log", "window-role", "window-tokens", "window-milestones", "window-add-member", "window-node", "wechat"] {
                let content: AnyView
                if page.hasPrefix("window-") {
                    // The dashboard window with one of its overlays open.
                    model.section = .dashboard
                    if let run = model.store.state.runs.first {
                        let id = run.id
                        switch page {
                        case "window-log": model.present("log", style: .drawer, width: 760) { RelayRunLogPanel(model: model, runID: id) }
                        case "window-role":
                            if let role = run.roles.first { model.present("role", width: 480) { RelayRoleConfigPanel(model: model, runID: id, roleID: role.id) } }
                        case "window-tokens": model.present("tokens", width: 640) { RelayTokenPanel(model: model, runID: id) }
                        case "window-milestones": model.present("milestones", width: 640) { RelayMilestonesPanel(model: model, runID: id) }
                        case "window-add-member": model.present("add-member", width: 560) { RelayAddMemberPanel(model: model, runID: id) }
                        case "window-node":
                            if let role = run.tasks.first?.task.roleId { model.present("node", width: 900) { RelayNodePanel(model: model, runID: id, key: .init(stage: .executing, roleID: role)) } }
                        default: model.overlay = nil
                        }
                    }
                    let window = RelayRootView(model: model).frame(width: 1400, height: 900)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    try snapshot(window, size: NSSize(width: 1400, height: 900), appearance: appearance,
                                 to: URL(fileURLWithPath: destination).appendingPathComponent("\(dark ? "dark" : "light")-\(page).png"))
                    model.overlay = nil
                    continue
                }
                switch page {
                case "window":
                    // The whole window with its sidebar, unfocused; a key window's focus cannot be shown offscreen.
                    model.openWorkbench(.people)
                    let window = RelayRootView(model: model).frame(width: 1240, height: 820)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    try snapshot(window, size: NSSize(width: 1240, height: 820), appearance: appearance,
                                 to: URL(fileURLWithPath: destination).appendingPathComponent("\(dark ? "dark" : "light")-window.png"))
                    model.section = .dashboard
                    continue
                case "sessions": content = AnyView(RelayManagedSessionsView(model: model))
                case "usage": content = AnyView(RelayUsageView(model: model))
                case "connectors": content = AnyView(RelayConnectionsView(model: model))
                case "wechat": content = AnyView(RelayWeChatCard(model: model))
                case "policies":
                    // Inert in-memory readings: an off-peak DeepSeek window and a spent Claude week.
                    var policy = RelayModelPolicy(connectionID: "workbuddy", model: "deepseek-v3"); policy.applyOffPeakDeepSeek()
                    try model.store.savePolicy(policy)
                    model.scheduler.quota.update(.claude, [
                        .init(name: "5 小时", usedFraction: 0.42, resetsAt: Date().addingTimeInterval(8_700), exhausted: false),
                        .init(name: "每周", usedFraction: 1, resetsAt: Date().addingTimeInterval(200_000), exhausted: true)])
                    content = AnyView(RelayPoliciesView(model: model))
                case "output":
                    guard let run = model.store.state.runs.first else { throw RelayError.invalid("Fixture run is missing") }
                    content = AnyView(VStack(alignment: .leading, spacing: 16) {
                        RelayCodeOutput(text: run.tasks.first?.output ?? "")
                        RelayTerminalLog(events: model.store.events[run.id] ?? [], roles: run.roles).frame(height: 380)
                    })
                case "node":
                    guard let run = model.store.state.runs.first else { throw RelayError.invalid("Fixture run is missing") }
                    content = AnyView(RelayNodeInspector(model: model, run: run, key: .init(stage: .executing, roleID: "engineer")) {})
                default: content = AnyView(RelayDashboard(model: model))
                }
                let scroll = ScrollView { content.padding(28).frame(maxWidth: .infinity, alignment: .leading) }
                // The dashboard is rendered tall enough to show every section under the graph.
                let height: CGFloat = page == "dashboard" ? 2000 : 960
                let root = scroll.frame(width: 1060, height: height).background(RelayStyle.canvas)
                    .environment(\.colorScheme, dark ? .dark : .light).tint(RelayStyle.action)
                try snapshot(root, size: NSSize(width: 1060, height: height), appearance: appearance,
                             to: URL(fileURLWithPath: destination).appendingPathComponent("\(dark ? "dark" : "light")-\(page).png"))
            }
        }
    }

    /// The approved reading workspace and Lancer integration, using only the isolated inert fixture store.
    private static func renderReading(_ app: RelayAppModel, to destination: String) throws {
        try settlePendingQuestion(app)
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            NSApp.appearance = appearance
            func shot(_ name: String, _ view: some View, width: CGFloat = 1400, height: CGFloat = 900) throws {
                try snapshot(view.frame(width: width, height: height).background(RelayStyle.canvas)
                    .environment(\.colorScheme, dark ? .dark : .light).tint(RelayStyle.action),
                             size: .init(width: width, height: height), appearance: appearance,
                             to: URL(fileURLWithPath: destination).appendingPathComponent("\(dark ? "dark" : "light")-\(name).png"))
            }
            app.go(.page(.knowledge))
            try shot("reading-workspace", RelayRootView(model: app))
            try shot("reading-content", RelayKnowledgeView(model: app), width: 1080, height: 760)
            try shot("reading-narrow", RelayKnowledgeView(model: app), width: 640, height: 760)
            for page in [RelayKnowledgePage.search, .review, .growth, .history, .settings] {
                try shot("knowledge-\(page)", RelayKnowledgeView(model: app, page: page), width: 1080, height: 760)
            }
            if let card = app.knowledge?.cards(type: .problem, limit: 1).first {
                try shot("reading-narrow-reader", RelayKnowledgeView(model: app, selection: card.id), width: 640, height: 760)
                try shot("knowledge-sources", RelayKnowledgeDetail(model: app, cardID: card.id, embedded: true, tab: .sources).padding(24),
                         width: 640, height: 760)
                app.present("knowledge-edit", width: 720) { RelayKnowledgeDetail(model: app, cardID: card.id, editing: true) }
                try shot("knowledge-edit", RelayRootView(model: app)); app.dismissOverlay()
            }
            app.present("knowledge-capture", width: 620) { RelayKnowledgeCaptureCard(model: app, kind: .paste) }
            try shot("knowledge-capture", RelayRootView(model: app)); app.dismissOverlay()
            if let run = app.store.state.runs.first {
                app.openThread(run.id)
                try shot("conversation-trajectory", RelayRootView(model: app))
                let graph = RelayTrajectory.build(run: run, events: app.store.events[run.id] ?? [])
                try shot("trajectory-legend", RelayTrajectoryPanel(graph: graph, showLegend: true,
                         onSelect: { _ in }, onSelectRecord: { _ in }, onFocusLane: { _ in }, onClose: {}), width: 380, height: 760)
                try shot("trajectory-events", RelayTrajectoryPanel(graph: graph, showEvents: true,
                         onSelect: { _ in }, onSelectRecord: { _ in }, onFocusLane: { _ in }, onClose: {}), width: 380, height: 760)
            }
        }
    }

    /// The main window on each collaboration page, light and dark (offscreen; the real window is checked apart).
    private static func renderWorkbench(_ app: RelayAppModel, to destination: String) throws {
        guard let host = app.workforce else { throw RelayError.invalid(app.workforceError ?? "workforce store missing") }
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            NSApp.appearance = appearance
            for page in RelayWorkbenchModel.Section.allCases {
                app.openWorkbench(page)
                app.workbench?.workflowID = host.workflows().first?.id
                let view = RelayRootView(model: app).frame(width: 1400, height: 900).environment(\.colorScheme, dark ? .dark : .light)
                try snapshot(view, size: NSSize(width: 1400, height: 900), appearance: appearance,
                             to: URL(fileURLWithPath: destination).appendingPathComponent("\(dark ? "dark" : "light")-workbench-\(page.icon).png"))
            }
            // Outer pages that are not collaboration pages: 工作台, and 设置 with its inner list.
            for page in [RelaySection.dashboard, .connectors] {
                app.go(.page(page))
                try snapshot(RelayRootView(model: app).frame(width: 1400, height: 900).environment(\.colorScheme, dark ? .dark : .light),
                             size: NSSize(width: 1400, height: 900), appearance: appearance,
                             to: URL(fileURLWithPath: destination).appendingPathComponent("\(dark ? "dark" : "light")-nav-\(page).png"))
            }
            // A task opened from 项目: its conversation.
            if let run = app.store.state.runs.first {
                app.openThread(run.id)
                try snapshot(RelayRootView(model: app).frame(width: 1400, height: 900).environment(\.colorScheme, dark ? .dark : .light),
                             size: NSSize(width: 1400, height: 900), appearance: appearance,
                             to: URL(fileURLWithPath: destination).appendingPathComponent("\(dark ? "dark" : "light")-thread.png"))
            }
            // 员工 → 设置: the role editor inline.
            app.openWorkbench(.people); app.workbench?.employeeID = "engineer"; app.workbench?.peopleTab = .settings
            try snapshot(RelayRootView(model: app).frame(width: 1400, height: 900).environment(\.colorScheme, dark ? .dark : .light),
                         size: NSSize(width: 1400, height: 900), appearance: appearance,
                         to: URL(fileURLWithPath: destination).appendingPathComponent("\(dark ? "dark" : "light")-workbench-people-settings.png"))
            app.workbench?.peopleTab = .chat
            // 群聊 with a task group open instead of a channel.
            if let run = app.store.state.runs.first {
                app.workbench?.open(taskGroup: run.id)
                let view = RelayRootView(model: app).frame(width: 1400, height: 900).environment(\.colorScheme, dark ? .dark : .light)
                try snapshot(view, size: NSSize(width: 1400, height: 900), appearance: appearance,
                             to: URL(fileURLWithPath: destination).appendingPathComponent("\(dark ? "dark" : "light")-workbench-taskgroup.png"))
                app.workbench?.taskRunID = nil
            }
            // The fixture's waiting run is settled here: its 需要你确认 card would otherwise cover the shots below.
            try settlePendingQuestion(app)
            // The thread with its trajectory panel unobstructed (the 会话 shot above has the card over it).
            if let run = app.store.state.runs.first {
                app.openThread(run.id)
                try snapshot(RelayRootView(model: app).frame(width: 1400, height: 900).environment(\.colorScheme, dark ? .dark : .light),
                             size: NSSize(width: 1400, height: 900), appearance: appearance,
                             to: URL(fileURLWithPath: destination).appendingPathComponent("\(dark ? "dark" : "light")-thread-calm.png"))
            }
            // 知识库 (K1): the new outer page, and one card open above it.
            if app.knowledge != nil {
                app.go(.page(.knowledge))
                try snapshot(RelayRootView(model: app).frame(width: 1400, height: 900).environment(\.colorScheme, dark ? .dark : .light),
                             size: NSSize(width: 1400, height: 900), appearance: appearance,
                             to: URL(fileURLWithPath: destination).appendingPathComponent("\(dark ? "dark" : "light")-knowledge.png"))
                // Taller than the window, so 入库记录 and the list below the fold can be checked too.
                try snapshot(RelayRootView(model: app).frame(width: 1400, height: 1500).environment(\.colorScheme, dark ? .dark : .light),
                             size: NSSize(width: 1400, height: 1500), appearance: appearance,
                             to: URL(fileURLWithPath: destination).appendingPathComponent("\(dark ? "dark" : "light")-knowledge-full.png"))
                if let card = app.knowledge?.cards(limit: 1).first {
                    app.present("knowledge-card", width: 780) { RelayKnowledgeDetail(model: app, cardID: card.id) }
                    try snapshot(RelayRootView(model: app).frame(width: 1400, height: 900).environment(\.colorScheme, dark ? .dark : .light),
                                 size: NSSize(width: 1400, height: 900), appearance: appearance,
                                 to: URL(fileURLWithPath: destination).appendingPathComponent("\(dark ? "dark" : "light")-knowledge-card.png"))
                    app.dismissOverlay()
                }
                // The paste overlay: the other way in, besides “记下来” in a conversation.
                app.present("knowledge-capture", width: 620) { RelayKnowledgeCaptureCard(model: app, kind: .paste) }
                try snapshot(RelayRootView(model: app).frame(width: 1400, height: 900).environment(\.colorScheme, dark ? .dark : .light),
                             size: NSSize(width: 1400, height: 900), appearance: appearance,
                             to: URL(fileURLWithPath: destination).appendingPathComponent("\(dark ? "dark" : "light")-knowledge-capture.png"))
                app.dismissOverlay()
            }
        }
    }

    /// Marks the fixture's waiting run as finished, so 需要你确认 stops covering the page during layout shots.
    private static func settlePendingQuestion(_ app: RelayAppModel) throws {
        var quiet = app.store.state
        quiet.runs = quiet.runs.map { run in
            guard !run.status.isTerminal else { return run }
            var copy = run; copy.status = .succeeded; copy.pendingQuestion = nil; copy.pause = nil
            return copy
        }
        try app.store.commit(quiet)
    }

    private static func snapshot(_ view: some View, size: NSSize, appearance: NSAppearance, to file: URL) throws {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [], backing: .buffered, defer: false)
        window.appearance = appearance; window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw RelayError.invalid("Cannot create fixture bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw RelayError.invalid("Cannot encode fixture bitmap") }
        try png.write(to: file, options: .atomic)
        window.contentView = nil
        print("FIXTURE_RENDERED \(file.path)")
    }
}
