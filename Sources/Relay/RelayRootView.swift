import SwiftUI
import RelayCore

struct RelayRootView: View {
    @Bindable var model: RelayAppModel
    @AppStorage("sidebar.collapsedProjects") private var collapsedRaw = ""
    private var collapsedProjects: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 8) {
                        DravionMark(size: 24)
                        RelayPixelText(text: "Dravion", pixel: 2.5).foregroundStyle(DravionBrand.solidInk)
                        RelayProductTag(text: "BOT")
                    }
                    Button { model.showsComposer = true } label: {
                        Label { Text("新建任务") } icon: { DravionIcon(name: "plus-circle", size: 16) }.font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(RelayStyle.border))
                            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
                    }.buttonStyle(.plain).keyboardShortcut("n").accessibilityIdentifier("new-task")
                }.padding(.horizontal, 14).padding(.top, 30)
                // No List selection: AppKit draws a focused sidebar's selection in the system accent (blue) and
                // ignores tint/accentColor there. The highlight is drawn here in neutral grey in every focus state;
                // arrow keys still move between sections while the sidebar has focus.
                List {
                    Section {
                        ForEach(RelayNav.primary, id: \.self) { item in navRow(item) }
                    }
                    let recent = model.store.state.runs.filter { $0.archivedAt == nil }
                    if !recent.isEmpty || !model.store.state.projects.isEmpty {
                        Section("项目") {
                            ForEach(RelaySidebarProjects.groups(model.store.state, runs: recent), id: \.project.id) { group in
                                RelaySidebarProjectRow(model: model, project: group.project, runs: group.runs)
                                    .listRowInsets(EdgeInsets(top: 1, leading: 2, bottom: 1, trailing: 2))
                                if !collapsedProjects.contains(group.project.id) {
                                    ForEach(group.runs.prefix(8)) { run in
                                        RelaySidebarRunRow(model: model, run: run)
                                            .padding(.leading, 8)
                                            .listRowInsets(EdgeInsets(top: 1, leading: 2, bottom: 1, trailing: 2))
                                    }
                                    if group.runs.count > 8 {
                                        Text("还有 \(group.runs.count - 8) 个任务，在标题下拉框里切换").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                                            .padding(.leading, 30)
                                    }
                                }
                            }
                            if recent.contains(where: \.status.isTerminal) {
                                Button("归档全部已结束任务") {
                                    model.perform { for run in recent where run.status.isTerminal { try model.store.setArchived(run.id, true) } }
                                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.listStyle(.sidebar)
                    .focusable()
                    .focusEffectDisabled()
                    .onMoveCommand { direction in
                        let all = RelayNav.primary + [.page(.settings)]
                        guard let index = all.firstIndex(of: model.nav) else { return }
                        switch direction {
                        case .up: model.go(all[max(all.startIndex, index - 1)])
                        case .down: model.go(all[min(all.endIndex - 1, index + 1)])
                        default: break
                        }
                    }
                navRow(.page(.settings), title: "设置").padding(.horizontal, 18)
                Button { model.present("personal", width: 940) { RelayPersonalPanel(model: model) } } label: {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Label { Text("本机工作空间") } icon: { DravionIcon(name: "desktop", size: 15) }.font(.system(size: 12, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    let runs = model.store.state.runs
                    let working = runs.filter { $0.status.isWorking && $0.waitingForSession == nil }.count
                    let queued = runs.filter { $0.status == .queued }.count
                    let waiting = runs.filter { $0.status == .paused && $0.pause?.automatic == true }.count
                    HStack(spacing: 6) {
                        Circle().fill(working > 0 ? Color(red: 0.16, green: 0.62, blue: 0.38) : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                        Text(working > 0 ? "调度器运转中" : "调度器空闲").font(.system(size: 11, weight: .medium))
                    }
                    Text("\(working) 执行 · \(queued) 排队 · \(waiting) 等待 · \(model.store.state.projects.count) 个项目")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(12).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(8).help("技能、记忆库与归档任务")
                .accessibilityIdentifier("personal-panel")
            }.navigationSplitViewColumnWidth(min: 210, ideal: 224, max: 260)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Text(model.showsWorkbench ? model.nav.title : RelayNav.settingsPages.contains(model.section) ? "设置 · \(model.section.rawValue)"
                         : model.section == .thread ? "\(model.selectedRun?.project.name ?? "项目") / 会话" : model.section.rawValue).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    if model.section != .usage { RelayQuotaPills(model: model) }
                    if model.scanning { ProgressView().controlSize(.small) }
                    Button { RelayQuotaFeed.refreshNow(model); model.refreshSessions() } label: { Image(systemName: "arrow.clockwise") }
                        .help("立即刷新账户额度，并刷新客户端项目与会话").disabled(model.scanning)
                }.buttonStyle(.borderless).padding(.horizontal, 28).padding(.vertical, 14)
                Divider().opacity(0.45)
                if let failure = model.error ?? model.store.lastError {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text(failure).font(.system(size: 12)).textSelection(.enabled).lineLimit(4)
                        Spacer()
                        Button { model.error = nil; model.store.lastError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding(12).background(Color.red.opacity(0.07))
                    .modifier(RelayAutoDismiss(key: failure, seconds: 10) { model.error = nil; model.store.lastError = nil })
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let notice = model.notice {
                    HStack(alignment: .top) {
                        Image(systemName: "info.circle").foregroundStyle(RelayStyle.accent)
                        Text(notice).font(.system(size: 12)).textSelection(.enabled).lineLimit(4)
                        Spacer()
                        Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding(12).background(RelayStyle.accent.opacity(0.06))
                    .modifier(RelayAutoDismiss(key: notice, seconds: 6) { model.notice = nil })
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if model.showsWorkbench, let workbench = model.workbench {
                    // Collaboration pages fill the window like the chat: each keeps its own lists, scroll and composer.
                    RelayWorkbenchContent(model: workbench).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.section == .thread {
                    if let run = model.selectedRun { RelayRunThread(model: model, run: run).id(run.id) }
                    else { RelayEmpty(symbol: "bubble.left.and.text.bubble.right", title: "任务已不在", detail: "它可能已被归档或删除。").frame(maxHeight: .infinity) }
                } else if model.section == .knowledge {
                    RelayKnowledgeView(model: model)
                } else {
                HStack(spacing: 0) {
                if RelayNav.settingsPages.contains(model.section) { settingsList; Divider() }
                ScrollView {
                    Group {
                        switch model.section {
                        case .dashboard: RelayDashboard(model: model)
                        case .knowledge: EmptyView()
                        case .projects: RelayProjectsView(model: model)
                        case .connectors: RelayConnectionsView(model: model)
                        case .policies: RelayPoliciesView(model: model)
                        case .usage: RelayUsageView(model: model)
                        case .settings: RelayRoutingView(model: model)
                        case .automation: RelayAutomationView(model: model)
                        case .business: RelayBusinessView(model: model)
                        case .thread: EmptyView()
                        }
                    }.padding(28).frame(maxWidth: 1400).frame(maxWidth: .infinity)
                }.background(RelayStyle.canvas)
                }
                // The note to the team stays at the bottom of the window; the page scrolls above it.
                // Always there, whatever the run's state: it answers, continues a failed run or starts a follow-up.
                if !model.showsWorkbench, model.section == .dashboard, let run = model.dashboardRun {
                    RelayInstructionBar(model: model, run: run).id(run.id)
                        .padding(.horizontal, 28).padding(.vertical, 12).frame(maxWidth: 1400).frame(maxWidth: .infinity)
                        .background(RelayStyle.canvas)
                        .overlay(alignment: .top) { Divider().opacity(0.6) }
                }
                // The live status bar: latest log line, every employee's state; expands into recent log + cards.
                if !model.showsWorkbench, model.section == .dashboard, let run = model.dashboardRun {
                    RelayActivityBar(model: model, run: run)
                }
                }
            }
        }
        .tint(RelayStyle.action)
        .overlay { RelayOverlayHost(model: model) }
        .modifier(RelayAttentionWatcher(model: model))

    }

    /// One outer sidebar row.
    private func navRow(_ item: RelayNav, title: String? = nil) -> some View {
        let selected = model.nav == item
        return Button { model.go(item) } label: {
            // Ink icons drawn as plain views, not a Label's icon: the sidebar list tints Label icons
            // with the system accent (blue). The selected row is a soft raised pill, as in Codex.
            HStack(spacing: 0) {
                RelaySidebarItem(icon: item.icon, title: title ?? item.title, selected: selected)
                if item == .work(.inbox), let workbench = model.workbench, case let count = RelayWorkbenchInbox.pending(workbench.host), count > 0 {
                    RelayBadge(text: "\(count)", color: RelayStyle.accent).padding(.leading, -44)
                }
            }
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 2, bottom: 1, trailing: 2))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("nav-\(item.icon)")
    }

    /// The inner level of 设置: configuration and resources, one page at a time.
    private var settingsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("设置").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 6)
            ForEach(RelayNav.settingsPages, id: \.self) { page in
                Button { model.go(.page(page)) } label: { RelaySidebarItem(icon: page.icon, title: page.rawValue, selected: model.section == page) }
                    .buttonStyle(.plain).accessibilityAddTraits(model.section == page ? .isSelected : [])
            }
            Spacer()
        }.padding(.horizontal, 10).padding(.vertical, 16).frame(width: 200).background(Color.primary.opacity(0.02))
    }
}

struct RelayDashboard: View {
    @Bindable var model: RelayAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var switching = false
    @State private var width: CGFloat = 1000
    @State private var showsBudget = false
    @AppStorage("dashboard.outputExpanded") private var outputExpanded = false
    /// 流程画布 (R40, Lancer-style) by default; the original node graph stays one click away.
    @AppStorage("dashboard.flowView") private var flowView = "canvas"
    private var run: RelayRun? { model.dashboardRun }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let run {
                if width >= 1080 {
                    HStack(alignment: .center, spacing: 12) {
                        RelayRunSwitcher(model: model, current: run).layoutPriority(1)
                        Spacer(minLength: 8)
                        stats(run)
                        RelayBadge(text: run.activityLabel, color: RelayStyle.status(run.status))
                    }
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        RelayRunSwitcher(model: model, current: run)
                        Spacer(minLength: 8)
                        RelayBadge(text: run.activityLabel, color: RelayStyle.status(run.status))
                    }
                    HStack(spacing: 8) { stats(run); Spacer(minLength: 0) }
                }
                runDetail(run)
                    .id(run.id)
                    .transition(.opacity.combined(with: .offset(y: 10)))
            } else {
                VStack(spacing: 22) {
                    DravionMark(size: 44, fill: .gradient).padding(.top, 36)
                    Text("今天想完成什么？").font(.system(size: 26, weight: .semibold))
                    RelayPromptBox(model: model)
                    HStack(spacing: 8) {
                        ForEach(["规划与分发", "执行任务", "实际测试", "复审交付"], id: \.self) { step in
                            Text(step).font(.system(size: 11)).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.vertical, 5).background(RelayStyle.sunken, in: Capsule())
                        }
                    }
                }.frame(maxWidth: 760).frame(maxWidth: .infinity)
                VStack(spacing: 10) {
                    setupRow("cpu", "连接你的模型", "沿用客户端账号，或添加自己的 API。", .connectors)
                    setupRow("folder-simple", "选择工作项目", "读取原有项目与会话，保留当前进度。", .projects)
                    setupRow("sliders-horizontal", "决定谁来调度", "各阶段、默认模型和恢复规则都由你设定。", .settings)
                }.frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: run?.id)
        .onChange(of: run?.id) { _, id in
            if let id { model.perform { _ = try model.store.loadEvents(id, fullHistory: true) } }
        }.onAppear { if let run { model.perform { _ = try model.store.loadEvents(run.id, fullHistory: true) } } }
    }
    private func setupRow(_ icon: String, _ title: String, _ detail: String, _ section: RelaySection) -> some View {
        Button { model.section = section } label: {
            HStack(spacing: 14) {
                RelayIconTile(icon: icon)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    @ViewBuilder private func budgetButtons(_ run: RelayRun) -> some View {
        ForEach([30, 60, 120], id: \.self) { minutes in
            Button("追加 \(RelayCountdown.short(Double(minutes * 60)))") { model.perform { try model.scheduler.extendBudget(run.id, minutes: minutes) } }
        }
        Button("不限时") { model.perform { try model.scheduler.extendBudget(run.id, minutes: nil) } }
    }
    private func openTask(_ runID: String, _ taskID: String) {
        model.present("task-\(taskID)", width: 860) { RelayTaskDetail(model: model, runID: runID, taskID: taskID) }
    }

    /// The four numbers as small chips beside the title; each opens its details above the page. The milestone chip
    /// is the roadmap's widget: a ring and the current stage.
    @ViewBuilder private func stats(_ run: RelayRun) -> some View {
        let calls = run.callRecords ?? []
        let milestones = run.displayMilestones
        let doneStages = milestones.filter { $0.status == .done }.count
        let id = run.id
        HStack(spacing: 8) {
            RelayStatChip(title: "子任务", value: "\(run.finishedTasks)/\(run.tasks.count)", color: RelayPalette.ember,
                          help: run.tasks.contains { $0.status == .running } ? "\(run.tasks.filter { $0.status == .running }.count) 个执行中" : run.phase.label) {
                model.present("tasks", width: 720) { RelayTasksPanel(model: model, runID: id) }
            }
            RelayStatChip(title: run.activeMilestone.flatMap { run.milestones?[$0].title } ?? "里程碑",
                          value: milestones.isEmpty ? "—" : "\(doneStages)/\(milestones.count)", color: RelayPalette.violet,
                          help: run.milestones == nil ? (milestones.isEmpty ? "等待拆分方案" : "单阶段任务：完成目标") : "点击查看路线图",
                          progress: milestones.isEmpty ? nil : Double(doneStages) / Double(milestones.count)) {
                model.present("milestones", width: 640) { RelayMilestonesPanel(model: model, runID: id) }
            }
            RelayStatChip(title: "Token", value: RelayTokens.number(run.totalTokens), color: RelayPalette.teal,
                          help: "缓存命中 \(Int((run.cacheHitRate * 100).rounded()))%") {
                model.present("tokens", width: 640) { RelayTokenPanel(model: model, runID: id) }
            }
            RelayStatChip(title: "调用", value: "\(calls.count)", color: RelayPalette.green,
                          help: "\(calls.filter { $0.status == .failed }.count) 次失败 · \(Set(calls.map(\.roleID)).count) 位员工") {
                model.present("calls", width: 720) { RelayCallsPanel(model: model, runID: id) }
            }
        }
    }

    /// Run time on the left; the log and the run controls on the right.
    @ViewBuilder private func controls(_ run: RelayRun) -> some View {
        let id = run.id
        let live = run.status.isWorking && run.waitingForSession == nil
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let seconds = Int(run.elapsed(at: timeline.date))
                Label {
                    Text("有效运行 \(seconds / 60) 分 \(seconds % 60) 秒" + (run.input.budgetMinutes > 0 ? " / 预算 \(RelayCountdown.short(Double(run.input.budgetMinutes * 60)))" : " · 不限时"))
                        .monospacedDigit()
                } icon: { DravionIcon(name: "clock-countdown", size: 14) }
                .foregroundStyle(run.input.budgetMinutes > 0 && Double(seconds) >= Double(run.input.budgetMinutes * 60) * 0.9 ? .orange : .secondary)
            }
            Spacer()
            Button {
                model.present("log", style: .drawer, width: 760) { RelayRunLogPanel(model: model, runID: id) }
            } label: {
                HStack(spacing: 6) {
                    if live { RelayPulseDot(color: RelayStyle.accent, size: 5) }
                    DravionIcon(name: "terminal-window", size: 13)
                    Text("执行记录")
                    Text("\((model.store.events[id] ?? []).count)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .help("实时查看执行记录（⇧⌘L）").accessibilityIdentifier("open-run-log")
            if !waitingCard(run) {
                if !run.status.isTerminal { RelayCurrentCallChip(model: model, run: run) }
                actions(run, captions: false)
            }
        }.font(.system(size: 12)).buttonStyle(.bordered)
    }

    /// Things waiting on the user, in the order they block the run.
    @ViewBuilder private func attention(_ run: RelayRun) -> some View {
        let denied = RelaySandboxHint.directories(for: run, events: model.store.events[run.id] ?? [])
        if !denied.isEmpty { RelaySandboxCard(model: model, run: run, directories: denied) }
        if let question = run.pendingQuestion { RelayQuestionCard(model: model, run: run, question: question).id(question.id) }
        if run.externalTurnUnconfirmed == true { RelayExternalTurnCard(model: model, run: run) }
        if run.pause?.reason == .awaitingGoal {
            HStack(spacing: 12) {
                RelayIconTile(icon: "chats-circle")
                VStack(alignment: .leading, spacing: 3) {
                    Text("任务已建好，等你说要做什么").font(.system(size: 13, weight: .semibold))
                    Text("在页面底部写下你想完成什么，发送后总调度开始规划；之后发的消息都是补充要求。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityIdentifier("awaiting-goal")
        }
        if run.pause?.reason == .milestone, run.status == .paused {
            RelayMilestoneConfirmCard(model: model, run: run).id(run.nextMilestone)
        } else if let pause = run.pause, pause.reason == .budget, run.status == .paused {
            RelayCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("时间预算已用完，已在步骤之间暂停", systemImage: "hourglass").foregroundStyle(.orange).font(.headline)
                    Text(pause.message).font(.system(size: 13)).textSelection(.enabled)
                    HStack(spacing: 8) {
                        budgetButtons(run)
                        Spacer()
                        Button("到此结束", role: .destructive) { model.perform { try model.scheduler.stop(run.id) } }
                    }.buttonStyle(.bordered).font(.system(size: 12))
                }
            }
        } else if let pause = run.pause, waitingCard(run) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "pause.circle.fill").foregroundStyle(.orange).font(.system(size: 15))
                VStack(alignment: .leading, spacing: 3) {
                    Text("任务等待恢复").font(.system(size: 13, weight: .semibold))
                    Text(pause.message).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                    if let date = pause.resumeAt, pause.automatic {
                        Text("下次尝试：\(date.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary)
                    }
                    if pause.reason == .sessionLimit, model.scheduler.seatConflict(run.id) != nil {
                        Button("查看详情") {
                            model.present("seat-\(run.id)", width: 600) { RelaySeatConflictPanel(model: model, runID: run.id) }
                        }
                        .buttonStyle(.link).font(.system(size: 12, weight: .medium)).padding(.top, 2)
                        .accessibilityIdentifier("seat-conflict-details")
                    }
                }
                Spacer(minLength: 12)
                RelayCurrentCallChip(model: model, run: run)
                actions(run, captions: true)
            }
            .padding(14)
            .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.orange.opacity(0.2)))
        }
        if let error = run.error {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(error).font(.system(size: 12)).textSelection(.enabled).lineLimit(6)
                Spacer()
            }
            .padding(14)
            .background(Color.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.red.opacity(0.18)))
        }
    }

    private func budgetPopover(_ run: RelayRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("运行时间").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 6) { budgetButtons(run) }.buttonStyle(.bordered).font(.system(size: 12))
            Text("到时只在步骤之间暂停，不会打断正在进行的调用。").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(14)
        .simultaneousGesture(TapGesture().onEnded { showsBudget = false })
    }

    /// The "任务等待恢复" card is up, and carries the run controls itself.
    private func waitingCard(_ run: RelayRun) -> Bool {
        run.pause != nil && run.pause?.reason != .milestone && run.pause?.reason != .awaitingGoal && !(run.pause?.reason == .budget && run.status == .paused)
            && run.pendingQuestion == nil && run.externalTurnUnconfirmed != true
    }

    /// Run controls as round icon buttons: what applies to the run's state, the destructive one last.
    /// With captions (inside the waiting card) each icon carries its name underneath.
    @ViewBuilder private func actions(_ run: RelayRun, captions: Bool) -> some View {
        let blocked = run.pendingQuestion != nil || run.externalTurnUnconfirmed == true
        HStack(spacing: captions ? 14 : 8) {
            if !run.status.isTerminal {
                RelayIconAction(symbol: "timer", title: "时间", captions: captions) { showsBudget = true }
                    .help("追加时间或取消时限；到时只在步骤之间暂停")
                    .popover(isPresented: $showsBudget, arrowEdge: .bottom) { budgetPopover(run) }
            }
            if (run.status == .paused || run.status == .interrupted) && run.pause?.reason != .awaitingGoal {
                RelayIconAction(symbol: "arrow.triangle.2.circlepath", title: "切换接入", captions: captions) { switching = true }
                    .disabled(blocked)
                RelayIconAction(symbol: "play.fill", title: "继续", prominent: true, captions: captions) {
                    model.perform { try model.scheduler.resume(run.id) }
                }.disabled(blocked).accessibilityIdentifier("resume-run")
            } else if !run.status.isTerminal {
                RelayIconAction(symbol: "pause.fill", title: "暂停", captions: captions) {
                    model.perform { try model.scheduler.pause(run.id) }
                }.accessibilityIdentifier("pause-run")
            }
            if !run.status.isTerminal {
                RelayIconAction(symbol: "stop.fill", title: "停止", tint: .red, captions: captions) {
                    model.perform { try model.scheduler.stop(run.id) }
                }.disabled(run.externalTurnUnconfirmed == true)
            } else {
                if run.status == .budgetExceeded {
                    RelayIconAction(symbol: "timer", title: "追加时间继续", prominent: true, captions: captions) { showsBudget = true }
                        .help("从已完成的步骤继续，不重新规划")
                        .popover(isPresented: $showsBudget, arrowEdge: .bottom) { budgetPopover(run) }
                }
                if run.status == .failed {
                    RelayIconAction(symbol: "arrow.uturn.forward", title: "从失败处继续", prominent: true, captions: captions) {
                        model.perform { try model.scheduler.continueFailed(run.id) }
                    }
                    .help("保留已完成的步骤、会话和文件，只重做失败的这一步；“重新运行”会从头规划")
                    .accessibilityIdentifier("continue-failed")
                }
                RelayIconAction(symbol: "arrow.clockwise", title: "重新运行", captions: captions) {
                    Task { do { model.selectRun(try await model.scheduler.retry(run.id).id) } catch { model.error = error.localizedDescription } }
                }
            }
        }
    }

    /// Order of the page, most needed first: progress at a glance, what waits on you, who is working on what and the
    /// step list; the graph, the final output and the details behind each tile fold away.
    @ViewBuilder private func runDetail(_ run: RelayRun) -> some View {
        let wide = width >= 920
        controls(run)
        attention(run)
        if !run.status.isTerminal { RelayLiveAgentBanner(model: model, run: run) }
        workCard(run, wide: wide)
        if !run.output.isEmpty {
            RelayFoldCard(title: "完成输出", summary: "\(run.output.components(separatedBy: "\n").count) 行", icon: "file-code", expanded: $outputExpanded) {
                RelayCodeOutput(text: run.output)
            }
        }
        Color.clear.frame(height: 0)
            .sheet(isPresented: $switching) { RelaySwitchSheet(model: model, run: run) }
    }

    /// The graph and the task steps in one card, side by side, so the whole run is seen without scrolling the page.
    /// Clicking a node opens its details above the page.
    @ViewBuilder private func workCard(_ run: RelayRun, wide: Bool) -> some View {
        let runID = run.id
        let nodes = Binding<RelayNodeKey?>(get: { nil }, set: { key in
            guard let key else { return }
            model.present("node-\(key.stage.rawValue)-\(key.roleID ?? "local")", width: 900) { RelayNodePanel(model: model, runID: runID, key: key) }
        })
        let executors = Set((run.input.directRoleID.map { [$0] } ?? run.input.executorIDs) + run.tasks.map(\.task.roleId)).count
        let graphHeight = CGFloat(max(1, executors)) * 132 + 24
        RelayCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("执行图谱与任务步骤").font(.system(size: 15, weight: .semibold))
                    Text(flowView == "canvas" ? "点分支看子任务详情 · 连线流动表示正在执行" : "点节点看文件和记录 · 点模型标签可更换模型 · 右键可修改、更换、移出员工")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                    Picker("", selection: $flowView) { Text("流程画布").tag("canvas"); Text("节点图").tag("graph") }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                    if !run.status.isTerminal {
                        Button {
                            model.present("add-member", width: 560) { RelayAddMemberPanel(model: model, runID: runID) }
                        } label: { Label("加入员工", systemImage: "person.badge.plus") }
                            .buttonStyle(.bordered).font(.system(size: 12))
                            .disabled(run.plan == nil || run.pause?.reason == .milestone)
                            .help(run.plan == nil ? "总调度拆完方案后才能加入员工" : "临时拉一位员工进来，分给他一项子任务")
                            .accessibilityIdentifier("add-member")
                    }
                }.padding(.horizontal, 20).padding(.vertical, 14)
                Divider().opacity(0.5)
                if flowView == "canvas" {
                    ScrollView(.horizontal, showsIndicators: false) {
                        RelayFlowCanvas(model: model, run: run) { openTask(runID, $0) }.frame(minWidth: 1000)
                    }
                } else if wide {
                    // No inner scrolling: the card is as tall as the longer of the two, the graph stays in view at
                    // the top while the steps run on below it.
                    HStack(alignment: .top, spacing: 0) {
                        RelayPipelineView(model: model, run: run, events: model.store.events[run.id] ?? [], selected: nodes, compact: true)
                            .frame(height: graphHeight)
                            .padding(16).frame(maxWidth: .infinity, alignment: .top)
                        Divider().opacity(0.5)
                        RelayTaskStepper(run: run, framed: false) { openTask(runID, $0) }.padding(18)
                            .frame(width: width >= 1200 ? 440 : 380, alignment: .top)
                    }.fixedSize(horizontal: false, vertical: true)
                } else {
                    RelayPipelineView(model: model, run: run, events: model.store.events[run.id] ?? [], selected: nodes, compact: true).padding(16)
                    Divider().opacity(0.5)
                    RelayTaskStepper(run: run, framed: false) { openTask(runID, $0) }.padding(18)
                }
            }
        }
    }

    private func graphSummary(_ run: RelayRun) -> String {
        let executors = run.input.directRoleID.map { [$0] } ?? run.input.executorIDs
        return "\(executors.count + 3) 个节点 · 当前：\(run.status.isTerminal ? run.status.label : run.phase.label)"
    }
}

/// A card whose body folds away; the header still says what is inside. The open state is remembered.
struct RelayFoldCard<Content: View>: View {
    var title: String
    var summary: String
    var icon: String
    @Binding var expanded: Bool
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        RelayCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.9)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        DravionIcon(name: icon, size: 15).foregroundStyle(.secondary)
                        Text(title).font(.system(size: 14, weight: .semibold))
                        Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(expanded ? "收起" : "展开").font(.system(size: 11)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if expanded {
                    Divider().opacity(0.5)
                    content.padding(18).transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

/// The current task as a dropdown: its title is the page title; the menu lists every task grouped by project,
/// with status and age, so switching tasks never takes a row of tabs.
struct RelayRunSwitcher: View {
    @Bindable var model: RelayAppModel
    let current: RelayRun
    @State private var hovering = false
    private var groups: [(project: RelayProject, runs: [RelayRun])] {
        var order: [String] = []
        var grouped: [String: [RelayRun]] = [:]
        for run in model.store.state.runs where run.archivedAt == nil || run.id == current.id {
            if grouped[run.project.id] == nil { order.append(run.project.id) }
            grouped[run.project.id, default: []].append(run)
        }
        return order.compactMap { id in
            guard let runs = grouped[id], let first = runs.first else { return nil }
            return (model.store.state.projects.first { $0.id == id } ?? first.project, runs)
        }
    }
    var body: some View {
        let all = groups
        Menu {
            ForEach(all, id: \.project.id) { group in
                Section(group.project.name.isEmpty ? URL(fileURLWithPath: group.project.path).lastPathComponent : group.project.name) {
                    ForEach(group.runs) { run in
                        Toggle(isOn: Binding(get: { run.id == current.id }, set: { _ in model.selectRun(run.id) })) {
                            Label("\(run.input.title)  ·  \(run.activityLabel) · \(RelaySidebarRunRow.age(run.createdAt))前", systemImage: Self.symbol(run))
                        }
                    }
                }
            }
            Divider()
            Button("新建任务…") { model.showsComposer = true }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(current.input.title).font(.system(size: 22, weight: .semibold, design: .rounded)).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 5) {
                        DravionIcon(name: "folder-simple", size: 12)
                        Text(current.project.name.isEmpty ? current.project.path : "\(current.project.name) · \(current.project.path)")
                            .lineLimit(1).truncationMode(.middle)
                        let count = all.reduce(0) { $0 + $1.runs.count }
                        let live = all.flatMap(\.runs).filter { $0.status.isWorking }.count
                        Text("· 共 \(count) 个任务" + (live > 0 ? "，\(live) 个进行中" : "")).foregroundStyle(.tertiary)
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
        .padding(.leading, -10)
        .onHover { hovering = $0 }
        .help("切换任务")
        .accessibilityIdentifier("run-switcher")
    }
    private static func symbol(_ run: RelayRun) -> String {
        if run.status.isWorking { return "circle.fill" }
        switch run.status {
        case .succeeded: return "checkmark.circle"
        case .failed, .budgetExceeded: return "xmark.circle"
        case .paused, .interrupted: return "pause.circle"
        default: return "circle.dashed"
        }
    }
}

struct RelayPipelineView: View {
    var model: RelayAppModel? = nil
    var run: RelayRun
    var events: [RelayEvent] = []
    @Binding var selected: RelayNodeKey?
    /// Smaller avatars and rows, for the graph sitting beside the task steps.
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    /// The configured executors plus anyone who joined the run later with a sub-task (`addMember`).
    private var executors: [RelayRole] {
        var ids = run.input.directRoleID.map { [$0] } ?? run.input.executorIDs
        for item in run.tasks where !ids.contains(item.task.roleId) { ids.append(item.task.roleId) }
        return ids.compactMap { id in run.roles.first { $0.id == id } }
    }
    /// Vertical distance between executor nodes; a node (avatar, two text lines, model chip, padding) must fit
    /// in it, or neighbours overlap once a run has more than a few executors.
    private var rowPitch: CGFloat { compact ? 132 : 158 }
    private var height: CGFloat { CGFloat(max(1, executors.count)) * rowPitch + 24 }
    private var testerKey: RelayNodeKey { .init(stage: .testing, roleID: run.phase == .tests ? nil : run.input.testerID) }
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let positions = compact ? [width * 0.13, width * 0.38, width * 0.63, width * 0.87] : [width * 0.12, width * 0.39, width * 0.66, width * 0.89]
            let center = height / 2
            let planner = RelayNodeKey(stage: .planning, roleID: run.input.plannerID)
            let reviewer = RelayNodeKey(stage: .reviewing, roleID: run.input.reviewerID)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reducedMotion || !run.status.isWorking || run.waitingForSession != nil)) { timeline in
                Canvas { context, _ in
                    for (index, role) in executors.enumerated() {
                        let y = rowY(index)
                        let key = RelayNodeKey(stage: .executing, roleID: role.id)
                        drawLink(&context, from: CGPoint(x: positions[0] + 50, y: center), to: CGPoint(x: positions[1] - 60, y: y),
                                 state: link(run.nodeState(planner), run.nodeState(key)), time: timeline.date)
                        drawLink(&context, from: CGPoint(x: positions[1] + 60, y: y), to: CGPoint(x: positions[2] - 50, y: center),
                                 state: link(run.nodeState(key), run.nodeState(testerKey)), time: timeline.date)
                    }
                    drawLink(&context, from: CGPoint(x: positions[2] + 50, y: center), to: CGPoint(x: positions[3] - 50, y: center),
                             state: link(run.nodeState(testerKey), run.nodeState(reviewer)), time: timeline.date)
                }
            }.accessibilityHidden(true)
            node(planner, title: run.input.directRoleID == nil ? "总调度" : "直接分配").position(x: positions[0], y: center)
            ForEach(Array(executors.enumerated()), id: \.element.id) { index, role in
                node(.init(stage: .executing, roleID: role.id), title: "执行 · \(run.tasks.filter { $0.task.roleId == role.id }.count) 个分支")
                    .position(x: positions[1], y: rowY(index))
            }
            node(testerKey, title: run.phase == .tests ? "本机实际测试" : run.input.testerID.isEmpty ? "本机测试 · 未安排质检" : "质量检查").position(x: positions[2], y: center)
            node(reviewer, title: run.input.reviewerID.isEmpty ? "复审 · 未安排" : "复审").position(x: positions[3], y: center)
        }.frame(height: height)
    }
    private func rowY(_ index: Int) -> CGFloat { height / 2 + (CGFloat(index) - CGFloat(executors.count - 1) / 2) * rowPitch }
    /// A link flows while its target works, turns solid once both ends are done, and stays faint otherwise.
    private func link(_ from: RelayNodeState, _ to: RelayNodeState) -> RelayNodeState {
        if to == .active { return .active }
        if from == .done && to == .done { return .done }
        return .pending
    }
    private func node(_ key: RelayNodeKey, title: String) -> some View {
        let role = key.roleID.flatMap { id in run.roles.first { $0.id == id } }
        let state = run.nodeState(key)
        let color = role.map { RelayStyle.color($0.color) } ?? RelayStyle.accent
        let isSelected = selected == key
        let produced = key.stage == .executing ? RelayNodeArtifacts(run: run, key: key, events: events).files.count : 0
        return Button {
            withAnimation(reducedMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) { selected = isSelected ? nil : key }
        } label: {
            VStack(spacing: compact ? 4 : 6) {
                RelayAgentAvatar(icon: RelayNodeInspector.icon(key.stage), color: color, state: state, size: compact ? 40 : 52)
                Text(role?.name ?? title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(state == .active ? state.label : title)
                    if produced > 0 { Text("· \(produced) 文件") }
                }
                .font(.system(size: 10)).foregroundStyle(state == .active ? AnyShapeStyle(RelayStyle.accent) : AnyShapeStyle(.secondary)).lineLimit(1)
                if let model, let role { RelayRoleConfigChip(model: model, run: run, role: role, maxWidth: compact ? 132 : 146) }
            }.padding(compact ? 4 : 8).frame(width: compact ? 138 : 156)
                .background(isSelected ? color.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(isSelected ? color.opacity(0.5) : .clear, lineWidth: 1))
                .scaleEffect(isSelected ? 1.04 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let model, let role, let stage = Self.stage(key.stage), run.status != .cancelled, run.status != .succeeded, run.status != .budgetExceeded {
                let runID = run.id
                Button("修改员工…") {
                    model.present("edit-member-\(role.id)", width: 670) {
                        RelayRoleEditor(model: model, role: role, close: model.dismissOverlay) { edited, asDefault in
                            try await model.scheduler.updateMember(runID, role: edited, saveAsDefault: asDefault)
                        }
                    }
                }
                Menu("更换员工") {
                    ForEach(model.store.state.roles.filter { $0.enabled && $0.id != role.id }) { other in
                        let connection = model.store.state.connections.first { $0.id == other.connectionID }?.name ?? "连接缺失"
                        Button("\(other.name) · \(connection)") { replace(model, stage: stage, from: role.id, to: other.id) }
                    }
                }
                Button("加入员工…") {
                    model.present("add-member", width: 560) { RelayAddMemberPanel(model: model, runID: runID) }
                }.disabled(run.plan == nil)
                Divider()
                Button("移出任务", role: .destructive) {
                    Task {
                        do { model.notice = try await model.scheduler.removeMember(runID, roleID: role.id) }
                        catch { model.error = error.localizedDescription }
                    }
                }
                Divider()
                Text("额度不够、快下班或不在岗时，会自动交给候选员工（在“修改员工”里设置）").font(.caption)
            }
        }
        .animation(reducedMotion ? nil : .easeInOut(duration: 0.45), value: state)
        .accessibilityLabel("\(role?.name ?? title)，\(state.label)")
        .accessibilityIdentifier("pipeline-node-\(key.stage.rawValue)-\(key.roleID ?? "local")")
    }
    private static func stage(_ status: RelayRunStatus) -> RelayStage? {
        switch status {
        case .planning: return .planner
        case .executing: return .executor
        case .testing: return .tester
        case .reviewing: return .reviewer
        default: return nil
        }
    }
    private func replace(_ model: RelayAppModel, stage: RelayStage, from: String, to: String) {
        let id = run.id
        Task {
            do { let message = try await model.scheduler.replaceMember(id, stage: stage, from: from, to: to); if !message.isEmpty { model.notice = message } }
            catch { model.error = error.localizedDescription }
        }
    }
    private func drawLink(_ context: inout GraphicsContext, from: CGPoint, to: CGPoint, state: RelayNodeState, time: Date) {
        var path = Path()
        path.move(to: from)
        let middle = (from.x + to.x) / 2
        path.addCurve(to: to, control1: CGPoint(x: middle, y: from.y), control2: CGPoint(x: middle, y: to.y))
        switch state {
        case .done:
            context.stroke(path, with: .color(Color.green.opacity(0.35)), lineWidth: 1.5)
        case .active where run.waitingForSession == nil:
            context.stroke(path, with: .color(RelayStyle.accent.opacity(0.12)), lineWidth: 4)
            let phase = reducedMotion ? 0 : -CGFloat(time.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10)) * 26
            context.stroke(path, with: .color(RelayStyle.accent.opacity(0.75)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 9], dashPhase: phase))
            // A bright packet travelling along the link toward the working node.
            if !reducedMotion {
                let t = CGFloat(time.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6)
                let trimmed = path.trimmedPath(from: max(0, t - 0.12), to: t)
                context.stroke(trimmed, with: .color(RelayStyle.accent), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        default:
            context.stroke(path, with: .color(Color.primary.opacity(0.09)), lineWidth: 1)
        }
    }
}

/// The prompt box of the empty dashboard (as in Codex): type the goal here, then pick project and roles in the
/// task sheet, which opens with this text.
struct RelayPromptBox: View {
    @Bindable var model: RelayAppModel
    @State private var goal = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("和 Dravion 一起工作：描述目标，总调度会拆分并交给你的团队", text: $goal, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(3...8).focused($focused)
                .onSubmit(send).accessibilityIdentifier("prompt-goal")
            HStack(spacing: 14) {
                Button { model.draftGoal = goal; model.showsComposer = true } label: { Image(systemName: "plus") }
                    .help("附件、项目与角色")
                Spacer()
                Button { model.draftGoal = goal; model.draftDictation = true; model.showsComposer = true } label: { Image(systemName: "mic") }
                    .help("语音输入")
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(goal.isEmpty ? Color.secondary.opacity(0.35) : RelayStyle.action, in: Circle())
                }.disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.return, modifiers: .command)
            }.buttonStyle(.plain).font(.system(size: 15)).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(focused ? Color.primary.opacity(0.22) : RelayStyle.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
        .onAppear { focused = true }
    }
    private func send() {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.draftGoal = goal; goal = ""; model.showsComposer = true
    }
}

/// A round icon button for run controls; with captions, its name sits underneath.
struct RelayIconAction: View {
    var symbol: String
    var title: String
    var tint: Color = .primary
    var prominent = false
    var captions = false
    var action: () -> Void
    var body: some View {
        Button(action: action) { RelayIconActionLabel(symbol: symbol, title: title, tint: tint, prominent: prominent, captions: captions) }
            .buttonStyle(.plain).help(title)
    }
}

struct RelayIconActionLabel: View {
    var symbol: String
    var title: String
    var tint: Color = .primary
    var prominent = false
    var captions = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: captions ? 13 : 12, weight: .semibold))
                .foregroundStyle(prominent ? Color(nsColor: .textBackgroundColor) : tint)
                .frame(width: captions ? 36 : 30, height: captions ? 36 : 30)
                .background(prominent ? AnyShapeStyle(RelayStyle.action) : AnyShapeStyle(tint.opacity(hovering ? 0.14 : 0.07)), in: Circle())
                .overlay(Circle().stroke(prominent ? .clear : tint.opacity(0.18)))
                .scaleEffect(hovering && enabled ? 1.06 : 1)
            if captions { Text(title).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize() }
        }
        .opacity(enabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(title)
    }
}

/// A recent task in the sidebar. On hover, as in Codex, an archive button appears at the right end of the row
/// (in place of the age); a task still running has to be stopped first.
struct RelaySidebarRunRow: View {
    let model: RelayAppModel
    let run: RelayRun
    @State private var hovering = false
    @State private var archiving = false
    var body: some View {
        let selected = model.section == .thread && model.selectedRunID == run.id
        HStack(spacing: 8) {
            if run.status.isWorking && run.waitingForSession == nil { RelayPulseDot(color: RelayStyle.status(run.status)) }
            else { Circle().fill(RelayStyle.status(run.status)).frame(width: 6, height: 6) }
            Text(run.input.title).font(.system(size: 12.5)).lineLimit(1).foregroundStyle(Color.primary.opacity(0.85))
            Spacer(minLength: 4)
            if hovering {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { archiving = true }
                    model.perform { try model.store.setArchived(run.id, true) }
                } label: {
                    Image(systemName: "archivebox").font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(run.status.isTerminal ? .secondary : .tertiary)
                .disabled(!run.status.isTerminal)
                .help(run.status.isTerminal ? "归档（可在“本机工作空间 → 归档任务”中找回）" : "进行中的任务需先停止才能归档")
                .transition(.opacity)
            } else if RelayAttention.kind(run, events: model.store.events[run.id] ?? []) != nil {
                // Needs a person: a dark “待确认” pill instead of the age (user request, 2026-11-01).
                HStack(spacing: 4) {
                    Text("待确认").font(.system(size: 10.5, weight: .semibold))
                    Circle().frame(width: 5, height: 5)
                }
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .padding(.horizontal, 7).padding(.vertical, 2.5)
                .background(Color.primary.opacity(0.85), in: Capsule())
                .help("这个任务在等你确认，点开处理")
            } else {
                Text(Self.age(run.createdAt)).font(.system(size: 10.5)).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .padding(.vertical, 4).padding(.leading, 8).padding(.trailing, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? RelayStyle.sidebarSelection : hovering ? Color.primary.opacity(0.05) : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.openThread(run.id) }
        .onHover { hovering = $0 }
        .opacity(archiving ? 0 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button("归档") { model.perform { try model.store.setArchived(run.id, true) } }.disabled(!run.status.isTerminal)
            if !run.status.isTerminal { Text("进行中的任务需先停止才能归档") }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("recent-run-\(run.id)")
    }
    /// "3分" / "2时" / "4天", as Codex shows the age of a thread.
    static func age(_ date: Date) -> String {
        let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
        if minutes < 60 { return "\(max(1, minutes))分" }
        if minutes < 1440 { return "\(minutes / 60)时" }
        return "\(minutes / 1440)天"
    }
}

/// One section row of the sidebar: ink icon, title, and a raised pill when selected.
struct RelaySidebarItem: View {
    var icon: String
    var title: String
    var selected: Bool
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 9) {
            DravionIcon(name: icon, duotone: selected, size: 17)
                .foregroundStyle(Color.primary.opacity(selected ? 0.9 : 0.72))
                .frame(width: 20)
            Text(title).font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(Color.primary.opacity(selected ? 1 : 0.82))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6).padding(.horizontal, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Color.primary.opacity(0.085), Color.primary.opacity(0.065)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.05), radius: 1, y: 0.5)
            } else if hovering {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

enum RelaySidebarProjects {
    /// Unarchived runs grouped by project folder, the project with the newest run first.
    static func groups(_ state: RelayState, runs: [RelayRun]) -> [(project: RelayProject, runs: [RelayRun])] {
        var order: [String] = []
        var grouped: [String: [RelayRun]] = [:]
        for run in runs.sorted(by: { $0.createdAt > $1.createdAt }) {
            if grouped[run.project.id] == nil { order.append(run.project.id) }
            grouped[run.project.id, default: []].append(run)
        }
        let active = order.compactMap { id -> (project: RelayProject, runs: [RelayRun])? in
            guard let runs = grouped[id], let first = runs.first else { return nil }
            return (state.projects.first { $0.id == id } ?? first.project, runs)
        }
        // Folders without tasks yet are listed too (as in Codex), after those with work.
        return active + state.projects.filter { project in !order.contains(project.id) }.map { ($0, []) }
    }
}

/// A project (folder) heading in the sidebar: folder icon, name, count, a live dot; click folds its tasks.
/// On hover a "+" starts a new task in this folder.
struct RelaySidebarProjectRow: View {
    let model: RelayAppModel
    let project: RelayProject
    let runs: [RelayRun]
    @AppStorage("sidebar.collapsedProjects") private var collapsedRaw = ""
    @State private var hovering = false
    @State private var confirmingDelete = false
    private var collapsed: Bool { collapsedRaw.split(separator: ",").contains { $0 == project.id } }
    var body: some View {
        HStack(spacing: 7) {
            DravionIcon(name: collapsed ? "folder-simple" : "folder-open", size: 15).foregroundStyle(Color.primary.opacity(0.7))
            Text(project.name.isEmpty ? URL(fileURLWithPath: project.path).lastPathComponent : project.name)
                .font(.system(size: 12.5, weight: .medium)).lineLimit(1).foregroundStyle(Color.primary)
            if runs.contains(where: { $0.status.isWorking && $0.waitingForSession == nil }) { RelayPulseDot(color: RelayStyle.accent, size: 5) }
            Spacer(minLength: 4)
            if hovering {
                Button {
                    model.draftProjectID = project.id
                    model.showsComposer = true
                } label: { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 20, height: 20) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("在这个项目里新建任务")
            } else {
                Text("\(runs.count)").font(.system(size: 10.5)).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(hovering ? Color.primary.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            var set = Set(collapsedRaw.split(separator: ",").map(String.init))
            if set.contains(project.id) { set.remove(project.id) } else { set.insert(project.id) }
            withAnimation(.easeInOut(duration: 0.2)) { collapsedRaw = set.sorted().joined(separator: ",") }
        }
        .onHover { hovering = $0 }
        .help(project.path)
        .contextMenu {
            Button("在这个项目里新建任务") { model.draftProjectID = project.id; model.showsComposer = true }
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)]) }
            Divider()
            Button("归档已结束的任务") {
                model.perform { for run in runs where run.status.isTerminal { try model.store.setArchived(run.id, true) } }
            }.disabled(!runs.contains { $0.status.isTerminal })
            Button("删除项目…", role: .destructive) { confirmingDelete = true }
                .disabled(runs.contains { !$0.status.isTerminal })
            if runs.contains(where: { !$0.status.isTerminal }) { Text("还有未结束的任务，先停止后才能删除") }
        }
        .confirmationDialog("删除项目「\(project.name)」？", isPresented: $confirmingDelete) {
            Button("删除项目", role: .destructive) {
                model.perform {
                    for run in model.store.state.runs where run.project.id == project.id && run.archivedAt == nil { try model.store.setArchived(run.id, true) }
                    try model.store.deleteProject(project.id)
                    if model.selectedRun?.project.id == project.id { model.selectedRunID = nil }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("它的 \(runs.count) 个任务会被归档，可在“本机工作空间 → 归档任务”中找回。文件夹 \(project.path) 里的文件不会被删除。")
        }
    }
}

extension RelayAppModel {
    /// The run the dashboard shows: the one picked, else the newest unarchived.
    var dashboardRun: RelayRun? { selectedRun ?? store.state.runs.first { $0.archivedAt == nil } }
}

/// A small number chip for the title row: tinted dot (or ring), value, label; opens its details.
struct RelayStatChip: View {
    var title: String
    var value: String
    var color: Color
    var help: String = ""
    var progress: Double? = nil
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let progress {
                    ZStack {
                        Circle().stroke(color.opacity(0.18), lineWidth: 2.5)
                        Circle().trim(from: 0, to: max(0.02, progress)).stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                    }.frame(width: 14, height: 14)
                } else {
                    RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: 16)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
                    Text(title.count > 8 ? title.prefix(8) + "…" : title).font(.system(size: 10)).foregroundStyle(color).lineLimit(1)
                }.fixedSize()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(hovering ? 0.13 : 0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(color.opacity(0.16)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .help(help.isEmpty ? "查看\(title)详情" : help + " · 点击查看详情")
        .accessibilityIdentifier("stat-\(title)")
    }
}

/// The current call in one line (employee, model, state); the full identity opens in a popover.
struct RelayCurrentCallChip: View {
    let model: RelayAppModel
    let run: RelayRun
    @State private var open = false
    var body: some View {
        if let role = run.roles.first(where: { $0.id == run.currentRoleID }) {
            let connection = run.connections.first { $0.id == role.connectionID }
            let effective = model.effectiveModel(role, connection: connection)
            let call = run.callRecords?.last { $0.roleID == role.id && $0.taskID == run.currentTaskID }
            let color = RelayStyle.color(role.color)
            Button { open = true } label: {
                HStack(spacing: 6) {
                    if call?.status == .running && run.waitingForSession == nil { RelayPulseDot(color: color, size: 5) }
                    else { Circle().fill(color).frame(width: 6, height: 6) }
                    Text(role.name).fontWeight(.medium).lineLimit(1)
                    Text(call?.reportedModel ?? effective.model).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    if let call { Text(run.waitingForSession == nil ? call.status.label : "等待名额").foregroundStyle(.secondary) }
                }
                .font(.system(size: 11))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Color.primary.opacity(0.05), in: Capsule())
                .overlay(Capsule().stroke(RelayStyle.border))
                .frame(maxWidth: 300)
            }
            .buttonStyle(.plain).help("当前调用：点击查看模型、思考级别和会话")
            .popover(isPresented: $open, arrowEdge: .bottom) { RelayRunIdentity(model: model, run: run).frame(width: 360) }
        }
    }
}

/// The note to the team, pinned at the bottom of the dashboard: text, recipient, send.
struct RelayInstructionBar: View {
    let model: RelayAppModel
    let run: RelayRun
    @State private var instruction = ""
    @State private var recipient = ""
    @FocusState private var focused: Bool
    var body: some View {
        let empty = instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let needsGoal = run.pause?.reason == .awaitingGoal
        let mode = Mode(run)
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "text.bubble").font(.system(size: 14)).foregroundStyle(.secondary)
            TextField(mode.placeholder, text: $instruction, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...5)
                .focused($focused).onSubmit(send)
                .frame(minHeight: 22)
            if mode == .instruct || mode == .continueFailed {
                RelayPillMenu(title: run.roles.first { $0.id == recipient }?.name ?? "所有角色", icon: "at") {
                    Button("所有角色") { recipient = "" }
                    Divider()
                    ForEach(run.roles) { role in Button(role.name) { recipient = role.id } }
                }
            }
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(empty ? Color.secondary.opacity(0.35) : RelayStyle.action, in: Circle())
            }.buttonStyle(.plain).disabled(empty).help(mode.help)
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
        .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(focused ? Color.primary.opacity(0.25) : RelayStyle.border))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        .onAppear { if needsGoal { focused = true } }
    }
    /// What sending does, by the run's state.
    enum Mode: Equatable {
        case goal, instruct, answer, continueFailed, followUp
        init(_ run: RelayRun) {
            if run.pause?.reason == .awaitingGoal { self = .goal }
            else if run.pendingQuestion != nil { self = .answer }
            else if run.status == .failed { self = .continueFailed }
            else if run.status.isTerminal { self = .followUp }
            else { self = .instruct }
        }
        var placeholder: String {
            switch self {
            case .goal: return "你想完成什么？写下目标，发送后开始规划…"
            case .instruct: return "补充目标、约束或调整方向，下一次调用时生效…"
            case .answer: return "回答当前问题，发送后继续原步骤…"
            case .continueFailed: return "补充要求，发送后从失败处继续…"
            case .followUp: return "这个任务已结束；写下新的要求，发送后新建后续任务…"
            }
        }
        var help: String {
            switch self {
            case .goal: return "设为目标并开始（↩）"
            case .instruct: return "加入任务（↩）"
            case .answer: return "回答并继续（↩）"
            case .continueFailed: return "加入要求并从失败处继续（↩）"
            case .followUp: return "新建后续任务（↩）"
            }
        }
    }
    private func send() {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let target = recipient.isEmpty ? nil : recipient
        do {
            switch Mode(run) {
            case .goal: try model.scheduler.addInstruction(run.id, text: text, roleID: nil)
            case .instruct: try model.scheduler.addInstruction(run.id, text: text, roleID: target)
            case .answer:
                guard let question = run.pendingQuestion else { return }
                try model.scheduler.answer(run.id, questionID: question.id, text: text)
            case .continueFailed: try model.scheduler.instructAndContinue(run.id, text: text, roleID: target)
            case .followUp: model.draftGoal = text; model.showsComposer = true
            }
            instruction = ""
        } catch { model.error = error.localizedDescription }
    }
}

/// A compact dropdown drawn as a soft pill: optional icon, title, small chevron, text centred. Used wherever a
/// menu sits beside a text field, instead of the system bordered pop-up.
struct RelayPillMenu<Items: View>: View {
    var title: String
    var icon: String? = nil
    /// Smaller, for list rows.
    var compact = false
    @ViewBuilder var items: Items
    @State private var hovering = false
    var body: some View {
        Menu { items } label: {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: compact ? 9 : 10.5, weight: .semibold)) }
                Text(title).font(.system(size: compact ? 11 : 12)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: compact ? 7.5 : 8.5, weight: .bold)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, compact ? 8 : 10).frame(height: compact ? 20 : 26)
            .background(Color.primary.opacity(hovering ? 0.09 : 0.055), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .onHover { hovering = $0 }
    }
}
