import SwiftUI
import RelayCore

/// A session row from the usage page, opened: its client session ID, where the record lives, what it cost, and
/// the conversation itself read from the client's own transcript (read-only; nothing is sent anywhere).
struct RelaySessionDetail: View {
    let model: RelayAppModel
    let row: SpendSummary.Session
    let projectName: String?
    @Environment(\.dismiss) private var dismiss
    @State private var transcript: RelayTranscript?
    @State private var shown = 200
    @State private var query = ""

    private var session: UsageLedger.Session { row.session }
    private var fileExists: Bool { FileManager.default.fileExists(atPath: session.id) }
    private var provider: RelayProviderKind? {
        switch row.agent {
        case .claudeCode: return .claude
        case .codex: return .codex
        default: return nil
        }
    }
    private var sessionID: String { transcript?.sessionID ?? RelayTranscript.idFromName(session.name) }

    var body: some View {
        VStack(spacing: 0) {
            RelaySheetHeader(title: "会话详情", close: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.label(projectName: projectName)).font(.title3.weight(.semibold)).lineLimit(2)
                        Text([row.agent.displayName, projectName, session.start.formatted(date: .abbreviated, time: .shortened) + " – " + session.end.formatted(date: .omitted, time: .shortened)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    identity
                    conversation
                }.padding(24)
            }
        }
        .frame(width: 900, height: 760).background(RelayStyle.canvas)
        .task(id: session.id) {
            guard fileExists else { return }
            let path = session.id
            transcript = await Task.detached(priority: .userInitiated) { RelayTranscript.read(path) }.value
        }
    }

    private var identity: some View {
        RelayCard {
            VStack(alignment: .leading, spacing: 12) {
                row("会话 ID", sessionID, mono: true, copy: true)
                if session.name != sessionID { row("记录名", session.name, mono: true, copy: false) }
                row("记录位置", session.id, mono: true, copy: true)
                if let model = transcript?.model { row("模型", model, mono: true, copy: false) }
                if let cwd = transcript?.directory ?? session.project?.name { row("目录", cwd, mono: true, copy: false) }
                row("用量", "\(TokenCount.short(session.tokens)) tokens · " + (session.estimatedCost.map { SpendFormat.money($0) } ?? "未定价"), mono: false, copy: false)
                Divider().opacity(0.5)
                HStack(spacing: 12) {
                    if let provider { RelaySessionActions(model: self.model, provider: provider, sessionID: sessionID) }
                    if fileExists {
                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.id)]) }
                            .font(.system(size: 11)).buttonStyle(.borderless)
                    }
                    Spacer()
                }
            }
        }
    }

    private func row(_ label: String, _ value: String, mono: Bool, copy: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).font(.system(size: 12, design: mono ? .monospaced : .default)).textSelection(.enabled).lineLimit(3)
            Spacer(minLength: 8)
            if copy {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("复制")
            }
        }
    }

    @ViewBuilder private var conversation: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("会话内容").font(.headline)
                if let transcript { Text("\(transcript.entries.count) 条").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                TextField("搜索", text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            if !fileExists {
                Text("\(row.agent.displayName) 的这条记录不是单独的文件（例如数据库或导出汇总），这里无法展开内容。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else if let transcript {
                let matching = query.isEmpty ? transcript.entries : transcript.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
                if transcript.truncated {
                    Text("记录较大，只读取了最后 \(RelayTranscript.maxBytes / 1_000_000) MB。").font(.caption).foregroundStyle(.orange)
                }
                if matching.isEmpty {
                    Text(query.isEmpty ? "没有识别出对话内容。可在访达中查看原始记录。" : "没有匹配的内容").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if matching.count > shown {
                    Button("加载更早的 \(min(200, matching.count - shown)) 条（共 \(matching.count) 条）") { shown += 200 }.buttonStyle(.borderless)
                }
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(matching.suffix(shown)) { entry in RelayTranscriptBubble(entry: entry) }
                }
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在读取记录…").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct RelayTranscriptBubble: View {
    let entry: RelayTranscript.Entry
    @State private var expanded = false
    var body: some View {
        let lines = entry.text.components(separatedBy: "\n")
        let limit = entry.kind == .user || entry.kind == .assistant ? 30 : 12
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(entry.kind.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(entry.kind == .user ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                if let title = entry.title { Text(title).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                Spacer()
                if let date = entry.date { Text(date.formatted(date: .omitted, time: .standard)).font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit() }
            }
            Group {
                if entry.kind == .tool || entry.kind == .result {
                    Text(RelaySyntaxText.render((expanded ? lines : Array(lines.prefix(limit))).joined(separator: "\n"), code: true))
                        .font(.system(size: 11, design: .monospaced))
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(GhosttyPalette.background, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text((expanded ? lines : Array(lines.prefix(limit))).joined(separator: "\n")).font(.system(size: 13))
                }
            }.textSelection(.enabled)
            if lines.count > limit {
                Button(expanded ? "收起" : "展开全部 \(lines.count) 行") { expanded.toggle() }.buttonStyle(.borderless).font(.system(size: 11))
            }
        }
        .padding(12)
        .background(entry.kind == .user ? Color.primary.opacity(0.05) : RelayStyle.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RelayStyle.border))
    }
}

/// Claude Code and Codex JSONL transcripts reduced to readable turns. Other clients' JSONL falls back to any
/// `text`/`content` strings it can find; nothing is written back.
struct RelayTranscript: Sendable {
    struct Entry: Identifiable, Sendable {
        enum Kind: Sendable { case user, assistant, thinking, tool, result, system
            var label: String {
                switch self {
                case .user: return "用户"
                case .assistant: return "助手"
                case .thinking: return "思考"
                case .tool: return "工具调用"
                case .result: return "工具结果"
                case .system: return "系统"
                }
            }
        }
        var id: Int
        var kind: Kind
        var title: String?
        var text: String
        var date: Date?
    }
    static let maxBytes = 24_000_000
    var entries: [Entry] = []
    var sessionID: String?
    var model: String?
    var directory: String?
    var truncated = false

    /// The trailing UUID of a record name (Codex `rollout-…-<uuid>`), else the name itself (Claude's uuid).
    static func idFromName(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        if let range = base.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) {
            return String(base[range])
        }
        return base
    }

    static func read(_ path: String) -> RelayTranscript {
        var result = RelayTranscript()
        guard let handle = FileHandle(forReadingAtPath: path) else { return result }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size > UInt64(maxBytes) { result.truncated = true; try? handle.seek(toOffset: size - UInt64(maxBytes)) } else { try? handle.seek(toOffset: 0) }
        guard let data = try? handle.readToEnd() else { return result }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        if result.truncated, !lines.isEmpty { lines.removeFirst() }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        func date(_ value: Any?) -> Date? {
            guard let text = value as? String else { return nil }
            return iso.date(from: text) ?? isoPlain.date(from: text)
        }
        func add(_ kind: Entry.Kind, _ text: String, title: String? = nil, at: Date?) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            result.entries.append(.init(id: result.entries.count, kind: kind, title: title, text: String(trimmed.prefix(40_000)), date: at))
        }
        func compact(_ value: Any?) -> String {
            if let text = value as? String { return text }
            guard let value, JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        func blocks(_ content: Any?) -> [[String: Any]] {
            if let text = content as? String { return [["type": "text", "text": text]] }
            return content as? [[String: Any]] ?? []
        }
        for line in lines {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            let at = date(json["timestamp"])
            // Claude Code: {"type":"user|assistant","message":{"role","content","model"},"sessionId","cwd"}
            if let message = json["message"] as? [String: Any], let type = json["type"] as? String, type == "user" || type == "assistant" {
                if result.sessionID == nil { result.sessionID = json["sessionId"] as? String }
                if result.directory == nil { result.directory = json["cwd"] as? String }
                if let model = message["model"] as? String, !model.hasPrefix("<") { result.model = model }
                for block in blocks(message["content"]) {
                    switch block["type"] as? String {
                    case "text": add(type == "user" ? .user : .assistant, block["text"] as? String ?? "", at: at)
                    case "thinking": add(.thinking, block["thinking"] as? String ?? "", at: at)
                    case "tool_use": add(.tool, compact(block["input"]), title: block["name"] as? String, at: at)
                    case "tool_result":
                        let content = block["content"]
                        let text = (content as? String) ?? blocks(content).compactMap { $0["text"] as? String }.joined(separator: "\n")
                        add(.result, text, title: block["is_error"] as? Bool == true ? "错误" : nil, at: at)
                    default: break
                    }
                }
                continue
            }
            // Codex rollout: {"timestamp","type":"session_meta|turn_context|response_item|event_msg","payload":{…}}
            if let payload = json["payload"] as? [String: Any], let type = json["type"] as? String {
                switch type {
                case "session_meta":
                    result.sessionID = payload["id"] as? String ?? result.sessionID
                    result.directory = payload["cwd"] as? String ?? result.directory
                case "turn_context":
                    if let model = payload["model"] as? String { result.model = model }
                case "response_item":
                    switch payload["type"] as? String {
                    case "message":
                        let role = payload["role"] as? String
                        let text = blocks(payload["content"]).compactMap { $0["text"] as? String }.joined(separator: "\n")
                        // Codex replays its instructions and environment as user messages; keep them, labelled as system.
                        let system = role == "developer" || role == "system" || text.hasPrefix("<environment_context>") || text.hasPrefix("<user_instructions>") || text.hasPrefix("# AGENTS.md")
                        add(system ? .system : role == "user" ? .user : .assistant, text, at: at)
                    case "reasoning":
                        let summary = (payload["summary"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                        add(.thinking, summary, at: at)
                    case "function_call", "custom_tool_call", "local_shell_call":
                        var arguments = payload["arguments"] as? String ?? payload["input"] as? String ?? compact(payload["action"])
                        if let data = arguments.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            if let command = object["command"] as? [String] { arguments = command.joined(separator: " ") }
                            else if let command = object["cmd"] as? String ?? object["command"] as? String { arguments = command }
                        }
                        add(.tool, arguments, title: payload["name"] as? String ?? "shell", at: at)
                    case "function_call_output", "custom_tool_call_output":
                        var output = payload["output"] as? String ?? compact(payload["output"])
                        if let data = output.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let inner = object["output"] as? String { output = inner }
                        add(.result, output, at: at)
                    default: break
                    }
                default: break
                }
                continue
            }
            // Anything else: a role and some text, if the line has them.
            let role = json["role"] as? String ?? json["type"] as? String
            let text = (json["text"] as? String) ?? (json["content"] as? String) ?? blocks(json["content"]).compactMap { $0["text"] as? String }.joined(separator: "\n")
            add(role == "user" ? .user : role == "assistant" ? .assistant : .system, text, title: role.flatMap { ["user", "assistant"].contains($0) ? nil : $0 }, at: at)
        }
        return result
    }
}
