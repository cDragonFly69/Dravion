import RelayCore
import SwiftUI

/// Lancer's GitTree, legend and event navigation adapted to the native thread. The graph, legend counts and event
/// list are projections of the same data; selecting one always targets the same conversation turn.
struct RelayTrajectoryPanel: View {
    let graph: RelayTrajectory
    var highlightLaneID: String?
    var selectedNodeID: String?
    var onSelect: (RelayTrajectoryNode) -> Void
    var onSelectRecord: (RelayTrajectoryRecord) -> Void
    var onFocusLane: (String) -> Void
    var onClose: () -> Void
    @State private var showLegend: Bool
    @State private var showEvents: Bool
    @State private var selectedKind: RelayTrajectoryKind?
    @State private var query = ""
    @State private var atBottom = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(graph: RelayTrajectory, highlightLaneID: String? = nil, selectedNodeID: String? = nil,
         showLegend: Bool = false, showEvents: Bool = false,
         onSelect: @escaping (RelayTrajectoryNode) -> Void, onSelectRecord: @escaping (RelayTrajectoryRecord) -> Void,
         onFocusLane: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.graph = graph; self.highlightLaneID = highlightLaneID; self.selectedNodeID = selectedNodeID
        self.onSelect = onSelect; self.onSelectRecord = onSelectRecord; self.onFocusLane = onFocusLane; self.onClose = onClose
        _showLegend = State(initialValue: showLegend); _showEvents = State(initialValue: showEvents)
    }

    private var counts: [RelayTrajectoryKind: Int] { Dictionary(grouping: graph.records, by: \.kind).mapValues(\.count) }
    private var records: [RelayTrajectoryRecord] {
        graph.records.filter { record in
            let laneMatches = highlightLaneID == nil || record.laneID == highlightLaneID || record.laneID == nil || record.laneID == RelayTrajectory.youLane
            return laneMatches && (selectedKind == nil || record.kind == selectedKind)
                && (query.isEmpty || record.message.localizedCaseInsensitiveContains(query) || record.kind.label.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            controls
            if showLegend { legend }
            Divider().opacity(0.6)
            if showEvents { eventList }
            else if graph.isEmpty {
                RelayEmpty(symbol: "point.3.connected.trianglepath.dotted", icon: "flow-arrow", title: "还没有步骤",
                           detail: "任务开始后，按执行者和时间查看每一步。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(14)
            } else { content }
            Divider().opacity(0.5)
            Text(showEvents ? "点事件定位对话 · 原始记录保持不变" : "列是执行者，纵向按记录顺序 · 点节点定位对话")
                .font(.system(size: 9.5)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(RelayStyle.canvas)
        .accessibilityIdentifier("trajectory-panel")
    }

    private var header: some View {
        HStack(spacing: 7) {
            DravionIcon(name: "flow-arrow", size: 13).foregroundStyle(.secondary)
            Text("会话轨迹").font(.system(size: 12, weight: .semibold))
            Text("\(graph.nodes.count) 步 · \(graph.records.count) 事件").font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(action: onClose) { Image(systemName: "sidebar.right").font(.system(size: 11)).frame(width: 22, height: 22) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("收起会话轨迹")
                .accessibilityLabel("收起会话轨迹")
        }.padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 10)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                modeButton("轨迹", events: false)
                modeButton("事件", events: true)
            }.padding(2).background(RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 6))
            Spacer(minLength: 0)
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)) { showLegend.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                    Text("图例 · 轨迹事件")
                    Image(systemName: showLegend ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
                }.font(.system(size: 10.5)).padding(.vertical, 5)
            }.buttonStyle(.plain).foregroundStyle(showLegend ? Color.primary : .secondary)
                .accessibilityIdentifier("trajectory-legend-toggle")
                .accessibilityLabel(showLegend ? "收起图例与轨迹事件" : "展开图例与轨迹事件")
        }.padding(.horizontal, 14).padding(.bottom, 10)
    }

    private func modeButton(_ title: String, events: Bool) -> some View {
        Button { showEvents = events } label: {
            Text(title).font(.system(size: 10.5, weight: showEvents == events ? .medium : .regular))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(showEvents == events ? RelayStyle.surface : .clear, in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain).accessibilityAddTraits(showEvents == events ? .isSelected : [])
            .accessibilityIdentifier(events ? "trajectory-events" : "trajectory-tree")
    }

    private var legend: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("点击类型筛选事件；灰色类型暂无对应记录。").font(.system(size: 10)).foregroundStyle(.secondary)
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], alignment: .leading, spacing: 6) {
                    ForEach([RelayTrajectoryKind.goal, .input, .reply, .edit, .test, .status] + RelayTrajectoryKind.lancerLegend, id: \.self) { kind in
                        let count = counts[kind] ?? 0
                        Button { selectedKind = selectedKind == kind ? nil : kind; showEvents = true } label: {
                            HStack(spacing: 6) {
                                Image(systemName: kind.symbol).font(.system(size: 10)).frame(width: 14)
                                Text(kind == .tool ? "工具调用" : kind.label).font(.system(size: 10.5)).lineLimit(1)
                                Spacer(minLength: 0)
                                Text("\(count)").font(.system(size: 9.5, design: .monospaced))
                            }
                            .foregroundStyle(count == 0 ? Color.secondary : .primary)
                            .padding(.horizontal, 6).padding(.vertical, 5)
                            .background(selectedKind == kind ? RelayStyle.sidebarSelection : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).help(kind.detail).accessibilityLabel("\(kind.label)，\(count) 条事件。\(kind.detail)")
                    }
                }
            }.padding(.horizontal, 14).padding(.bottom, 12)
        }.frame(maxHeight: 248)
            .transition(.opacity)
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索事件内容", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("清除事件搜索")
                }
            }.font(.system(size: 11)).padding(9).background(RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Text("\(selectedKind?.label ?? "全部类型") · \(records.count) 条").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if selectedKind != nil { Button("清除类型") { selectedKind = nil }.buttonStyle(.plain).font(.system(size: 10)) }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if records.isEmpty {
                        Text("没有匹配的事件。").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    ForEach(records) { record in eventRow(record) }
                }
            }
        }.padding(12)
    }

    private func eventRow(_ record: RelayTrajectoryRecord) -> some View {
        let line = record.sourceEvent.map(RelayEventLine.from)
        let preview = line.map { [$0.verb, String($0.body.prefix(220))].filter { !$0.isEmpty }.joined(separator: " · ") } ?? record.message
        let lane = graph.lanes.first { $0.id == record.laneID }
        return Button { onSelectRecord(record) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: record.kind.symbol).font(.system(size: 11)).foregroundStyle(record.kind == .error ? RelayPalette.ember : .secondary)
                    .frame(width: 16).padding(.top, 3)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(record.kind.label).font(.system(size: 10.5, weight: .medium))
                        Spacer()
                        Text(record.date.formatted(date: .omitted, time: .standard)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Text(preview).font(.system(size: 11)).lineLimit(3).multilineTextAlignment(.leading)
                    Text(lane?.title ?? "调度器").font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
            }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(record.nodeID != nil && record.nodeID == selectedNodeID ? RelayStyle.sidebarSelection : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help("在对话中查看这条记录")
    }

    private var content: some View {
        let layout = RelayTrajectoryLayout()
        let size = layout.size(laneCount: graph.lanes.count, rowCount: graph.nodes.count)
        return GeometryReader { geometry in
            let inset = max(8, (geometry.size.width - size.width) / 2)
            let width = max(size.width + 16, geometry.size.width)
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    ZStack(alignment: .topLeading) {
                        Canvas { context, canvas in
                            drawGuides(&context, layout: layout, inset: inset, height: canvas.height)
                            drawEdges(&context, layout: layout, inset: inset)
                        }.frame(width: width, height: size.height)
                        ForEach(Array(graph.lanes.enumerated()), id: \.element.id) { index, lane in
                            laneHeader(lane)
                                .position(x: inset + layout.center(lane: index, row: 0).x, y: layout.headerHeight / 2)
                        }
                        ForEach(graph.nodes) { node in
                            if let laneIndex = graph.laneIndex(node.laneID) {
                                chip(node, lane: graph.lanes[laneIndex])
                                    .relayLightAnchor("node:\(node.id)")
                                    .position(x: inset + layout.center(lane: laneIndex, row: node.row).x,
                                              y: layout.center(lane: laneIndex, row: node.row).y)
                                    .id(node.id)
                            }
                        }
                    }.frame(width: width, height: size.height, alignment: .topLeading)
                }
                .relayLightAnchor("trajectory-viewport")
                .modifier(RelayFollowBottom(atBottom: $atBottom))
                .onAppear { if let last = graph.nodes.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: graph.nodes.last?.id) { _, id in
                    guard atBottom, let id else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private func laneHeader(_ lane: RelayTrajectoryLane) -> some View {
        Button { onFocusLane(lane.id) } label: {
            VStack(spacing: 2) {
                Text(lane.title).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                Text(lane.subtitle).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width: 100).contentShape(Rectangle()).opacity(dimmed(lane.id) ? 0.45 : 1)
        }.buttonStyle(.plain).help("聚焦\(lane.title)的对话和事件")
    }

    private func chip(_ node: RelayTrajectoryNode, lane: RelayTrajectoryLane) -> some View {
        let tint = color(lane), selected = selectedNodeID == node.id
        return Button { onSelect(node) } label: {
            HStack(spacing: 4) {
                Image(systemName: node.kind.symbol).font(.system(size: 8.5, weight: .semibold))
                Text(node.title).font(.system(size: 10)).lineLimit(1)
            }
            .foregroundStyle(selected ? Color.primary : tint).padding(.horizontal, 7).frame(width: 100, height: 22)
            .background(tint.opacity(node.kind == .goal ? 0.14 : 0.1), in: Capsule())
            .overlay(Capsule().stroke(selected ? tint : tint.opacity(0.45), lineWidth: selected ? 1.5 : 1))
            .overlay { if node.running { RelayRunningBorder(color: tint) } }
        }.buttonStyle(.plain).opacity(dimmed(node.laneID) ? 0.35 : 1)
            .help("\(node.title) · \(node.detail) · \(node.eventIDs.count) 条事件")
            .accessibilityLabel("\(lane.title)，\(node.title)，\(node.detail)\(node.running ? "，运行中" : "")")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func color(_ lane: RelayTrajectoryLane) -> Color {
        lane.id == RelayTrajectory.youLane ? .primary : RelayStyle.color(lane.colorName)
    }
    private func dimmed(_ laneID: String) -> Bool { highlightLaneID.map { $0 != laneID } ?? false }

    private func drawGuides(_ context: inout GraphicsContext, layout: RelayTrajectoryLayout, inset: CGFloat, height: CGFloat) {
        for index in graph.lanes.indices {
            let x = inset + layout.center(lane: index, row: 0).x
            var line = Path(); line.move(to: .init(x: x, y: layout.headerHeight)); line.addLine(to: .init(x: x, y: height))
            context.stroke(line, with: .color(RelayStyle.border.opacity(dimmed(graph.lanes[index].id) ? 0.3 : 0.6)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
        }
    }

    private func drawEdges(_ context: inout GraphicsContext, layout: RelayTrajectoryLayout, inset: CGFloat) {
        let byID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        for edge in graph.edges {
            guard let from = byID[edge.from], let to = byID[edge.to],
                  let fromLane = graph.laneIndex(from.laneID), let toLane = graph.laneIndex(to.laneID) else { continue }
            let start = layout.center(lane: fromLane, row: from.row), end = layout.center(lane: toLane, row: to.row)
            var path = Path(); path.move(to: .init(x: inset + start.x, y: start.y + layout.nodeHeight / 2))
            let point = CGPoint(x: inset + end.x, y: end.y - layout.nodeHeight / 2)
            if fromLane == toLane { path.addLine(to: point) }
            else {
                let mid = (start.y + end.y) / 2
                path.addCurve(to: point, control1: .init(x: inset + start.x, y: mid), control2: .init(x: inset + end.x, y: mid))
            }
            context.stroke(path, with: .color(color(graph.lanes[toLane]).opacity(dimmed(to.laneID) ? 0.2 : 0.45)),
                           style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
    }
}
