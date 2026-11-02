import SwiftUI
import RelayCore

/// 自动化 (sidebar, above 业务模块 and 收件箱; user request 2026-11-02): 自动化脚本 — model-free jobs installed per
/// script, callable by every agent — as a list or as cards (like 技能). Business flows live in 业务模块.
struct RelayAutomationView: View {
    @Bindable var model: RelayAppModel
    @State private var expanded: Set<String> = []
    @AppStorage("automation.layout") private var layout = "list"
    private var host: RelayAutomationHost { model.automations }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                RelayPageTitle(title: "自动化脚本", subtitle: "把重复的工作固定成脚本：运行时不调用模型、不花 token。员工在聊天里、执行任务的 Agent（Claude Code、Codex 等）都会直接调用已装的脚本，而不是自己一步步做。")
                Spacer()
                if host.installs.count < host.catalog.count {
                    Button("全部安装") { host.installAll() }.buttonStyle(.borderedProminent).tint(RelayStyle.action)
                }
            }
            HStack {
                Text("已安装 \(host.installs.count) / \(host.catalog.count) · 运行 \(host.runs.count) 次").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $layout) { Label("列表", systemImage: "list.bullet").tag("list"); Label("卡片", systemImage: "square.grid.2x2").tag("cards") }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            if layout == "cards" {
                    ForEach(Array(Dictionary(grouping: host.catalog, by: \.category).sorted { $0.key < $1.key }), id: \.key) { category, modules in
                        group(category, count: modules.count) { ForEach(modules) { scriptTile($0) } }
                    }
            } else {
                ForEach(host.catalog) { module in card(module) }
            }
            runs
        }
        .onAppear { host.reloadRuns() }
    }

    /// A titled grid, like the skills page.
    private func group<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(RelayPalette.client(title)).frame(width: 8, height: 8)
                Text(title).font(.system(size: 13, weight: .semibold))
                Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10, alignment: .top)], spacing: 10, content: content)
        }
    }

    /// The card layout of one script: name, switch, summary, last run, run / install.
    private func scriptTile(_ module: RelayAutomationModule) -> some View {
        let install = host.install(of: module.id)
        let tint = RelayPalette.client(module.category)
        let last = host.runs.first { $0.moduleID == module.id }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DravionIcon(name: "lightning", size: 13).foregroundStyle(tint)
                Text(module.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Spacer()
                if let install {
                    Toggle(isOn: Binding(get: { install.enabled }, set: { var next = install; next.enabled = $0; host.update(next) })) { EmptyView() }
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
            }
            Text(module.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if let last { Circle().fill(color(last.status)).frame(width: 6, height: 6); Text("\(label(last.status)) · \(last.startedAt.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary) }
                else { Text(install == nil ? "未安装" : "还没有运行").foregroundStyle(.tertiary) }
                Spacer()
                if install == nil {
                    Button("安装") { host.install(module.id) }.buttonStyle(.borderless)
                } else {
                    Button { Task { await host.run(module.id, trigger: .manual, requestedBy: "user") } } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless).disabled(host.running.contains(module.id) || install?.enabled != true).help("立即运行（不调用模型）")
                    if let last { Button { open(last) } label: { Image(systemName: "doc.text") }.buttonStyle(.borderless).help("看最近一次输出") }
                }
            }.font(.system(size: 10.5))
        }
        .padding(11).frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(install == nil ? Color.primary.opacity(0.03) : tint.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(install == nil ? RelayStyle.border : tint.opacity(0.18)))
        .opacity(install?.enabled == false ? 0.75 : 1)
        .help(module.steps.map { $0.command ?? "内置动作：\($0.action ?? "")" }.joined(separator: "\n"))
    }

    private func card(_ module: RelayAutomationModule) -> some View {
        let install = host.install(of: module.id)
        let running = host.running.contains(module.id)
        return RelayCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    RelayIconTile(icon: "lightning")
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(module.name).font(.system(size: 15, weight: .semibold))
                            RelayBadge(text: module.category, color: .secondary)
                            if install != nil { RelayBadge(text: install?.enabled == true ? "已安装" : "已停用", color: install?.enabled == true ? .green : .secondary) }
                        }
                        Text(module.summary).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if let install {
                        Toggle("启用", isOn: Binding(get: { install.enabled }, set: { var next = install; next.enabled = $0; host.update(next) }))
                            .toggleStyle(.switch).controlSize(.small).labelsHidden().help("停用后不再定时运行，员工也不能调用")
                        Button(running ? "运行中…" : "立即运行") { Task { await host.run(module.id, trigger: .manual, requestedBy: "user") } }
                            .buttonStyle(.borderedProminent).tint(RelayStyle.action).disabled(running || !install.enabled)
                        Menu {
                            Button(expanded.contains(module.id) ? "收起命令" : "查看命令") { toggle(module.id) }
                            Divider()
                            Button("卸载", role: .destructive) { host.uninstall(module.id) }.disabled(running)
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).frame(width: 26)
                    } else {
                        Button("查看命令") { toggle(module.id) }.buttonStyle(.bordered)
                        Button("安装") { host.install(module.id); expanded.insert(module.id) }.buttonStyle(.borderedProminent).tint(RelayStyle.action)
                    }
                }
                if expanded.contains(module.id) || install == nil && expanded.contains(module.id) { commands(module) }
                if let install { settings(module, install) }
                if let last = host.runs.first(where: { $0.moduleID == module.id }) {
                    Button { open(last) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(color(last.status)).frame(width: 7, height: 7)
                            Text("最近：\(label(last.status)) · \(last.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(trigger(last))")
                            Text("查看输出").foregroundStyle(.tertiary)
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func commands(_ module: RelayAutomationModule) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("会执行的步骤（不调用模型）").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(Array(module.steps.enumerated()), id: \.offset) { index, step in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(index + 1). \(step.title)").font(.system(size: 12, weight: .medium))
                    Text(step.command ?? "内置动作：\(step.action ?? "")").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("会动到：" + module.touches.joined(separator: "；")).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private func settings(_ module: RelayAutomationModule, _ install: RelayAutomationInstall) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(module.parameters, id: \.key) { parameter in
                HStack {
                    Text(parameter.label).font(.system(size: 12)).frame(width: 150, alignment: .leading)
                    TextField(parameter.required ? "必填" : "可选", text: Binding(get: { install.values[parameter.key] ?? "" }, set: {
                        var next = install; next.values[parameter.key] = $0; host.update(next)
                    })).relayField()
                }
            }
            if module.needsProject {
                HStack {
                    Text("项目").font(.system(size: 12)).frame(width: 150, alignment: .leading)
                    Picker("", selection: Binding(get: { install.projectID ?? "" }, set: { var next = install; next.projectID = $0.isEmpty ? nil : $0; host.update(next) })) {
                        Text("运行时指定（默认第一个项目）").tag("")
                        ForEach(model.store.state.projects) { Text($0.name).tag($0.id) }
                    }.labelsHidden().fixedSize()
                    Spacer()
                }
            }
            if module.triggers.contains(.schedule) {
                HStack {
                    Text("定时").font(.system(size: 12)).frame(width: 150, alignment: .leading)
                    Picker("", selection: Binding(get: { Self.key(install.schedule) }, set: { var next = install; next.schedule = Self.schedule($0); host.update(next) })) {
                        Text("不定时").tag("none")
                        Text("每 30 分钟").tag("every-30"); Text("每小时").tag("every-60"); Text("每 6 小时").tag("every-360")
                        Text("每天 09:00").tag("daily-9"); Text("每天 13:00").tag("daily-13"); Text("每天 22:00").tag("daily-22")
                    }.labelsHidden().fixedSize()
                    if let schedule = install.schedule { Text(schedule.label).font(.system(size: 11)).foregroundStyle(.secondary) }
                    Spacer()
                }
            }
        }
    }

    private var runs: some View {
        RelayCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("运行记录").font(.headline)
                if host.runs.isEmpty { Text("还没有运行过。").font(.system(size: 12)).foregroundStyle(.secondary) }
                ForEach(host.runs.prefix(30)) { run in
                    Button { open(run) } label: {
                        HStack(spacing: 8) {
                            Circle().fill(color(run.status)).frame(width: 7, height: 7)
                            Text(run.moduleName).font(.system(size: 12, weight: .medium))
                            Text("\(trigger(run))\(run.projectName.map { " · \($0)" } ?? "")").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Text(label(run.status)).font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(run.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func open(_ run: RelayAutomationRun) {
        model.present("automation-\(run.id)", width: 760) { RelayAutomationRunPanel(model: model, runID: run.id) }
    }
    private func toggle(_ id: String) { if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } }
    private func color(_ status: RelayAutomationRun.Status) -> Color {
        switch status { case .running: RelayStyle.accent; case .succeeded: .green; case .failed: .red; case .cancelled: .secondary }
    }
    private func label(_ status: RelayAutomationRun.Status) -> String {
        switch status { case .running: "运行中"; case .succeeded: "完成"; case .failed: "失败"; case .cancelled: "已取消" }
    }
    private func trigger(_ run: RelayAutomationRun) -> String {
        switch run.trigger {
        case .manual: "手动"; case .schedule: "定时"; case .afterRun: "任务完成后"
        case .employee: "员工 \(run.requestedBy.map { model.workforce?.name($0) ?? $0 } ?? "")调用"
        }
    }
    static func key(_ schedule: RelayAutomationInstall.Schedule?) -> String {
        switch schedule {
        case nil: "none"
        case .every(let minutes): "every-\(minutes)"
        case .daily(let hour, _): "daily-\(hour)"
        }
    }
    static func schedule(_ key: String) -> RelayAutomationInstall.Schedule? {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let value = Int(parts[1]) else { return nil }
        return parts[0] == "every" ? .every(minutes: value) : .daily(hour: value, minute: 0)
    }
}

/// One run's steps with their exit codes and output.
struct RelayAutomationRunPanel: View {
    let model: RelayAppModel
    let runID: String
    var body: some View {
        let run = model.automations.runs.first { $0.id == runID }
        VStack(alignment: .leading, spacing: 0) {
            RelaySheetHeader(title: run?.moduleName ?? "自动化运行", close: { model.dismissOverlay() })
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let run {
                        Text(run.summary.components(separatedBy: "\n").first ?? "").font(.system(size: 13, weight: .medium))
                        ForEach(Array(run.steps.enumerated()), id: \.offset) { index, step in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("\(index + 1). \(step.title)").font(.system(size: 12, weight: .semibold))
                                    Spacer()
                                    Text(step.skipped ? "未运行" : "退出码 \(step.exitCode.map(String.init) ?? "-") · \(String(format: "%.1f", step.seconds)) 秒")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                if !step.output.isEmpty {
                                    Text(step.output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                        }
                    }
                }.padding(20)
            }.frame(maxHeight: 560)
        }
    }
}
