import SwiftUI
import RelayCore

enum RelayKnowledgeDetailTab: String, CaseIterable {
    case body = "正文", sources = "来源与引用", history = "修订"
}

/// One reader shared by the workspace and existing overlay callers. Editing remains a centred model.present
/// overlay, while selecting a card or following a related card keeps the reader in place.
struct RelayKnowledgeDetail: View {
    @Bindable var model: RelayAppModel
    let cardID: String
    var embedded = false
    var onSelect: ((String) -> Void)?
    @State private var tab: RelayKnowledgeDetailTab
    @State private var editing: Bool
    @State private var confirmingDelete = false
    @State private var title = ""
    @State private var body_ = ""
    @State private var tags = ""
    @State private var expandedRevision: Int?
    @State private var failure: String?

    init(model: RelayAppModel, cardID: String, embedded: Bool = false, editing: Bool = false,
         tab: RelayKnowledgeDetailTab = .body, onSelect: ((String) -> Void)? = nil) {
        self.model = model; self.cardID = cardID; self.embedded = embedded; self.onSelect = onSelect
        _editing = State(initialValue: editing); _tab = State(initialValue: tab)
        let card = model.knowledge?.card(cardID)
        _title = State(initialValue: card?.title ?? "")
        _body_ = State(initialValue: card?.body ?? "")
        _tags = State(initialValue: card?.tags.joined(separator: ", ") ?? "")
    }

    private var store: RelayKnowledgeStore? { model.knowledge }
    private var card: RelayKnowledgeCard? { _ = model.knowledgeTick; return store?.card(cardID) }
    private var history: [RelayKnowledgeRevision] { _ = model.knowledgeTick; return store?.history(cardID) ?? [] }
    private var related: [RelayKnowledgeCard] { _ = model.knowledgeTick; return store?.related(cardID) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !embedded {
                RelayOverlayHeader(icon: "books", color: card.map { RelayKnowledgeUI.color($0.type) } ?? .secondary,
                                   title: editing ? "编辑卡片" : "知识详情",
                                   subtitle: card?.title ?? "卡片已不在", close: { model.dismissOverlay() })
                Divider().opacity(0.5)
            }
            if let card {
                if editing {
                    RelayFitScroll { editor.padding(20) }
                } else if embedded {
                    heading(card)
                    tabs.padding(.top, 14)
                    ScrollView { tabContent(card).padding(.vertical, 18) }
                } else {
                    RelayFitScroll {
                        VStack(alignment: .leading, spacing: 14) {
                            heading(card); tabs; tabContent(card)
                        }.padding(20)
                    }
                }
                if let failure {
                    Text(failure).font(.system(size: 12)).foregroundStyle(RelayPalette.ember).textSelection(.enabled).padding(12)
                }
                if confirmingDelete {
                    HStack(spacing: 10) {
                        Text("删除后可在入库记录中撤销。").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("取消") { confirmingDelete = false }
                        Button("删除", role: .destructive) { delete(card) }
                    }.padding(12).background(RelayStyle.sunken)
                }
                if editing {
                    Divider()
                    HStack {
                        Spacer()
                        Button("取消") { model.dismissOverlay() }
                        Button("保存修改") { save(card) }.buttonStyle(.borderedProminent).tint(RelayStyle.action)
                            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.padding(16)
                }
            } else {
                RelayEmpty(symbol: "books.vertical", icon: "books", title: "卡片已不在", detail: "它可能刚被删除、合并或撤销。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func heading(_ card: RelayKnowledgeCard) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(card.type.label).font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(RelayKnowledgeUI.color(card.type))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RelayKnowledgeUI.color(card.type).opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                Spacer()
                Button("编辑") {
                    model.present("knowledge-edit", width: 720) { RelayKnowledgeDetail(model: model, cardID: card.id, editing: true) }
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("knowledge-edit")
                Menu {
                    Menu("合并到…") {
                        ForEach((store?.cards(limit: 200) ?? []).filter { $0.id != card.id }) { other in
                            Button(other.title) { merge(card, into: other) }
                        }
                    }
                    Button("在访达中显示") {
                        if let store { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL(card)]) }
                    }
                    Divider()
                    Button("删除卡片", role: .destructive) { confirmingDelete = true }
                } label: { Image(systemName: "ellipsis").frame(width: 18) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("卡片操作")
            }
            Text(card.title).font(.system(size: 22, weight: .semibold)).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text([card.project, author(card.createdBy), "修订 \(card.revision)"].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !card.tags.isEmpty {
                Text(card.tags.map { "#\($0)" }.joined(separator: "  ")).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 20) {
            ForEach(RelayKnowledgeDetailTab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    Text(item.rawValue).font(.system(size: 11, weight: tab == item ? .medium : .regular))
                        .foregroundStyle(tab == item ? Color.primary : .secondary).padding(.bottom, 10)
                        .overlay(alignment: .bottom) { if tab == item { Rectangle().fill(Color.primary).frame(height: 2) } }
                }.buttonStyle(.plain).accessibilityAddTraits(tab == item ? .isSelected : [])
                    .accessibilityIdentifier("knowledge-detail-\(item.rawValue)")
            }
            Spacer(minLength: 0)
        }.overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    @ViewBuilder private func tabContent(_ card: RelayKnowledgeCard) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            switch tab {
            case .body:
                RelayKnowledgeBody(text: card.body, tint: RelayKnowledgeUI.color(card.type))
                if !related.isEmpty { relatedSection }
            case .sources:
                let sources = store?.sources(of: card) ?? []
                if sources.isEmpty {
                    Text("这张卡片没有关联来源。").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(sources, id: \.source.id) { item in
                    KnowledgeSourceExcerpt(source: item.source, text: item.text)
                }
                if !related.isEmpty { relatedSection }
            case .history:
                if history.isEmpty { Text("还没有修订记录。").font(.system(size: 12)).foregroundStyle(.secondary) }
                ForEach(history) { revision in
                    VStack(alignment: .leading, spacing: 8) {
                        Button { expandedRevision = expandedRevision == revision.id ? nil : revision.id } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: expandedRevision == revision.id ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .semibold)).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("\(author(revision.actor)) · \(revision.reason)").font(.system(size: 12, weight: .medium))
                                    Text("r\(revision.beforeRevision ?? 0) → r\(revision.afterRevision ?? 0) · \(revision.createdAt.formatted(date: .abbreviated, time: .shortened))\(revision.undoneAt == nil ? "" : " · 已撤销")")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if expandedRevision == revision.id {
                            if let markdown = revision.afterMarkdown {
                                Text(verbatim: markdown).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 8))
                            } else {
                                Text("此修订删除了卡片。").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Divider().opacity(0.4)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().opacity(0.5)
            Text("关联知识").font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(related) { item in
                Button {
                    if let onSelect { onSelect(item.id) }
                    else { model.present("knowledge-card", width: 780) { RelayKnowledgeDetail(model: model, cardID: item.id) } }
                } label: {
                    HStack {
                        Text(item.title).font(.system(size: 12)).lineLimit(2)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: 10))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("标题", text: $title).relayField().accessibilityIdentifier("knowledge-edit-title")
            TextField("标签，用逗号分开", text: $tags).relayField()
            TextEditor(text: $body_).font(.system(size: 13)).scrollContentBackground(.hidden)
                .padding(8).frame(minHeight: 260, maxHeight: 400)
                .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(RelayStyle.border))
            Text("保存后留下修订记录，可在“入库记录”撤销。").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func author(_ id: String) -> String {
        if id == "user" { return "你" }
        if id == "knowledge-curator" { return "知识整理员" }
        return model.store.state.roles.first { $0.id == id }?.name ?? id
    }

    private func save(_ card: RelayKnowledgeCard) {
        guard let store else { return }
        let parsed = tags.components(separatedBy: CharacterSet(charactersIn: ",，"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        do {
            _ = try store.update(card.id, actor: "user", reason: "在知识库页面编辑") { draft in
                draft.title = title; draft.body = body_; draft.tags = parsed
            }
            model.notice = "已保存，可在入库记录里撤销"
            model.dismissOverlay()
        } catch { failure = error.localizedDescription }
    }

    private func delete(_ card: RelayKnowledgeCard) {
        guard let store else { return }
        do {
            try store.delete(card.id); model.notice = "已删除：\(card.title)"
            confirmingDelete = false
            if !embedded { model.dismissOverlay() }
        } catch { failure = error.localizedDescription; confirmingDelete = false }
    }

    private func merge(_ card: RelayKnowledgeCard, into target: RelayKnowledgeCard) {
        guard let store else { return }
        do {
            _ = try store.merge(card.id, into: target.id, actor: "user", reason: "在知识库页面合并")
            model.notice = "已合并到：\(target.title)"
            if let onSelect { onSelect(target.id) }
            else { model.present("knowledge-card", width: 780) { RelayKnowledgeDetail(model: model, cardID: target.id) } }
        } catch { failure = error.localizedDescription }
    }
}

struct RelayKnowledgeBody: View {
    var text: String
    var tint: Color = RelayPalette.teal
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(RelayKnowledgeUI.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(text).font(.system(size: 13, weight: .semibold)).padding(.top, 9)
                case .rule:
                    Divider().opacity(0.5).padding(.vertical, 4)
                case .quote(let text):
                    Text(RelayChatReportView.markdown(text)).font(.system(size: 13)).lineSpacing(5)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 2) }
                case .text(let text):
                    Text(RelayChatReportView.markdown(text)).font(.system(size: 13)).lineSpacing(5)
                }
            }
        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct KnowledgeSourceExcerpt: View {
    let source: RelayKnowledgeSource
    let text: String
    @State private var expanded = false
    private var url: URL? {
        guard let url = URL(string: source.origin), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("来源原文", systemImage: "quote.opening").font(.system(size: 12, weight: .medium))
                Spacer()
                if let url { Link("打开来源 ↗", destination: url).font(.system(size: 11)).tint(.primary) }
            }
            Text(source.origin).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            Text(verbatim: text).font(.system(size: 12)).lineSpacing(4).lineLimit(expanded ? nil : 8).textSelection(.enabled)
            HStack {
                Text(source.capturedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button(expanded ? "收起原文" : "展开原文") { expanded.toggle() }.buttonStyle(.plain).font(.system(size: 11))
            }
        }.padding(14).background(RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 8))
    }
}
