import SwiftUI
import RelayCore

/// A local self-test of saved cards. This is deliberately a reading exercise: no invented AI questions, mastery
/// scores or persisted review schedule before the K4 review engine exists.
struct RelayKnowledgePractice: View {
    @Bindable var model: RelayAppModel
    let open: (String) -> Void
    @State private var index = 0
    @State private var revealed = false
    private var cards: [RelayKnowledgeCard] {
        _ = model.knowledgeTick
        return model.knowledge?.cards(types: [.qa, .concept, .problem, .project], limit: 100) ?? []
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("先回想，再看答案").font(.system(size: 19, weight: .semibold))
                        Text("用已保存的问答、概念与问题复盘自测。本轮练习不计入长期掌握度。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(min(index + 1, cards.count)) / \(cards.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
                if cards.isEmpty {
                    RelayEmpty(symbol: "book", icon: "books", title: "先积累几张知识卡片", detail: "这里会使用你已有的问答、概念、问题复盘和项目卡片。")
                } else if index >= cards.count {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("本轮已看完 \(cards.count) 张卡片").font(.system(size: 18, weight: .semibold))
                        Button("再练一轮") { index = 0; revealed = false }.buttonStyle(.borderedProminent).tint(RelayStyle.action)
                    }.padding(28)
                } else {
                    let card = cards[index]
                    VStack(alignment: .leading, spacing: 20) {
                        Text(card.type.label).font(.system(size: 11, weight: .medium)).foregroundStyle(RelayKnowledgeUI.color(card.type))
                        Text(card.title).font(.system(size: 23, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        if revealed {
                            Divider()
                            RelayKnowledgeBody(text: card.body, tint: RelayKnowledgeUI.color(card.type))
                        } else {
                            Text("试着说清它的要点，以及什么情况下会用到。").font(.system(size: 13)).foregroundStyle(.secondary)
                                .padding(.vertical, 20)
                        }
                        HStack(spacing: 12) {
                            Button(revealed ? "收起原文" : "查看原文") { revealed.toggle() }
                                .buttonStyle(.borderedProminent).tint(RelayStyle.action)
                            Button("打开知识卡片") { open(card.id) }.buttonStyle(.plain).font(.system(size: 12))
                            Spacer()
                            Button("上一张") { index -= 1; revealed = false }.disabled(index == 0)
                            Button("下一张") { index += 1; revealed = false }
                        }
                    }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RelayStyle.border))
                }
                Text("复习排期与模拟面试尚未启用。").font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
        }.onChange(of: cards.map(\.id)) { _, _ in index = 0; revealed = false }
    }
}

struct RelayKnowledgeGrowth: View {
    @Bindable var model: RelayAppModel
    let open: (String) -> Void
    private var tags: [(tag: String, count: Int)] {
        _ = model.knowledgeTick; return Array((model.knowledge?.tagCounts() ?? []).prefix(8))
    }
    private var reflections: [RelayKnowledgeCard] {
        _ = model.knowledgeTick; return model.knowledge?.cards(types: [.insight, .review, .problem], limit: 12) ?? []
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("你的知识积累").font(.system(size: 19, weight: .semibold))
                    Text("按已经保存的卡片整理，方便回看自己持续关注的问题。").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("关注的主题").font(.system(size: 13, weight: .semibold))
                    if tags.isEmpty { Text("为知识添加标签后，主题分布会出现在这里。").font(.system(size: 12)).foregroundStyle(.secondary) }
                    ForEach(tags, id: \.tag) { item in
                        HStack(spacing: 12) {
                            Text(item.tag).font(.system(size: 12)).frame(width: 110, alignment: .leading).lineLimit(1)
                            GeometryReader { geometry in
                                Capsule().fill(RelayPalette.teal.opacity(0.12))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(RelayPalette.teal.opacity(0.7))
                                            .frame(width: geometry.size.width * CGFloat(item.count) / CGFloat(max(1, tags.first?.count ?? 1)))
                                    }
                            }.frame(height: 5)
                            Text("\(item.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                        }.accessibilityElement(children: .ignore).accessibilityLabel("\(item.tag)，\(item.count) 张卡片")
                    }
                    if !tags.isEmpty { Text("一张卡片可以属于多个主题；数量不代表掌握程度。").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                }.padding(22).background(RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 10) {
                    Text("最近的复盘与认知").font(.system(size: 13, weight: .semibold))
                    if reflections.isEmpty { Text("问题复盘、认知笔记与回顾卡片会汇集在这里。").font(.system(size: 12)).foregroundStyle(.secondary) }
                    ForEach(reflections) { card in
                        RelayKnowledgeRow(card: card, snippet: RelayKnowledgeUI.preview(card.body)) { open(card.id) }
                        Divider().opacity(0.4)
                    }
                }
            }.frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
        }
    }
}
