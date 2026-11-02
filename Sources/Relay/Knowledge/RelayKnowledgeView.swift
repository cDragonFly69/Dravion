import SwiftUI
import UniformTypeIdentifiers
import RelayCore

enum RelayKnowledgePage: String, CaseIterable, Identifiable {
    case browse = "浏览", search = "问答与搜索", review = "面试复习", growth = "成长", history = "入库记录", settings = "设置"
    var id: String { rawValue }
}

private enum KnowledgeTopic: String, CaseIterable {
    case all = "全部知识", development = "开发经验", projects = "项目与工具", growth = "个人成长"
    var types: [RelayKnowledgeCardType]? {
        switch self {
        case .all: nil
        case .development: [.concept, .qa, .problem, .delivery]
        case .projects: [.project, .skill, .video]
        case .growth: [.insight, .review, .note]
        }
    }
}

/// The approved reading workspace. Each column owns its scroll position; all content and mutations still use the
/// one KnowledgeStore. The same view works as a list → reader on a narrow window.
struct RelayKnowledgeView: View {
    @Bindable var model: RelayAppModel
    @State private var page: RelayKnowledgePage
    @State private var query = ""
    @State private var topic = KnowledgeTopic.all
    @State private var type: RelayKnowledgeCardType?
    @State private var tag: String?
    @State private var project: String?
    @State private var selectedID: String?
    @State private var reading = false
    @State private var limit = 60
    @State private var historyLimit = 60
    @State private var hideUndone = false
    @State private var dropping = false

    init(model: RelayAppModel, page: RelayKnowledgePage = .browse, selection: String? = nil) {
        self.model = model
        _page = State(initialValue: page)
        _selectedID = State(initialValue: selection)
        _reading = State(initialValue: selection != nil)
    }

    private var store: RelayKnowledgeStore? { model.knowledge }
    private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matches: [RelayKnowledgeHit] {
        _ = model.knowledgeTick
        guard let store else { return [] }
        if !searchText.isEmpty {
            return store.search(searchText, type: type, tag: tag, project: project, types: topic.types, limit: limit + 1)
        }
        return store.cards(type: type, tag: tag, project: project, types: topic.types, limit: limit + 1)
            .map { RelayKnowledgeHit(card: $0, snippet: RelayKnowledgeUI.preview($0.body)) }
    }
    private var rows: [RelayKnowledgeHit] { Array(matches.prefix(limit)) }
    private var currentID: String? {
        // Explicit related-card navigation may open an older card beyond the current list page.
        if let selectedID, store?.card(selectedID) != nil { return selectedID }
        return rows.first?.id
    }
    private var tags: [(tag: String, count: Int)] { _ = model.knowledgeTick; return store?.tagCounts() ?? [] }
    private var projects: [String] { _ = model.knowledgeTick; return store?.projects() ?? [] }
    private var entries: [RelayKnowledgeEntry] { _ = model.knowledgeTick; return store?.entries(limit: historyLimit) ?? [] }
    private var filterKey: String { [query, topic.rawValue, type?.rawValue ?? "", tag ?? "", project ?? ""].joined(separator: "\u{1F}") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 20)
            navigation
            if let failure = model.knowledgeError {
                RelayEmpty(symbol: "books.vertical", icon: "books", title: "知识库没有打开", detail: failure)
                    .textSelection(.enabled).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store != nil {
                pageContent.padding(.top, 18)
            } else {
                ProgressView("正在打开知识库…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 26).padding(.top, 24).padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RelayStyle.canvas)
        .onChange(of: filterKey) { _, _ in limit = 60; selectedID = nil; reading = false }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { providers in
            for provider in providers {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                    Task { @MainActor in
                        if let error { model.error = error.localizedDescription; return }
                        guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
                            model.error = "无法读取拖入的文件。"; return
                        }
                        importFile(url)
                    }
                }
            }
            return !providers.isEmpty
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12).strokeBorder(RelayStyle.action, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .background(RelayStyle.canvas.opacity(0.92))
                    .overlay(Label("松手就入库", systemImage: "arrow.down.doc").font(.system(size: 16, weight: .medium)))
                    .padding(12).allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text("知识库").font(.system(size: 25, weight: .semibold))
                Text("把经验留下来，下一次直接用。 · \(store?.cardCount ?? 0) 条知识")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Label("仅自己可见", systemImage: "lock")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 10)
            Button { startCapture(.paste) } label: {
                Label("采集知识", systemImage: "plus").font(.system(size: 12, weight: .medium)).padding(.vertical, 4)
            }.buttonStyle(.borderedProminent).tint(RelayStyle.action)
                .accessibilityIdentifier("knowledge-capture")
            Menu {
                Button("网页链接…") { startCapture(.web) }
                Button("选择文件…") { RelayDialogs.attachments().forEach(importFile) }
                Divider()
                Button("导出为 Markdown 文件夹…") { export() }
                Button("在访达中显示知识库") { reveal() }
            } label: { Image(systemName: "ellipsis").frame(width: 20, height: 26) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("更多采集与导出方式")
        }
    }

    private var navigation: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(RelayKnowledgePage.allCases) { item in
                    Button { page = item } label: {
                        Text(item.rawValue)
                            .font(.system(size: 12, weight: item == page ? .semibold : .regular))
                            .foregroundStyle(item == page ? Color.primary : .secondary)
                            .padding(.vertical, 12)
                            .overlay(alignment: .bottom) {
                                if item == page { Rectangle().fill(Color.primary).frame(height: 2) }
                            }
                    }.buttonStyle(.plain).accessibilityAddTraits(item == page ? .isSelected : [])
                        .accessibilityIdentifier("knowledge-tab-\(item.id)")
                }
            }
        }
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .browse, .search:
            VStack(alignment: .leading, spacing: 14) {
                if page == .search {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("从自己的知识里找答案").font(.system(size: 17, weight: .semibold))
                        Text("搜索已保存的标题、正文与标签，点开结果查看依据。智能问答尚未启用。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(.bottom, 4)
                }
                filters
                workspace
            }
        case .history: records
        case .settings: settings
        case .review:
            RelayKnowledgePractice(model: model, open: openCard)
        case .growth:
            RelayKnowledgeGrowth(model: model, open: openCard)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("搜索知识、问题或标签…", text: $query).textFieldStyle(.plain).font(.system(size: 12))
                        .accessibilityIdentifier("knowledge-search")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("清除搜索")
                    }
                }
                .padding(.horizontal, 12).frame(height: 36)
                .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(RelayStyle.border))
                Menu(project ?? "全部项目") {
                    Button("全部项目") { project = nil }
                    ForEach(projects, id: \.self) { name in Button(name) { project = name } }
                }.frame(width: 136).disabled(projects.isEmpty).help("按项目筛选知识")
            }
            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(KnowledgeTopic.allCases, id: \.self) { item in
                            Button { topic = item; type = nil } label: {
                                Text(item.rawValue).font(.system(size: 11, weight: topic == item ? .medium : .regular))
                                    .foregroundStyle(topic == item ? Color.primary : .secondary)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(topic == item ? RelayStyle.sidebarSelection : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).accessibilityAddTraits(topic == item ? .isSelected : [])
                        }
                    }
                }
                Menu {
                    Button("全部类型") { type = nil }
                    ForEach(RelayKnowledgeCardType.allCases.filter { topic.types?.contains($0) ?? true }) { item in
                        Button(item.label) { type = item }
                    }
                    Divider()
                    Button("全部标签") { tag = nil }
                    ForEach(tags, id: \.tag) { item in Button("#\(item.tag)（\(item.count)）") { tag = item.tag } }
                } label: {
                    Label(type?.label ?? tag.map { "#\($0)" } ?? "筛选", systemImage: "line.3.horizontal.decrease")
                        .font(.system(size: 11))
                }.menuStyle(.borderlessButton).fixedSize().help("类型和标签筛选")
            }
        }
    }

    private var workspace: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 720
            HStack(alignment: .top, spacing: 0) {
                if !compact || !reading {
                    list
                        .frame(width: compact ? nil : min(330, max(260, geometry.size.width * 0.34)))
                        .frame(maxWidth: compact ? .infinity : nil, maxHeight: .infinity)
                }
                if !compact { Divider().opacity(0.55).padding(.horizontal, 20) }
                if !compact || reading {
                    VStack(alignment: .leading, spacing: 10) {
                        if compact {
                            Button { reading = false } label: { Label("返回知识列表", systemImage: "chevron.left").font(.system(size: 12)) }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        if let id = currentID {
                            RelayKnowledgeDetail(model: model, cardID: id, embedded: true, onSelect: openCard)
                                .id(id)
                        } else {
                            RelayEmpty(symbol: "books.vertical", icon: "books", title: "留下一条值得复用的知识",
                                       detail: "选择左侧卡片，在这里阅读正文、来源和修订。")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(rows.count)\(matches.count > limit ? "+" : "") 条知识")
                Spacer()
                Text(searchText.isEmpty ? "最近更新" : "相关结果")
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 8)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if rows.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(store?.cardCount == 0 ? "还没有知识" : "没有找到匹配的知识").font(.system(size: 14, weight: .medium))
                            Text(store?.cardCount == 0 ? "采集一段文字、一个链接，或把文件拖到这里。" : "换个关键词，或清除当前筛选。")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button(store?.cardCount == 0 ? "采集第一条知识" : "清除筛选") {
                                if store?.cardCount == 0 { startCapture(.paste) } else { clearFilters() }
                            }.buttonStyle(.bordered)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(rows) { hit in
                        RelayKnowledgeRow(card: hit.card, snippet: hit.snippet, selected: currentID == hit.id) {
                            selectedID = hit.id; reading = true
                        }
                        if hit.id != rows.last?.id { Divider().opacity(0.4).padding(.horizontal, 10) }
                    }
                    if matches.count > limit {
                        Button("载入更多知识") { limit += 60 }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
                    }
                }
            }
        }
    }

    private var records: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("每次整理，都有来处").font(.system(size: 17, weight: .semibold))
                    Text("入库、编辑、合并与删除均可追溯；仍可撤销的记录会显示操作按钮。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("隐藏已撤销", isOn: $hideUndone).toggleStyle(.checkbox).font(.system(size: 11))
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(entries.filter { !hideUndone || $0.undoneAt == nil }) { entry in
                        KnowledgeEntryRow(entry: entry) { undo(entry) }
                    }
                    if entries.isEmpty {
                        RelayEmpty(symbol: "clock.arrow.circlepath", icon: "clock-countdown", title: "还没有入库记录", detail: "采集第一条知识后，会在这里留下记录。")
                    }
                    if entries.count == historyLimit {
                        Button("载入更早记录") { historyLimit += 60 }.buttonStyle(.plain).padding(12)
                    }
                }
            }
        }
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("知识库设置").font(.system(size: 17, weight: .semibold))
                setting("保存位置", detail: store?.directory.path ?? "未打开", status: "本机", icon: "folder")
                HStack(spacing: 10) {
                    Button("在访达中打开") { reveal() }
                    Button("导出 Markdown…") { export() }
                }.buttonStyle(.bordered)
                Divider()
                setting("采集知识", detail: "粘贴文字、网页、文件，以及对话里的“记下来”，会直接保存并保留来源。", status: "已启用", icon: "plus-square")
                setting("自动提炼", detail: "从日常对话和任务中自动整理知识；尚未启用。", status: "待接入", icon: "sparkle")
                setting("员工复用与智能问答", detail: "让员工检索相关卡片，并在回答中引用；尚未启用。", status: "待接入", icon: "quotes")
                setting("账号同步", detail: "当前知识只保存在这台 Mac；跨设备同步尚未启用。", status: "本机保存", icon: "hard-drives")
            }.padding(.vertical, 4).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func setting(_ title: String, detail: String, status: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            DravionIcon(name: icon, size: 15).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text(status).font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
                .background(RelayStyle.sunken, in: Capsule())
        }
    }

    private func clearFilters() {
        query = ""; topic = .all; type = nil; tag = nil; project = nil; limit = 60
    }

    private func openCard(_ id: String) {
        page = .browse; selectedID = id; reading = true
    }

    private func startCapture(_ kind: RelayKnowledgeCaptureKind) {
        model.present("knowledge-capture", width: 620) { RelayKnowledgeCaptureCard(model: model, kind: kind) }
    }

    private func importFile(_ url: URL) {
        guard let store else { return }
        do {
            switch try store.captureFile(url) {
            case .added(let card), .existing(let card): model.notice = "已保存：\(card.title)"; openCard(card.id)
            case .blocked(let reason): model.notice = reason
            }
        } catch { model.error = error.localizedDescription }
    }

    private func undo(_ entry: RelayKnowledgeEntry) {
        guard let store else { return }
        do { try store.undo(entry.batch); model.notice = "已撤销：\(entry.titles.first ?? entry.action.rawValue)" }
        catch { model.error = error.localizedDescription }
    }

    private func export() {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "导出到这里"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { model.notice = "已导出：\(try store.export(to: url).path)" }
        catch { model.error = error.localizedDescription }
    }

    private func reveal() {
        guard let store else { return }
        NSWorkspace.shared.activateFileViewerSelecting([store.directory])
    }
}

/// The capture entry on the page (K1): a pasted text, a web link, or a dropped file. It writes through the store and
/// reports the outcome; nothing is confirmed beforehand, matching “入库不找用户确认”.
enum RelayKnowledgeCaptureKind: String, Identifiable {
    case paste = "粘贴文字", web = "网页链接"
    var id: String { rawValue }
}

struct RelayKnowledgeCaptureCard: View {
    @Bindable var model: RelayAppModel
    @State private var kind: RelayKnowledgeCaptureKind
    @State private var text = ""
    @State private var title = ""
    @State private var link = ""
    @State private var busy = false
    @State private var failure: String?

    private var store: RelayKnowledgeStore? { model.knowledge }

    init(model: RelayAppModel, kind: RelayKnowledgeCaptureKind) {
        self.model = model; _kind = State(initialValue: kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RelayOverlayHeader(icon: kind == .web ? "paper-plane-tilt" : "books", color: RelayPalette.teal,
                               title: "采集知识", subtitle: "留下原文和来源，之后随时查找、整理。",
                               close: { model.dismissOverlay() })
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 12) {
                Picker("采集方式", selection: $kind) {
                    Text("粘贴文字").tag(RelayKnowledgeCaptureKind.paste)
                    Text("网页链接").tag(RelayKnowledgeCaptureKind.web)
                }.pickerStyle(.segmented).disabled(busy)
                if kind == .web {
                    TextField("https://…", text: $link).relayField()
                    Text("只取这一页的正文；需要登录或由脚本生成的页面会明确报错，不会假装成功。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    TextField("标题（留空就用第一行）", text: $title).relayField()
                    TextEditor(text: $text)
                        .font(.system(size: 13)).scrollContentBackground(.hidden)
                        // A compact dialog rather than a full-height panel: the overlay host centres the card.
                        .padding(8).frame(minHeight: 220, maxHeight: 340)
                        .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(RelayStyle.border))
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("把一段文字贴进来：第一行会当标题，密钥会被遮掉。")
                                    .font(.system(size: 13)).foregroundStyle(.tertiary)
                                    .padding(.horizontal, 13).padding(.vertical, 9)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                if let failure { Text(failure).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
                HStack(spacing: 10) {
                    Spacer()
                    Button("取消") { model.dismissOverlay() }
                    Button(busy ? "处理中…" : "入库") { submit() }
                        .buttonStyle(.borderedProminent).tint(RelayStyle.action)
                        .disabled(busy || (kind == .web ? link.isEmpty : text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }.padding(20)
        }
    }

    private func submit() {
        guard let store else { failure = model.knowledgeError ?? "知识库没有打开。"; return }
        failure = nil
        if kind == .web {
            guard let url = URL(string: link.trimmingCharacters(in: .whitespaces)), url.scheme != nil else { failure = "链接不完整。"; return }
            busy = true
            Task { @MainActor in
                do {
                    let page = try await RelayKnowledgeCapture.fetch(url)
                    let outcome = try store.captureWeb(url: page.url, title: page.title, text: page.text)
                    finish(outcome)
                } catch { failure = error.localizedDescription; busy = false }
            }
        } else {
            do { finish(try store.capturePasted(text, title: title.isEmpty ? nil : title)) }
            catch { failure = error.localizedDescription }
        }
    }

    private func finish(_ outcome: RelayKnowledgeStore.AddOutcome) {
        busy = false
        switch outcome {
        case .added(let card): model.notice = "已入库：\(card.title)"
        case .existing(let card): model.notice = "已经有这一条：\(card.title)"
        case .blocked(let reason): model.notice = reason
        }
        model.dismissOverlay()
    }
}

// MARK: - Shared pieces

enum RelayKnowledgeUI {
    /// Category tints; body text stays `.primary` (界面规范 2、6).
    static func color(_ type: RelayKnowledgeCardType) -> Color {
        switch type {
        case .concept: return RelayPalette.teal
        case .qa: return RelayPalette.violet
        case .problem: return RelayPalette.ember
        case .project: return RelayPalette.green
        case .video: return RelayPalette.rose
        case .skill: return RelayPalette.amber
        case .insight: return RelayPalette.violet
        case .delivery: return RelayPalette.green
        case .review: return RelayPalette.teal
        case .note: return Color.secondary
        }
    }

    /// A Phosphor glyph per kind, so a list can be scanned without reading the label (all registered in Icons/phosphor).
    static func icon(_ type: RelayKnowledgeCardType) -> String {
        switch type {
        case .concept: return "files"
        case .qa: return "chats-circle"
        case .problem: return "git-diff"
        case .project: return "folders"
        case .video: return "desktop"
        case .skill: return "terminal-window"
        case .insight: return "chart-bar"
        case .delivery: return "package"
        case .review: return "clock-countdown"
        case .note: return "books"
        }
    }

    /// First readable line of the body, one line, for a list row.
    static func preview(_ body: String) -> String {
        body.split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0 != "---" && !$0.hasPrefix("#") }
            ?? body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    static func when(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// The few Markdown blocks a card uses, for the detail view: `##` headings, `---` rules, `>` quotes, plain text.
    enum Block {
        case heading(String), rule, quote(String), text(String)
    }
    static func blocks(_ body: String) -> [Block] {
        var result: [Block] = []
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed == "---" { result.append(.rule) }
            else if trimmed.hasPrefix("## ") { result.append(.heading(String(trimmed.dropFirst(3)))) }
            else if trimmed.hasPrefix("# ") { result.append(.heading(String(trimmed.dropFirst(2)))) }
            else if trimmed.hasPrefix("> ") { result.append(.quote(String(trimmed.dropFirst(2)))) }
            else { result.append(.text(line)) }
        }
        return result
    }
}


struct RelayKnowledgeRow: View {
    var card: RelayKnowledgeCard
    var snippet: String
    var selected = false
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text(card.type.label).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(RelayKnowledgeUI.color(card.type))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RelayKnowledgeUI.color(card.type).opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
                    Text(RelayKnowledgeUI.when(card.updatedAt)).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                Text(card.title).font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                if !snippet.isEmpty, snippet.trimmingCharacters(in: .whitespacesAndNewlines) != card.title {
                    Text(snippet).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                }
                if let project = card.project, !project.isEmpty {
                    Text(project).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? RelayStyle.sidebarSelection : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? RelayStyle.border : .clear))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.vertical, 4)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("knowledge-card-\(card.id)")
    }
}

struct KnowledgeEntryRow: View {
    var entry: RelayKnowledgeEntry
    var undo: () -> Void
    private var tint: Color {
        switch entry.action {
        case .create: return RelayPalette.teal
        case .update, .externalEdit: return RelayPalette.amber
        case .merge: return RelayPalette.violet
        case .delete: return RelayPalette.ember
        case .undo: return .secondary
        }
    }
    private var label: String {
        switch entry.action {
        case .create: return "入库"
        case .update: return "修改"
        case .merge: return "合并"
        case .delete: return "删除"
        case .externalEdit: return "外部编辑"
        case .undo: return "撤销"
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(tint).frame(width: 6, height: 6).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                    Text(entry.titles.joined(separator: "、")).font(.system(size: 12)).lineLimit(1)
                    if entry.undoneAt != nil { Text("已撤销").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                Text("\(entry.actor) · \(entry.reason) · \(RelayKnowledgeUI.when(entry.createdAt))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if entry.undoable {
                Button("撤销", action: undo)
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(RelayStyle.surface, in: Capsule())
                    .overlay(Capsule().stroke(RelayStyle.border))
                    .help("撤销这一次入库（写一条修订记录）")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
