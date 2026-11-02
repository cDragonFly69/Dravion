import Foundation
import WidgetKit
import RelayCore
import RelayWidgetShared

@MainActor enum RelayWidgetPublisher {
    private static var lastTasks: [RelayRun] = []
    static func publish(_ runs: [RelayRun]) throws {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PulseAppGroup") as? String else { return }
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw RelayError.invalid("无法打开 Dravion 小组件共享目录。请检查应用签名。")
        }
        guard runs != lastTasks || !FileManager.default.fileExists(atPath: directory.appendingPathComponent("relay-tasks.json").path) else { return }
        let pending = runs.filter { !$0.status.isTerminal }
        let recent = pending + runs.filter { $0.status.isTerminal }
        let snapshot = RelayTaskSnapshot(generatedAt: Date(), working: runs.filter { $0.status.isWorking }.count,
            waiting: pending.filter { !$0.status.isWorking }.count, completed: runs.filter { $0.status == .succeeded }.count,
            tasks: recent.prefix(8).map { .init(id: $0.id, title: $0.input.title, state: $0.status.rawValue, stateLabel: $0.status.label, finished: $0.finishedTasks, total: $0.tasks.count) })
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("relay-tasks.json")
        try RelayJSON.encoder().encode(snapshot).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        lastTasks = runs
        WidgetCenter.shared.reloadTimelines(ofKind: "RelayTaskProgress")
    }
}
