import WidgetKit
import SwiftUI

struct RelayProgressEntry: TimelineEntry {
    var date: Date
    var snapshot: RelayTaskSnapshot?
    var error: String?
}

struct RelayProgressProvider: TimelineProvider {
    func placeholder(in context: Context) -> RelayProgressEntry { .init(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (RelayProgressEntry) -> Void) { completion(read()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RelayProgressEntry>) -> Void) {
        completion(Timeline(entries: [read()], policy: .after(Date().addingTimeInterval(60))))
    }
    private func read() -> RelayProgressEntry {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PulseAppGroup") as? String,
              let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            return .init(date: Date(), error: "请打开已签名的 Dravion 应用")
        }
        let url = directory.appendingPathComponent("relay-tasks.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .init(date: Date(), error: "打开 Dravion，同步任务进度") }
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let data = try Data(contentsOf: url)
            let snapshot = try decoder.decode(RelayTaskSnapshot.self, from: data)
            guard snapshot.version == 1 else { return .init(date: Date(), error: "请更新 Dravion 小组件") }
            return .init(date: Date(), snapshot: snapshot)
        } catch { return .init(date: Date(), error: "任务快照无法读取，请重新打开 Dravion") }
    }
}

struct RelayProgressWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RelayTaskProgress", provider: RelayProgressProvider()) { entry in
            RelayProgressView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }.configurationDisplayName("Dravion · 调度进度")
            .description("查看运行、暂停与已完成的任务，点击继续处理。")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct RelayProgressView: View {
    var entry: RelayProgressEntry
    @Environment(\.widgetFamily) private var family
    private let accent = Color(red: 0.898, green: 0.188, blue: 0.420) // Dravion Magenta #E5306B
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Dravion", systemImage: "point.3.connected.trianglepath.dotted").font(.system(size: 14, weight: .semibold)).foregroundStyle(accent)
                Spacer()
                if let snapshot = entry.snapshot { Text(snapshot.generatedAt, style: .relative).font(.system(size: 9)).foregroundStyle(.secondary) }
            }
            if let snapshot = entry.snapshot {
                HStack(spacing: 16) {
                    metric(snapshot.working, "执行中", .blue)
                    metric(snapshot.waiting, "等待中", .orange)
                    if family != .systemSmall { metric(snapshot.completed, "已完成", .green) }
                }
                if snapshot.tasks.isEmpty { Text("准备好迎接下一个想法").font(.system(size: 11)).foregroundStyle(.secondary) }
                ForEach(snapshot.tasks.prefix(family == .systemSmall ? 1 : family == .systemLarge ? 5 : 2)) { task in
                    if let url = URL(string: "relay://run/\(task.id)") {
                        Link(destination: url) {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(task.title).lineLimit(1); Spacer(); Text(task.stateLabel).foregroundStyle(.secondary) }.font(.system(size: 11))
                                ProgressView(value: Double(task.finished), total: Double(max(1, task.total))).tint(task.state == "succeeded" ? .green : accent)
                            }
                        }
                    }
                }
            } else {
                Spacer(minLength: 0)
                Text(entry.error ?? "你的团队，尽在掌握").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.widgetURL(URL(string: "relay://dashboard"))
    }
    private func metric(_ value: Int, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value, format: .number).font(.system(size: 23, weight: .semibold, design: .rounded)).foregroundStyle(color)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}
