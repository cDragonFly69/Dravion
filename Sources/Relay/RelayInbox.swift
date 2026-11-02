import Foundation
import RelayCore

/// One request dropped into the inbox. Roles and projects may be named by id or by their display name;
/// anything left out falls back to the defaults in 调度设置, exactly as a new task in the UI does.
struct RelayInboxCommand: Decodable {
    var action: String            // create | stop | resume | retry | answer | confirm | instruct | extend | grant | remember | status | show | add-project
    var section: String?          // show: dashboard | chat | team | settings … (RelaySection case name)
    var title: String?
    var goal: String?
    var project: String?          // project id, name or directory
    var planner: String?
    var executors: [String]?
    var tester: String?
    var reviewer: String?
    var budgetMinutes: Int?
    var reworkLimit: Int?
    var run: String?              // run id or a unique prefix, for stop / resume / retry
    var group: String?            // project group id or name; fills project/roles that are left out
    var staged: Bool?             // false = one stage, no milestone stops
    var text: String?             // answer / instruct text, a rewritten goal for confirm, or the note for remember
    var minutes: Int?             // extend: minutes to add; 0 = no limit
    var role: String?             // instruct: role id or name; omitted = all roles
}

/// Local automation entry for the desktop app: a JSON file in `<data>/inbox` is handled like the matching
/// button (新建任务 / 停止 / 恢复) and goes through the same scheduler, validation and preflight. The data
/// directory is private to the user (0700); nothing listens on the network. Each request is moved to
/// `inbox/done/` next to `<name>.result.json`, which records the outcome.
@MainActor final class RelayInbox {
    private let model: RelayAppModel
    private let directory: URL
    private var timer: Timer?
    private var busy = false
    private static let pollSeconds: TimeInterval = 2
    private static let maxRequestBytes = 256 * 1024

    init(model: RelayAppModel, root: URL) {
        self.model = model
        directory = root.appendingPathComponent("inbox", isDirectory: true)
    }

    func start() {
        let manager = FileManager.default
        for url in [directory, directory.appendingPathComponent("done", isDirectory: true)] {
            try? manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
    }

    private func poll() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var result: [String: Any] = ["request": file.lastPathComponent, "handledAt": ISO8601DateFormatter().string(from: Date())]
            do {
                let data = try Data(contentsOf: file)
                guard data.count <= Self.maxRequestBytes else { throw RelayError.invalid("请求超过 256 KB。") }
                let command = try JSONDecoder().decode(RelayInboxCommand.self, from: data)
                result.merge(try await handle(command)) { _, new in new }
                result["ok"] = true
            } catch {
                result["ok"] = false
                result["error"] = model.store.redact(error.localizedDescription)
            }
            let done = directory.appendingPathComponent("done", isDirectory: true)
            let stem = file.deletingPathExtension().lastPathComponent
            if let json = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? json.write(to: done.appendingPathComponent(stem + ".result.json"), options: .atomic)
            }
            let target = done.appendingPathComponent(file.lastPathComponent)
            try? manager.removeItem(at: target)
            try? manager.moveItem(at: file, to: target)
        }
    }

    private func handle(_ command: RelayInboxCommand) async throws -> [String: Any] {
        switch command.action {
        case "create":
            let input = try runInput(command)
            let run = try await model.scheduler.create(input)
            model.selectRun(run.id)
            return ["runID": run.id, "status": run.status.rawValue]
        case "retry":
            // 重新运行: a new run from the current files, like the button on a finished task.
            let next = try await model.scheduler.retry(try findRun(command.run).id)
            model.selectRun(next.id)
            return ["runID": next.id, "status": next.status.rawValue]
        case "stop", "resume":
            let run = try command.run == nil ? waitingRun() : findRun(command.run)
            if command.action == "stop" {
                if run.pause?.reason == .milestone { try model.scheduler.endAtMilestone(run.id) } else { try model.scheduler.stop(run.id) }
            } else { try model.scheduler.resume(run.id) }
            return outcome(run.id)
        case "answer":
            let run = try command.run == nil ? waitingRun() : findRun(command.run)
            guard let question = run.pendingQuestion else { throw RelayError.invalid("任务 #\(run.id.prefix(6)) 没有等待回答的问题。") }
            try model.scheduler.answer(run.id, questionID: question.id, text: command.text ?? "")
            return outcome(run.id)
        case "confirm":
            let run = try command.run == nil ? waitingRun() : findRun(command.run)
            try model.scheduler.confirmMilestone(run.id, goal: command.text)
            return outcome(run.id)
        case "instruct":
            let run = try command.run == nil ? waitingRun() : findRun(command.run)
            let role = try command.role.map { name in
                guard let found = run.roles.first(where: { $0.id == name || $0.name == name }) else { throw RelayError.invalid("任务中没有角色 \(name)。") }
                return found.id
            }
            try model.scheduler.addInstruction(run.id, text: command.text ?? "", roleID: role)
            return outcome(run.id)
        case "extend":
            let run = try command.run == nil ? waitingRun() : findRun(command.run)
            try model.scheduler.extendBudget(run.id, minutes: (command.minutes ?? 0) == 0 ? nil : command.minutes)
            return outcome(run.id)
        case "grant":
            let run = try command.run == nil ? waitingRun() : findRun(command.run)
            let denied = RelaySandboxHint.directories(for: run, events: model.store.events[run.id] ?? [])
            guard let directory = command.text ?? denied.first else { throw RelayError.invalid("没有找到需要授权的目录。") }
            try model.scheduler.grantWritable(run.id, path: directory, remember: true)
            return outcome(run.id)
        case "add-project":
            // Registers a directory as a project, like 添加项目: name in `title`, test command in `text`.
            guard let path = command.project.map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }),
                  FileManager.default.fileExists(atPath: path) else { throw RelayError.invalid("add-project 需要一个已存在的目录。") }
            if let existing = model.store.state.projects.first(where: { $0.path == path }) { return ["projectID": existing.id] }
            let project = RelayProject(name: command.title ?? URL(fileURLWithPath: path).lastPathComponent, path: path, testCommand: command.text ?? "")
            try model.store.saveProject(project)
            return ["projectID": project.id]
        case "delete-project":
            // Same as the sidebar's 删除项目: its runs are archived (recoverable), the folder's files are untouched.
            let key = command.project ?? command.title ?? ""
            guard let project = model.store.state.projects.first(where: { $0.id == key || $0.name == key }) else { throw RelayError.invalid("找不到项目 \(key)。") }
            guard !model.store.state.runs.contains(where: { $0.project.id == project.id && !$0.status.isTerminal }) else { throw RelayError.invalid("该项目仍有未结束任务。") }
            for run in model.store.state.runs where run.project.id == project.id && run.archivedAt == nil { try model.store.setArchived(run.id, true) }
            try model.store.deleteProject(project.id)
            if model.selectedRun?.project.id == project.id { model.selectedRunID = nil }
            return ["projectID": project.id, "path": project.path]
        case "show":
            // Brings a page to the front (demos, scripted walkthroughs); changes nothing else.
            if let name = command.section, let target = RelaySection.allCases.first(where: { "\($0)" == name }) { model.section = target }
            else if command.section == "team" { model.openWorkbench(.people) }  // 员工与分工 is now 员工
            if let id = command.run { let run = try findRun(id); model.selectedRunID = run.id; _ = try model.store.loadEvents(run.id, fullHistory: true) }
            return ["section": "\(model.section)"]
        case "remember":
            // WeChat remote “记下来：…” (K1): the text goes in verbatim, with no model call (KAC05). The store owns
            // trimming, the empty-text error and the added/existing/blocked wording; the inbox only returns its fields.
            guard let knowledge = model.knowledge else { throw RelayError.invalid(model.knowledgeError ?? "知识库没有打开，这条没有记录。") }
            let remembered = try knowledge.remoteRemember(command.text ?? "")
            return ["cardID": remembered.cardID, "title": remembered.title, "summary": remembered.summary]
        case "status":
            let runs = model.store.state.runs.filter { $0.archivedAt == nil }.prefix(6)
            let summary = runs.map { run in
                "#\(run.id.prefix(6)) \(run.input.title)：\(run.activityLabel) · \(run.finishedTasks)/\(run.tasks.count) 子任务"
                    + (run.milestones.map { list in " · 里程碑 \(list.filter { $0.status == .done }.count)/\(list.count)" } ?? "")
            }.joined(separator: "\n")
            return ["summary": summary.isEmpty ? "没有进行中的任务。" : summary]
        default:
            throw RelayError.invalid("未知操作 \(command.action)；可用 create、stop、resume、retry、answer、confirm、instruct、extend、grant、remember、status、show。")
        }
    }

    private func runInput(_ command: RelayInboxCommand) throws -> RelayRunInput {
        let state = model.store.state
        guard let goal = command.goal?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty else {
            throw RelayError.invalid("请填写 goal。")
        }
        let group: RelayGroup? = try command.group.map { wanted in
            guard let found = state.groupList.first(where: { $0.id == wanted || $0.name == wanted }) else {
                throw RelayError.invalid("找不到项目群 \(wanted)；请用项目群的 id 或名称。")
            }
            return found
        }
        let wanted = command.project ?? group?.projectID
        guard let wanted, let project = state.projects.first(where: { project in
            project.id == wanted || project.name == wanted
                || URL(fileURLWithPath: project.path).standardizedFileURL.path == URL(fileURLWithPath: (wanted as NSString).expandingTildeInPath).standardizedFileURL.path
        }) else { throw RelayError.invalid("找不到项目 \(command.project ?? "")；请用项目 id、名称或目录。") }
        func role(_ name: String?, fallback: String) throws -> String {
            guard let name, !name.isEmpty else { return fallback }
            guard let found = state.roles.first(where: { $0.id == name || $0.name == name }) else { throw RelayError.invalid("找不到角色 \(name)。") }
            return found.id
        }
        let routing = state.routing
        let title = command.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RelayRunInput(
            title: (title?.isEmpty ?? true) ? String(goal.prefix(50)) : title!,
            goal: goal, projectID: project.id,
            plannerID: try role(command.planner, fallback: group?.plannerID ?? routing.coordinatorID),
            executorIDs: try command.executors.map { try $0.map { try role($0, fallback: "") } }
                ?? (group.map(\.executorIDs).flatMap { $0.isEmpty ? nil : $0 } ?? routing.executorIDs),
            testerID: try role(command.tester, fallback: group?.testerID ?? routing.testerID),
            reviewerID: try role(command.reviewer, fallback: group?.reviewerID ?? routing.reviewerID),
            budgetMinutes: command.budgetMinutes ?? 30, reworkLimit: command.reworkLimit ?? 1,
            groupID: group?.id, staged: command.staged)
    }

    private func outcome(_ id: String) -> [String: Any] {
        guard let run = try? model.store.run(id) else { return ["runID": id] }
        return ["runID": run.id, "status": run.status.rawValue, "summary": "#\(run.id.prefix(6)) \(run.input.title)：\(run.activityLabel)"]
    }
    /// The task a reply without a tag is about: the one waiting for the user (a question first), newest first.
    private func waitingRun() throws -> RelayRun {
        let runs = model.store.state.runs.filter { $0.archivedAt == nil }
        if let run = runs.first(where: { $0.pendingQuestion != nil }) ?? runs.first(where: { $0.status == .paused || $0.status == .interrupted })
            ?? runs.first(where: { $0.status == .failed }) ?? runs.first(where: { !$0.status.isTerminal }) { return run }
        throw RelayError.invalid("没有等待你处理的任务；请带上任务号，例如 #1a2b3c。")
    }
    private func findRun(_ id: String?) throws -> RelayRun {
        guard let id, !id.isEmpty else { throw RelayError.invalid("请填写 run。") }
        let matches = model.store.state.runs.filter { $0.id == id || $0.id.hasPrefix(id) }
        guard matches.count == 1 else { throw RelayError.invalid(matches.isEmpty ? "找不到任务 \(id)。" : "任务前缀 \(id) 不唯一。") }
        return matches[0]
    }
}
