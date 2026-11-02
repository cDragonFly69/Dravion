import SwiftUI
import RelayCore

/// What the local clients know beyond one task: installed skills, saved memories, and archived runs. Opened
/// from 本机工作空间 in the sidebar, like the account panel in Codex. Everything here is read from the clients'
/// own folders; nothing is edited except a run's archive flag.
struct RelayPersonalPanel: View {
    @Bindable var model: RelayAppModel
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "概况", skills = "技能", memory = "记忆库", archive = "归档任务"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .overview: return "desktop"
            case .skills: return "files"
            case .memory: return "folder-open"
            case .archive: return "folders"
            }
        }
    }
    @State private var tab: Tab = .overview
    @State private var library = RelayLocalLibrary()
    @State private var loaded = false
    @State private var query = ""
    @State private var openedMemory: RelayLocalLibrary.Memory.ID?
    @State private var usage: [String: RelaySkills.Usage] = [:]
    @State private var skillFilter = SkillFilter.all
    @State private var skillError: String?
    enum SkillFilter: String, CaseIterable { case all = "全部", used = "调用过", off = "已停用" }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(DravionBrand.gradient).frame(width: 34, height: 34)
                        Text(String(NSFullUserName().prefix(1))).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NSFullUserName()).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text("本机工作空间").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.padding(.bottom, 14)
                ForEach(Tab.allCases) { item in
                    Button { tab = item } label: {
                        HStack(spacing: 9) {
                            DravionIcon(name: item.icon, duotone: tab == item, size: 16)
                            Text(item.rawValue).font(.system(size: 13, weight: tab == item ? .semibold : .regular))
                            Spacer()
                            if let count = count(item) { Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(tab == item ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
                Button("关闭") { model.dismissOverlay() }
            }
            .padding(18).frame(width: 210).background(Color.primary.opacity(0.03))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(tab.rawValue).font(.system(size: 18, weight: .semibold))
                    Spacer()
                    if tab == .skills || tab == .memory {
                        TextField("搜索", text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
                        Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("重新读取")
                    }
                }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)
                Divider().opacity(0.5)
                ScrollView {
                    Group {
                        switch tab {
                        case .overview: overview
                        case .skills: skills
                        case .memory: memory
                        case .archive: archive
                        }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(height: 680).background(RelayStyle.canvas)
        .task { if !loaded { await reload() } }
    }

    private func reload() async {
        let runs = model.store.state.runs
        let events = RelayHostPaths.root.appendingPathComponent("events")
        async let read = Task.detached(priority: .userInitiated) { RelayLocalLibrary.read() }.value
        async let counted = Task.detached(priority: .utility) { RelaySkills.usage(runs: runs, eventsDirectory: events) }.value
        library = await read
        usage = await counted
        loaded = true
    }
    private var archived: [RelayRun] { model.store.state.runs.filter { $0.archivedAt != nil } }
    private func count(_ tab: Tab) -> Int? {
        switch tab {
        case .overview: return nil
        case .skills: return loaded ? library.skills.count : nil
        case .memory: return loaded ? library.memories.count : nil
        case .archive: return archived.count
        }
    }

    private var overview: some View {
        let runs = model.store.state.runs
        let tiles: [(String, String, String, Color)] = [
            ("任务", "\(runs.filter { $0.archivedAt == nil }.count)", "进行中与最近", RelayPalette.violet),
            ("已完成", "\(runs.filter { $0.status == .succeeded }.count)", "全部历史", RelayPalette.green),
            ("技能", loaded ? "\(library.skills.count)" : "…", "\(Set(library.skills.map(\.client)).count) 个客户端", RelayPalette.amber),
            ("记忆", loaded ? "\(library.memories.count)" : "…", "Claude 项目记忆与全局说明", RelayPalette.teal),
            ("员工", "\(model.store.state.roles.filter(\.enabled).count)", "已启用", RelayPalette.rose),
            ("项目", "\(model.store.state.projects.count)", "本机项目", RelayPalette.ember)
        ]
        return VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                ForEach(tiles, id: \.0) { tile in RelayStatTile(title: tile.0, value: tile.1, note: tile.2, color: tile.3) }
            }
            Text("数据目录").font(.headline)
            HStack {
                Text(RelayHostPaths.root.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([RelayHostPaths.root]) }.buttonStyle(.borderless)
            }.padding(12).background(RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private func use(_ skill: RelayLocalLibrary.Skill) -> RelaySkills.Usage? { usage[skill.folder] ?? usage[skill.name] }

    @ViewBuilder private var skills: some View {
        let shown = library.skills.filter { skill in
            (query.isEmpty || skill.name.localizedCaseInsensitiveContains(query) || skill.summary.localizedCaseInsensitiveContains(query))
                && (skillFilter == .all || (skillFilter == .used && use(skill) != nil) || (skillFilter == .off && skill.disabled))
        }
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Picker("筛选", selection: $skillFilter) {
                    ForEach(SkillFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                Spacer()
                let calls = usage.values.reduce(0) { $0 + $1.calls }
                Text("共调用 \(calls) 次 · \(library.skills.filter(\.disabled).count) 个已停用").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let skillError { Text(skillError).font(.system(size: 12)).foregroundStyle(.red) }
            if !loaded { ProgressView() } else if shown.isEmpty {
                RelayEmptyNote(text: skillFilter == .all ? "没有找到技能。Claude Code、Codex、WorkBuddy 的 skills 目录都会在这里列出。" : "没有符合筛选的技能。")
            } else {
                ForEach(Array(Dictionary(grouping: shown, by: \.client).sorted { $0.key < $1.key }), id: \.key) { client, items in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Circle().fill(RelayPalette.client(client)).frame(width: 8, height: 8)
                            Text(client).font(.system(size: 13, weight: .semibold))
                            Text("\(items.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10, alignment: .top)], spacing: 10) {
                            ForEach(items) { skill in skillCard(skill, client: client) }
                        }
                    }
                }
            }
            Text("停用会把技能文件夹移到 Dravion 数据目录的 disabled-skills 里，所有客户端（包括在 Dravion 之外直接使用时）都不会再加载它；重新启用会放回原处。插件自带的技能在插件更新后可能被恢复。")
                .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func skillCard(_ skill: RelayLocalLibrary.Skill, client: String) -> some View {
        let used = use(skill)
        let tint = RelayPalette.client(client)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(skill.name).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1)
                    .foregroundStyle(skill.disabled ? .secondary : .primary)
                if let source = skill.source { Text(source).font(.system(size: 10)).foregroundStyle(.tertiary) }
                Spacer()
                Toggle(isOn: Binding(get: { !skill.disabled }, set: { toggle(skill, enabled: $0) })) { EmptyView() }
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .help(skill.disabled ? "已停用：所有客户端都不会调用。打开即恢复" : "关闭后，所有客户端都不会再调用这个技能")
            }
            Text(skill.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if let used {
                    Label("\(used.calls) 次", systemImage: "bolt.fill").foregroundStyle(tint)
                    Text(used.models.sorted { $0.value > $1.value }.prefix(2).map { "\($0.key) ×\($0.value)" }.joined(separator: "、"))
                        .foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if let last = used.last { Text(last.formatted(.relative(presentation: .named))).foregroundStyle(.tertiary) }
                } else {
                    Text(skill.disabled ? "已停用" : "还没有被调用").foregroundStyle(.tertiary)
                    Spacer()
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.path)]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help(skill.path)
            }.font(.system(size: 10.5))
        }
        .padding(11).frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(skill.disabled ? Color.primary.opacity(0.03) : tint.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(skill.disabled ? RelayStyle.border : tint.opacity(0.18)))
        .opacity(skill.disabled ? 0.75 : 1)
        .help(used.map { u in u.models.sorted { $0.value > $1.value }.map { "\($0.key)：\($0.value) 次" }.joined(separator: "\n") + "\n用于 \(u.runs.count) 个任务" } ?? skill.path)
    }

    private func toggle(_ skill: RelayLocalLibrary.Skill, enabled: Bool) {
        skillError = nil
        do {
            try RelaySkills.setEnabled(enabled, skillFile: skill.path)
            Task { await reload() }
        } catch { skillError = error.localizedDescription }
    }

    @ViewBuilder private var memory: some View {
        let shown = library.memories.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query) || $0.scope.localizedCaseInsensitiveContains(query) }
        if !loaded { ProgressView() } else if shown.isEmpty { RelayEmptyNote(text: "没有找到记忆文件。Claude Code 的项目记忆在 ~/.claude/projects/*/memory，全局说明是 ~/.claude/CLAUDE.md 和 ~/.codex/AGENTS.md。") } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(shown) { item in
                    VStack(alignment: .leading, spacing: 0) {
                        Button { openedMemory = openedMemory == item.id ? nil : item.id } label: {
                            HStack(spacing: 10) {
                                Circle().fill(RelayPalette.client(item.client)).frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text("\(item.client) · \(item.scope)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(item.modified.formatted(.relative(presentation: .named))).font(.system(size: 10)).foregroundStyle(.tertiary)
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                                    .rotationEffect(.degrees(openedMemory == item.id ? 90 : 0))
                            }.padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if openedMemory == item.id {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.text).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }.buttonStyle(.borderless).font(.system(size: 11))
                            }.padding(.horizontal, 27).padding(.bottom, 12)
                        }
                    }
                    .background(openedMemory == item.id ? RelayStyle.sunken : .clear, in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
    }

    @ViewBuilder private var archive: some View {
        if archived.isEmpty { RelayEmptyNote(text: "没有归档的任务。在侧边栏“最近任务”里右键已结束的任务，选择“归档”。") } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(archived) { run in
                    HStack(spacing: 10) {
                        Circle().fill(RelayStyle.status(run.status)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run.input.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text("\(run.project.name) · \(run.status.label) · 归档于 \(run.archivedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("查看") { model.selectRun(run.id); model.dismissOverlay() }.buttonStyle(.borderless)
                        Button("恢复") { model.perform { try model.store.setArchived(run.id, false) } }.buttonStyle(.bordered).controlSize(.small)
                    }
                    .padding(10).background(RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
    }
}

private struct RelayEmptyNote: View {
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            DravionIcon(name: "files", size: 26).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }.frame(maxWidth: .infinity, minHeight: 220)
    }
}

/// Skills and memories the local clients keep, read once per open (front matter only for skills).
struct RelayLocalLibrary: Sendable {
    struct Skill: Identifiable, Sendable {
        var id: String { path }; var client: String; var name: String; var summary: String; var path: String; var source: String?
        /// Switched off: moved to `RelaySkills.disabledRoot`, so no client loads it.
        var disabled = false
        /// The folder name, which is what clients usually call the skill by.
        var folder: String { URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent }
    }
    struct Memory: Identifiable, Sendable { var id: String { path }; var client: String; var scope: String; var title: String; var text: String; var path: String; var modified: Date }
    var skills: [Skill] = []
    var memories: [Memory] = []

    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> RelayLocalLibrary {
        var library = RelayLocalLibrary()
        let roots: [(String, String, String?)] = [
            ("Claude Code", ".claude/skills", nil), ("Claude Code", ".claude/plugins", "插件"),
            ("Codex", ".codex/skills", nil), ("WorkBuddy", ".workbuddy/skills", nil),
            ("DeepSeek Harness", ".dsh/skills", nil), ("通用", ".agents/skills", nil)
        ]
        var seen = Set<String>()
        for ((client, relative, source), disabled) in roots.flatMap({ root in [(root, false), (root, true)] }) {
            let root = disabled ? RelaySkills.disabledRoot.appendingPathComponent(relative) : home.appendingPathComponent(relative)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                if walker.level > 7 { walker.skipDescendants(); continue }
                guard url.lastPathComponent == "SKILL.md" else { continue }
                let meta = frontMatter(url)
                let name = meta["name"] ?? url.deletingLastPathComponent().lastPathComponent
                guard seen.insert(client + "/" + name).inserted else { continue }
                library.skills.append(.init(client: client, name: name, summary: meta["description"] ?? "", path: url.path, source: source, disabled: disabled))
                if library.skills.count > 400 { break }
            }
        }
        library.skills.sort { ($0.client, $0.name) < ($1.client, $1.name) }

        func add(_ client: String, _ scope: String, _ url: URL) {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  (values.fileSize ?? 0) > 0, (values.fileSize ?? 0) < 400_000,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            let meta = frontMatter(url)
            library.memories.append(.init(client: client, scope: scope, title: meta["name"] ?? meta["description"] ?? url.deletingPathExtension().lastPathComponent,
                                          text: String(text.prefix(20_000)), path: url.path, modified: values.contentModificationDate ?? .distantPast))
        }
        add("Claude Code", "全局说明", home.appendingPathComponent(".claude/CLAUDE.md"))
        add("Codex", "全局说明", home.appendingPathComponent(".codex/AGENTS.md"))
        let projects = home.appendingPathComponent(".claude/projects")
        for folder in (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            let memory = folder.appendingPathComponent("memory")
            guard let files = try? FileManager.default.contentsOfDirectory(at: memory, includingPropertiesForKeys: nil) else { continue }
            // "-Users-me-codeproject-Dravion" → "Dravion"; scratch folders under /tmp are skipped.
            guard !folder.lastPathComponent.contains("-tmp-") else { continue }
            let scope = folder.lastPathComponent.split(separator: "-").last.map(String.init) ?? folder.lastPathComponent
            for file in files where file.pathExtension == "md" { add("Claude Code", "项目 " + scope, file) }
        }
        library.memories.sort { $0.modified > $1.modified }
        return library
    }

    /// `key: value` lines between the leading `---` fences.
    private static func frontMatter(_ url: URL) -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.read(upToCount: 8_192) else { return [:] }
        try? handle.close()
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { result[key] = value }
        }
        return result
    }
}
