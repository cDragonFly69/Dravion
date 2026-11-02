import SwiftUI
import AppKit
import Quartz
import RelayCore

// MARK: - Report feed

/// The group chat as employees reporting work, built from the run's own events and results — no extra model calls.
/// Tool calls are not shown one by one: they are folded into the next thing the employee says ("改了哪些文件、跑了几条
/// 命令、生成了哪些图片"). Plans, finished sub-tasks, checks, reviews and failures become plain-language messages.
struct RelayChatItem: Identifiable {
    enum Kind { case user, report, note }
    enum Tone { case info, done, problem, question }
    var id: String
    var kind: Kind
    var date: Date
    var roleID: String?
    var tone: Tone = .info
    var title: String?
    var body: String = ""
    var files: [String] = []
    var commands = 0
    var images: [URL] = []
    var attachments: [URL] = []
    var issues: [String] = []
    /// Offer "从失败处继续" under this message.
    var offersRetry = false
}

enum RelayChatFeed {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg"]

    static func items(_ run: RelayRun, events all: [RelayEvent]) -> [RelayChatItem] {
        let root = run.root.isEmpty ? run.project.path : run.root
        let events = all.filter { $0.kind != .usage }
        var items: [RelayChatItem] = []
        struct Work { var files: [String] = []; var commands = 0; var images: [URL] = []; var taskID: String?; var last: Date = .distantPast }
        var work: [String: Work] = [:]
        var lastNote = ""

        func flush(_ roleID: String, date: Date, text: String, tone: RelayChatItem.Tone, id: String) {
            let pending = work.removeValue(forKey: roleID) ?? Work()
            var item = RelayChatItem(id: id, kind: .report, date: date, roleID: roleID, tone: tone, body: text)
            item.files = pending.files; item.commands = pending.commands
            item.images = unique(pending.images + imagePaths(in: text, root: root))
            if let task = run.tasks.first(where: { $0.id == pending.taskID }) {
                item.title = task.status == .succeeded ? "完成了「\(task.task.title)」" : "「\(task.task.title)」进展"
                if task.status == .succeeded && tone == .info { item.tone = .done }
            }
            items.append(item)
        }

        for event in events {
            switch event.kind {
            case .input:
                let (text, files) = splitAttachments(event.message)
                var item = RelayChatItem(id: event.id, kind: .user, date: event.date, body: text)
                item.images = files.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
                item.attachments = files.filter { !imageExtensions.contains($0.pathExtension.lowercased()) }
                items.append(item)
            case .status:
                let text = plainStatus(event.message, run: run)
                guard !text.isEmpty, text != lastNote else { continue }
                lastNote = text
                items.append(.init(id: event.id, kind: .note, date: event.date, body: text))
            case .tool:
                guard let roleID = event.roleID else { continue }
                var entry = work[roleID] ?? Work()
                let facts = toolFacts(event.message, root: root)
                for file in facts.files where !entry.files.contains(file) { entry.files.append(file) }
                entry.commands += facts.command ? 1 : 0
                entry.images += facts.images
                if let task = event.taskID { entry.taskID = task }
                entry.last = event.date
                work[roleID] = entry
            case .text:
                guard let roleID = event.roleID else { continue }
                let text = cleanText(event.message)
                // The planner's structured answer is shown as the plan below, not as JSON.
                guard !text.isEmpty, !text.hasPrefix("{"), !text.hasPrefix("[") else { continue }
                if work[roleID]?.taskID == nil, let task = event.taskID { work[roleID, default: Work()].taskID = task }
                flush(roleID, date: event.date, text: text, tone: .info, id: event.id)
            case .error:
                let roleID = event.roleID ?? run.currentRoleID ?? ""
                flush(roleID, date: event.date, text: "我这边遇到了问题：\(event.message)", tone: .problem, id: event.id)
            case .test:
                items.append(.init(id: event.id, kind: .note, date: event.date, body: "本机测试：" + (event.message.components(separatedBy: "\n").first ?? "")))
            case .usage: break
            }
        }

        // Work done since the employee last spoke, by someone who is no longer working on it.
        for (roleID, pending) in work where !(run.status.isWorking && run.currentRoleID == roleID) && (!pending.files.isEmpty || pending.commands > 0) {
            let task = run.tasks.first { $0.id == pending.taskID }
            let finished = task?.status == .succeeded
            var item = RelayChatItem(id: "work-\(roleID)", kind: .report, date: pending.last, roleID: roleID, tone: finished ? .done : .info,
                                     title: task.map { finished ? "完成了「\($0.task.title)」" : "「\($0.task.title)」做到这里先停下" },
                                     body: task.map { $0.output.isEmpty ? "" : summary($0.output) } ?? "")
            item.files = pending.files; item.commands = pending.commands; item.images = unique(pending.images)
            items.append(item)
        }

        // The plan, from the planner, just before the first executor starts.
        if let plan = run.plan, run.input.directRoleID == nil {
            let firstWork = events.first { $0.roleID != nil && $0.roleID != run.input.plannerID }?.date ?? run.createdAt
            let lines = plan.tasks.enumerated().map { index, task in
                "\(index + 1). \(task.title) → \(run.roles.first { $0.id == task.roleId }?.name ?? task.roleId)"
            }
            var text = plan.summary.isEmpty ? "" : plan.summary + "\n\n"
            text += "分工如下：\n" + lines.joined(separator: "\n")
            if let stage = run.activeMilestone ?? run.nextMilestone, let milestones = run.milestones {
                text = "这是第 \(stage + 1)/\(milestones.count) 阶段「\(milestones[stage].title)」。\n" + text
            }
            items.append(.init(id: "plan", kind: .report, date: firstWork.addingTimeInterval(-0.001), roleID: run.input.plannerID,
                               title: "我把任务拆成了 \(plan.tasks.count) 项", body: text))
        }
        // Quality check and review, as reports from those employees.
        for (id, roleID, label, review) in [("quality", run.input.testerID, "质量检查", run.quality), ("review", run.input.reviewerID, "复审", run.review)] {
            guard let review else { continue }
            let date = events.last { $0.roleID == roleID }?.date ?? (run.endedAt ?? events.last?.date ?? run.createdAt)
            var item = RelayChatItem(id: id, kind: .report, date: date.addingTimeInterval(0.001), roleID: roleID,
                                     tone: review.passed ? .done : .problem,
                                     title: review.passed ? "\(label)通过" : "\(label)发现 \(review.issues.count) 个问题，需要返工",
                                     body: review.summary)
            item.issues = review.issues
            items.append(item)
        }
        if run.status == .failed {
            let roleID = run.currentRoleID
            var item = RelayChatItem(id: "failed", kind: .report, date: (run.endedAt ?? events.last?.date ?? run.createdAt), roleID: roleID, tone: .question,
                                     title: "这一步没做完，要我接着修吗？",
                                     body: (run.error ?? "任务失败。") + "\n\n可以从失败处继续：已完成的步骤、会话和文件都保留，只重做失败的这一步。")
            item.offersRetry = true
            items.append(item)
        }
        return items.sorted { $0.date < $1.date }
    }

    // MARK: Parsing

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    /// Files changed, whether a command ran, and image files written, from one tool record of any client.
    static func toolFacts(_ message: String, root: String) -> (files: [String], command: Bool, images: [URL]) {
        guard let data = message.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], false, []) }
        let input = json["input"] as? [String: Any] ?? [:]
        let path = (input["file_path"] ?? input["path"] ?? input["filePath"]) as? String ?? ""
        var written: [String] = []
        var command = false
        if let name = (json["name"] ?? json["tool"]) as? String {
            switch name.lowercased() {
            case "edit", "multiedit", "write", "write_file", "edit_file", "create", "create_file", "str_replace", "multi_edit", "apply_patch":
                if !path.isEmpty { written.append(path) }
            case "bash", "shell", "exec", "run_command", "terminal": command = true
            default: break
            }
        } else {
            let item = json["item"] as? [String: Any] ?? json
            switch item["type"] as? String {
            case "file_change": written = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            case "command_execution": command = true
            default: break
            }
        }
        let images = written.filter { imageExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            .map { URL(fileURLWithPath: $0.hasPrefix("/") ? $0 : root + "/" + $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return (written.map { relative($0, root: root) }, command, images)
    }

    /// Existing image files named by absolute path in a message ("截图在 /…/shot.png").
    static func imagePaths(in text: String, root: String) -> [URL] {
        guard text.contains("/") else { return [] }
        let pattern = #"(/[^\s`'"<>()（）「」，。]+\.(?:png|jpe?g|gif|webp|heic|tiff|bmp|svg))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { URL(fileURLWithPath: String(text[$0])) }
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static let attachmentHeader = "附件："
    /// A user message and the files attached to it (`附件：` followed by one path per line).
    static func splitAttachments(_ message: String) -> (String, [URL]) {
        guard let range = message.range(of: "\n\n" + attachmentHeader) ?? (message.hasPrefix(attachmentHeader) ? message.range(of: attachmentHeader) : nil) else {
            return (message, [])
        }
        let files = message[range.upperBound...].split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
        return (String(message[..<range.lowerBound]), files)
    }

    private static func relative(_ path: String, root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
    /// Drops client diagnostics ("[llm-…] model listing …") that are not the employee talking.
    static func cleanText(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { $0.range(of: #"^\s*\[[A-Za-z0-9_.:-]+\]\s"#, options: .regularExpression) == nil }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func summary(_ text: String) -> String {
        let lines = cleanText(text).components(separatedBy: "\n")
        return lines.prefix(12).joined(separator: "\n")
    }
    /// "DeepSeek · 工程师 · DeepSeek Harness · 客户端模型配置 · 续接已有会话" → "工程师 接着上次的会话开始干活".
    static func plainStatus(_ message: String, run: RelayRun) -> String {
        let parts = message.components(separatedBy: " · ")
        if parts.count >= 3, let role = run.roles.first(where: { message.hasPrefix($0.name) }) {
            let resumed = message.contains("续接")
            return "\(role.name) \(resumed ? "接着上次的会话" : "开新会话")开始工作"
        }
        return message.components(separatedBy: "\n").first ?? message
    }
}

// MARK: - Employee status bar

/// Who in this group is busy and with what, and what the others are waiting for — in a sentence each.
struct RelayGroupStatusBar: View {
    let model: RelayAppModel
    let run: RelayRun

    var body: some View {
        let roles = members
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(roles) { role in
                    let line = status(role)
                    HStack(spacing: 8) {
                        RelayAvatar(role: role, connection: run.connections.first { $0.id == role.connectionID }, active: line.busy, size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(role.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                Circle().fill(line.busy ? RelayPalette.green : line.waiting ? Color.orange : Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
                                Text(line.label).font(.system(size: 10)).foregroundStyle(line.busy ? RelayPalette.green : .secondary)
                            }
                            Text(line.text).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 230, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(line.busy ? RelayPalette.green.opacity(0.07) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .help(line.text)
                }
            }.padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private var members: [RelayRole] {
        let ids = [run.input.plannerID] + (run.input.directRoleID.map { [$0] } ?? run.input.executorIDs) + [run.input.testerID, run.input.reviewerID]
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }.compactMap { id in run.roles.first { $0.id == id } }
    }

    private func status(_ role: RelayRole) -> (busy: Bool, waiting: Bool, label: String, text: String) {
        let events = model.store.events[run.id] ?? []
        let mine = run.tasks.filter { $0.task.roleId == role.id }
        if run.status.isWorking, run.waitingForSession == nil, run.currentRoleID == role.id || mine.contains(where: { $0.status == .running }) {
            let task = mine.first { $0.status == .running }?.task.title ?? run.tasks.first { $0.id == run.currentTaskID }?.task.title
            let doing = events.last { $0.roleID == role.id && [.tool, .text].contains($0.kind) }.map { Self.plainAction(RelayEventLine.from($0)) }
            return (true, false, "忙碌", [task.map { "在做「\($0)」" }, doing].compactMap { $0 }.joined(separator: " · ").ifEmpty("正在\(run.phase.label)"))
        }
        if run.status.isTerminal {
            let done = mine.filter { $0.status == .succeeded }.count
            return (false, false, "空闲", done > 0 ? "这次完成了 \(done) 项，待命中" : "任务已结束，待命中")
        }
        if let pause = run.pause, run.currentRoleID == role.id {
            return (false, true, "等待", pause.message.components(separatedBy: "\n").first ?? "等待恢复")
        }
        // Busy elsewhere?
        let elsewhere = RelayEmployeeState.of(role, in: model.store.state, events: model.store.events)
        if elsewhere.kind == .working, elsewhere.runID != run.id {
            return (true, false, "忙碌", "在另一个任务里：\(elsewhere.headline)")
        }
        if role.id == run.input.plannerID, run.plan != nil { return (false, false, "空闲", "方案已拆好，等大家做完再看") }
        if role.id == run.input.testerID, run.stageIndex < 2 { return (false, false, "空闲", "等执行完成后做质量检查") }
        if role.id == run.input.reviewerID, run.stageIndex < 3 { return (false, false, "空闲", "等测试通过后做最终复审") }
        if let next = mine.first(where: { $0.status == .pending }) {
            let blockers = next.task.dependsOn.compactMap { id in run.tasks.first { $0.id == id && $0.status != .succeeded }?.task.title }
            return (false, !blockers.isEmpty, "待命", blockers.isEmpty ? "下一项：\(next.task.title)" : "等「\(blockers[0])」完成后做「\(next.task.title)」")
        }
        let done = mine.filter { $0.status == .succeeded }.count
        return (false, false, "空闲", done > 0 ? "已完成 \(done) 项，待命中" : "待命中")
    }

    /// One tool line as a person would say it.
    static func plainAction(_ line: RelayEventLine) -> String {
        let subject = line.body.components(separatedBy: "\n").first ?? ""
        let name = URL(fileURLWithPath: subject).lastPathComponent
        switch line.tone {
        case .command: return "在运行命令"
        case .read: return "在看 \(name)"
        case .write: return "在改 \(name)"
        case .search: return "在查找代码"
        case .text: return "在整理汇报"
        case .test: return "在跑测试"
        case .skill: return "在用技能 \(subject.components(separatedBy: " ").first ?? "")"
        default: return line.verb.isEmpty ? "在工作" : "在\(line.verb)"
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

// MARK: - Message views

struct RelayChatReportView: View {
    let model: RelayAppModel
    let run: RelayRun
    let item: RelayChatItem
    @State private var expanded = false

    var body: some View {
        switch item.kind {
        case .note:
            HStack {
                Spacer()
                Text("\(item.date.formatted(date: .omitted, time: .shortened)) · \(item.body)")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 3).background(Color.primary.opacity(0.04), in: Capsule())
                Spacer()
            }
        case .user: userBubble
        case .report: report
        }
    }

    private var userBubble: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 120)
            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary)
                    Text("你").font(.system(size: 11, weight: .semibold))
                }
                if !item.body.isEmpty {
                    Text(item.body).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(DravionBrand.solidInk, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(Color(nsColor: .textBackgroundColor))
                }
                if !item.images.isEmpty { RelayImageStrip(model: model, images: item.images) }
                ForEach(item.attachments, id: \.path) { RelayAttachmentChip(url: $0, model: model) }
            }
        }
    }

    private var report: some View {
        let role = run.roles.first { $0.id == item.roleID }
        let color = role.map { RelayStyle.color($0.color) } ?? .secondary
        let lines = item.body.components(separatedBy: "\n")
        let long = lines.count > 10 || item.body.count > 700
        return HStack(alignment: .top, spacing: 10) {
            RelayAvatar(role: role, connection: role.flatMap { r in run.connections.first { $0.id == r.connectionID } }, active: false, size: 32)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(role?.name ?? "调度器").font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                    if let role { Text(role.stage.label).font(.system(size: 10)).foregroundStyle(.tertiary) }
                    Text(item.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    if let title = item.title {
                        HStack(spacing: 6) {
                            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(toneColor)
                            Text(title).font(.system(size: 13, weight: .semibold))
                        }
                    }
                    if !item.body.isEmpty {
                        Text(Self.markdown(long && !expanded ? lines.prefix(10).joined(separator: "\n") : item.body))
                            .font(.system(size: 13)).lineSpacing(2).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if long {
                            Button(expanded ? "收起" : "展开全文") { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
                                .buttonStyle(.borderless).font(.system(size: 11))
                        }
                    }
                    if !item.issues.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(item.issues.enumerated()), id: \.offset) { _, issue in
                                Label { Text(issue).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) } icon: {
                                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    if !item.files.isEmpty { files }
                    if !item.images.isEmpty { RelayImageStrip(model: model, images: item.images) }
                    if item.offersRetry, run.status == .failed {
                        HStack(spacing: 8) {
                            Button("从失败处继续修复") { model.perform { try model.scheduler.continueFailed(run.id) } }.buttonStyle(.borderedProminent)
                            Button("在工作台查看") { model.selectRun(run.id) }.buttonStyle(.bordered)
                        }.font(.system(size: 12))
                    }
                }
                .padding(12)
                .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(item.tone == .info ? RelayStyle.border : toneColor.opacity(0.3)))
            }
            Spacer(minLength: 60)
        }
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("改了 \(item.files.count) 个文件" + (item.commands > 0 ? " · 运行了 \(item.commands) 条命令" : ""))
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            RelayFlow(spacing: 6) {
                ForEach(item.files.prefix(expanded ? 60 : 8), id: \.self) { path in
                    let root = run.root.isEmpty ? run.project.path : run.root
                    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: root).appendingPathComponent(path)
                    Button {
                        RelayFilePreview.open(url, model: model)
                    } label: {
                        HStack(spacing: 4) {
                            DravionIcon(name: "file-code", size: 11)
                            Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                        }
                        .font(.system(size: 11)).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                    }.buttonStyle(.plain).help(path + "\n点击预览；右键可查看所在位置")
                    .contextMenu {
                        Button("预览") { RelayFilePreview.open(url, model: model) }
                        Button("查看路径（在访达中显示）") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button("复制路径") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) }
                    }
                }
                if item.files.count > 8 && !expanded {
                    Button("+\(item.files.count - 8)") { expanded = true }.buttonStyle(.plain)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var icon: String {
        switch item.tone {
        case .done: return "checkmark.circle.fill"
        case .problem: return "exclamationmark.triangle.fill"
        case .question: return "questionmark.circle.fill"
        case .info: return "text.bubble"
        }
    }
    private var toneColor: Color {
        switch item.tone {
        case .done: return RelayPalette.green
        case .problem: return .orange
        case .question: return RelayPalette.violet
        case .info: return .secondary
        }
    }
    static func markdown(_ text: String) -> AttributedString {
        // Headings and list bullets as a person would write them in a chat, then inline markdown.
        let text = text.components(separatedBy: "\n").map { line -> String in
            if let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) { return "**" + line[range.upperBound...] + "**" }
            if let range = line.range(of: #"^(\s*)[-*]\s+"#, options: .regularExpression) {
                return line[range].replacingOccurrences(of: #"[-*]\s+$"#, with: "", options: .regularExpression) + "• " + line[range.upperBound...]
            }
            return line
        }.joined(separator: "\n")
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// Wrapping row of chips.
struct RelayFlow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { y += row + spacing; x = 0; row = 0 }
            x += size.width + spacing; row = max(row, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(width, widest), height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing; row = max(row, size.height)
        }
    }
}

// MARK: - Images and attachments

/// Thumbnails posted in a message; clicking one opens the gallery at that image.
struct RelayImageStrip: View {
    let model: RelayAppModel
    let images: [URL]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(images.prefix(4).enumerated()), id: \.offset) { index, url in
                Button {
                    model.present("gallery", width: 1000) { RelayImageGallery(model: model, images: images, index: index) }
                } label: {
                    ZStack {
                        RelayThumbnail(url: url).frame(width: images.count == 1 ? 260 : 120, height: images.count == 1 ? 170 : 90)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(RelayStyle.border))
                        if index == 3 && images.count > 4 {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.black.opacity(0.45))
                            Text("+\(images.count - 4)").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        }
                    }
                }.buttonStyle(.plain).help(url.lastPathComponent)
            }
        }
    }
}

struct RelayThumbnail: View {
    let url: URL
    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
        } else {
            ZStack { Color.primary.opacity(0.05); Image(systemName: "photo").foregroundStyle(.tertiary) }
        }
    }
}

/// Full-size image viewer with previous/next (buttons, ← →) and a thumbnail strip.
struct RelayImageGallery: View {
    let model: RelayAppModel
    let images: [URL]
    @State var index: Int
    var body: some View {
        let url = images[min(index, images.count - 1)]
        VStack(spacing: 0) {
            RelayOverlayHeader(icon: "files", title: url.lastPathComponent, subtitle: "\(index + 1) / \(images.count) · " + url.deletingLastPathComponent().path,
                               close: model.dismissOverlay) {
                Button("用预览打开") { NSWorkspace.shared.open(url) }.buttonStyle(.borderless).font(.system(size: 12))
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.borderless).font(.system(size: 12))
            }
            Divider().opacity(0.5)
            ZStack {
                Color.black.opacity(0.04)
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(16).id(url)
                        .transition(.opacity)
                } else {
                    Text("无法读取这张图片").foregroundStyle(.secondary)
                }
                HStack {
                    arrow("chevron.left", enabled: index > 0) { index -= 1 }.keyboardShortcut(.leftArrow, modifiers: [])
                    Spacer()
                    arrow("chevron.right", enabled: index < images.count - 1) { index += 1 }.keyboardShortcut(.rightArrow, modifiers: [])
                }.padding(.horizontal, 14)
            }
            .frame(height: 560)
            .animation(.easeInOut(duration: 0.18), value: index)
            if images.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(images.enumerated()), id: \.offset) { offset, item in
                            Button { index = offset } label: {
                                RelayThumbnail(url: item).frame(width: 72, height: 50).clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(offset == index ? Color.primary : .clear, lineWidth: 2))
                                    .opacity(offset == index ? 1 : 0.6)
                            }.buttonStyle(.plain)
                        }
                    }.padding(12)
                }
            }
        }
    }
    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 38, height: 38).background(.black.opacity(enabled ? 0.45 : 0.15), in: Circle())
        }.buttonStyle(.plain).disabled(!enabled)
    }
}

/// A non-image attachment: icon, name, size. Click previews it; "查看路径" shows it in Finder.
struct RelayAttachmentChip: View {
    let url: URL
    var model: RelayAppModel? = nil
    var remove: (() -> Void)? = nil
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(size).foregroundStyle(.secondary)
                    Button("查看路径") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).underline(hovering)
                }.font(.system(size: 10))
            }
            if let remove {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(hovering ? Color.primary.opacity(0.2) : RelayStyle.border))
        .contentShape(Rectangle())
        .onTapGesture { if let model { RelayFilePreview.open(url, model: model) } else { NSWorkspace.shared.open(url) } }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("预览") { if let model { RelayFilePreview.open(url, model: model) } }
            Button("用默认应用打开") { NSWorkspace.shared.open(url) }
            Button("查看路径（在访达中显示）") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .help("点击预览 · " + url.path)
    }
    private var size: String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        return bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "文件不存在"
    }
}

/// Any file previewed in place with Quick Look (code, text, PDF, images, office files…).
struct RelayFilePreview: View {
    let model: RelayAppModel
    let url: URL
    static func open(_ url: URL, model: RelayAppModel) {
        if RelayChatFeed.imageExtensions.contains(url.pathExtension.lowercased()) {
            model.present("gallery", width: 1000) { RelayImageGallery(model: model, images: [url], index: 0) }
        } else {
            model.present("preview-\(url.path)", width: 920) { RelayFilePreview(model: model, url: url) }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            RelayOverlayHeader(icon: "file-code", title: url.lastPathComponent, subtitle: url.deletingLastPathComponent().path, close: model.dismissOverlay) {
                Button("用默认应用打开") { NSWorkspace.shared.open(url) }.buttonStyle(.borderless).font(.system(size: 12))
                Button("查看路径") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.borderless).font(.system(size: 12))
            }
            Divider().opacity(0.5)
            if FileManager.default.fileExists(atPath: url.path) {
                RelayQuickLook(url: url).frame(height: 620)
            } else {
                Text("文件不存在：\(url.path)").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
            }
        }
    }
}

struct RelayQuickLook: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }
}

// MARK: - Pinned goal and assignments

/// Pinned above the messages: the task's goal and who was given what. A finished assignment carries a check,
/// "已完成" and "查看交付" (its output, files and record). Folds to one line.
struct RelayPinnedGoal: View {
    let model: RelayAppModel
    let run: RelayRun
    @AppStorage("chat.pinnedCollapsed") private var collapsed = false
    var body: some View {
        let done = run.tasks.filter { $0.status == .succeeded }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(RelayPalette.ember).rotationEffect(.degrees(35))
                Text("目标").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(run.input.goal.components(separatedBy: "\n").first ?? run.input.title).font(.system(size: 12.5, weight: .medium)).lineLimit(collapsed ? 1 : 2)
                Spacer(minLength: 8)
                if !run.tasks.isEmpty {
                    Text("分工 \(done)/\(run.tasks.count) 已完成").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                Button { withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() } } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(collapsed ? 0 : 180))
                }.buttonStyle(.plain).foregroundStyle(.tertiary).help(collapsed ? "展开分工" : "收起")
            }
            if !collapsed, !run.tasks.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(run.tasks.enumerated()), id: \.element.id) { index, item in row(index, item) }
                    }
                }.frame(maxHeight: min(CGFloat(run.tasks.count) * 27, 190))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RelayPalette.ember.opacity(0.04))
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private func row(_ index: Int, _ item: RelayWorkItem) -> some View {
        let role = run.roles.first { $0.id == item.task.roleId }
        let finished = item.status == .succeeded
        return HStack(spacing: 8) {
            Group {
                switch item.status {
                case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(RelayPalette.green)
                case .running: Image(systemName: "circle.dotted").foregroundStyle(RelayStyle.accent)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .paused: Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }.font(.system(size: 12))
            Text("\(index + 1). \(item.task.title)").font(.system(size: 12)).lineLimit(1)
                .foregroundStyle(item.status == .pending ? .secondary : .primary)
                .strikethrough(false)
            if canReassign(item) {
                RelayPillMenu(title: role?.name ?? item.task.roleId, icon: "arrow.triangle.swap", compact: true) { reassignMenu(item) }
                    .help("改派给其他员工；对方忙碌时可以排队，或多开一个会话马上执行")
            } else {
                Text("→ \(role?.name ?? item.task.roleId)").font(.system(size: 11)).foregroundStyle(role.map { RelayStyle.color($0.color) } ?? .secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if finished {
                Text("已完成").font(.system(size: 11, weight: .medium)).foregroundStyle(RelayPalette.green)
                Button("查看交付") {
                    let runID = run.id, taskID = item.id
                    model.present("task-\(taskID)", width: 860) { RelayTaskDetail(model: model, runID: runID, taskID: taskID) }
                }.buttonStyle(.borderless).font(.system(size: 11))
            } else if item.status == .pending, let role, let busy = busy(role, except: item.id) {
                Text("排队中 · \(role.name)忙碌").font(.system(size: 11)).foregroundStyle(.orange).help(busy)
            } else {
                Text(item.status.label).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private func canReassign(_ item: RelayWorkItem) -> Bool {
        !run.status.isTerminal && [.pending, .paused, .failed].contains(item.status)
    }

    /// What keeps `role` from starting now: a sub-task of theirs running here, or work in another task.
    private func busy(_ role: RelayRole, except taskID: String? = nil) -> String? {
        if let running = run.tasks.first(where: { $0.task.roleId == role.id && $0.status == .running && $0.id != taskID }) {
            return "正在做「\(running.task.title)」"
        }
        let state = RelayEmployeeState.of(role, in: model.store.state, events: model.store.events)
        if state.kind == .working, state.runID != run.id { return "在另一个任务里：\(state.headline)" }
        return nil
    }

    @ViewBuilder private func reassignMenu(_ item: RelayWorkItem) -> some View {
        let current = run.roles.first { $0.id == item.task.roleId }
        let others = (run.roles + model.store.state.roles.filter { r in r.enabled && !run.roles.contains { $0.id == r.id } })
            .filter { role in role.id != item.task.roleId && (role.stage == .executor || run.roles.contains { $0.id == role.id }) }
        Text("「\(item.task.title)」交给谁").font(.system(size: 11))
        Divider()
        ForEach(others) { role in
            if let busy = busy(role) {
                Menu("\(role.name) · 忙碌") {
                    Text(busy)
                    Button("排在他当前的工作之后") { reassign(item, to: role.id, newSession: false) }
                    Button("多开一个会话，马上执行") { reassign(item, to: role.id, newSession: true) }
                }
            } else {
                Button("\(role.name) · 空闲") { reassign(item, to: role.id, newSession: false) }
            }
        }
        if let current {
            Divider()
            Button("给 \(current.name) 多开一个会话执行") { reassign(item, to: current.id, newSession: true) }
                .disabled(busy(current, except: item.id) == nil)
        }
    }

    /// Hands the sub-task over; a run paused by the user or a recoverable stop resumes so the new employee starts.
    private func reassign(_ item: RelayWorkItem, to roleID: String, newSession: Bool) {
        let runID = run.id
        Task {
            do {
                let holder = try await model.scheduler.reassignTask(runID, taskID: item.id, roleID: roleID, newSession: newSession)
                let current = try model.store.run(runID)
                let name = current.roles.first { $0.id == holder }?.name ?? holder
                if (current.status == .paused || current.status == .interrupted), current.pendingQuestion == nil,
                   current.externalTurnUnconfirmed != true, current.pause?.reason != .milestone, current.pause?.reason != .budget {
                    try model.scheduler.resume(runID)
                    model.notice = "「\(item.task.title)」已交给 \(name)，任务已继续。"
                } else {
                    model.notice = "「\(item.task.title)」已交给 \(name)" + (current.status.isWorking ? "，轮到时开始。" : "。")
                }
            } catch { model.error = model.store.redact(error.localizedDescription) }
        }
    }
}
