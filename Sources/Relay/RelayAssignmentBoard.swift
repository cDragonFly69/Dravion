import SwiftUI
import RelayCore

/// Native drag-and-drop and menus edit the same bindings; no second assignment state is kept.
struct RelayAssignmentBoard: View {
    var roles: [RelayRole]
    var connections: [RelayConnection]
    @Binding var planner: String
    @Binding var executors: [String]
    @Binding var tester: String
    @Binding var reviewer: String
    var direct = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var enabled: [RelayRole] { roles.filter(\.enabled) }
    private var stages: [RelayStage] { direct ? [.executor, .tester, .reviewer] : RelayStage.allCases }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("拖动员工，安排分工").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("也可使用岗位菜单选择").font(.caption).foregroundStyle(.secondary)
            }
            // A wrapping grid, not a horizontal scroll view: a scroll view takes the drag as a scroll first.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(enabled) { role in
                    RelayRoleChip(role: role, connection: connections.first { $0.id == role.connectionID }?.name ?? "连接缺失",
                                  stages: stages, title: title) { assign(role.id, to: $0) }
                }
            }
            // A plain stack, not a lazy grid: drop targets stay installed even while the board scrolls.
            HStack(alignment: .top, spacing: 10) {
                ForEach(stages, id: \.self) { stage in
                    RelayStation(stage: stage, title: title(stage), ids: current.holders(stage), roles: roles, enabled: enabled,
                                 multiple: stage == .executor && !direct,
                                 assign: { assign($0, to: stage) }, clear: { apply(current.clearing(stage)) },
                                 remove: { id in apply(current.removing(id, from: stage)) })
                }
            }
            Text("最少只要一位执行员工：一位时直接交给他；几位执行员工需要总调度来分工。质量检查、复审不安排就跳过，只跑本机测试。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func title(_ stage: RelayStage) -> String {
        switch stage {
        case .planner: return "规划 · 可选"
        case .executor: return direct ? "接收角色" : "执行"
        case .tester: return "质量检查 · 可选"
        case .reviewer: return "最终复审 · 可选"
        }
    }
    private var current: RelayAssignment { .init(planner: planner, executors: executors, tester: tester, reviewer: reviewer) }
    /// Writes only the posts that changed, so a direct-mode executor binding is not rewritten needlessly.
    private func apply(_ next: RelayAssignment) {
        if next.planner != planner { planner = next.planner }
        if next.executors != executors { executors = next.executors }
        if next.tester != tester { tester = next.tester }
        if next.reviewer != reviewer { reviewer = next.reviewer }
    }
    private func assign(_ ids: [String], to stage: RelayStage) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)) {
            apply(current.assigning(ids, to: stage, direct: direct))
        }
    }
    private func assign(_ id: String, to stage: RelayStage) { assign([id], to: stage) }
}

/// A role card to drag. The drag preview is a plain label: snapshotting the card would also capture its
/// menu button (an AppKit view), which is what made the drag start late and move unevenly.
private struct RelayRoleChip: View {
    let role: RelayRole
    let connection: String
    let stages: [RelayStage]
    let title: (RelayStage) -> String
    let assign: (RelayStage) -> Void

    var body: some View {
        HStack(spacing: 9) {
            DravionIcon(name: "users-three", size: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(role.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(connection).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Menu {
                ForEach(stages, id: \.self) { stage in Button("分配到\(title(stage))") { assign(stage) } }
            } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
                .accessibilityLabel("为\(role.name)选择岗位")
        }
        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
        .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RelayStyle.border))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .draggable(RelayAssignment.payload(role.id)) {
            Label(role.name, systemImage: "person.fill")
                .font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
        }
        .accessibilityIdentifier("assign-role-\(role.id)")
    }
}

/// One post. It keeps its own hover state, so passing over a post redraws that post only, not the board.
private struct RelayStation: View {
    let stage: RelayStage
    let title: String
    let ids: [String]
    let roles: [RelayRole]
    let enabled: [RelayRole]
    let multiple: Bool
    let assign: (String) -> Void
    let clear: () -> Void
    let remove: (String) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 2)
                Menu {
                    ForEach(enabled) { role in Button(role.name) { assign(role.id) } }
                    if !ids.isEmpty { Divider(); Button("清空岗位") { clear() } }
                } label: { Image(systemName: "plus.circle").foregroundStyle(.secondary) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
                    .accessibilityLabel("选择\(title)员工")
            }
            if ids.isEmpty {
                Text("拖放到这里").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 42)
            } else {
                ForEach(ids, id: \.self) { id in
                    HStack(spacing: 5) {
                        Text(roles.first { $0.id == id }?.name ?? "角色已移除").font(.system(size: 12, weight: .medium)).lineLimit(2)
                        Spacer(minLength: 2)
                        Button { remove(id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("移出这个岗位")
                    }.padding(8).background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }.padding(12).frame(minWidth: 0, maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
            // The whole post is the drop area, including the empty space under the holders.
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .background(targeted ? Color.primary.opacity(0.08) : RelayStyle.sunken, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? Color.primary.opacity(0.45) : RelayStyle.border,
                style: StrokeStyle(lineWidth: 1, dash: ids.isEmpty ? [4, 4] : [])))
            .dropDestination(for: String.self) { items, _ in
                let valid = RelayAssignment.dropped(items, enabled: enabled.map(\.id), multiple: multiple)
                for id in valid { assign(id) }
                targeted = false
                return !valid.isEmpty
            } isTargeted: { targeted = $0 }
            .accessibilityIdentifier("assignment-\(stage.rawValue)")
    }
}
