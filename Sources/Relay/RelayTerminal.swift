import SwiftUI
import RelayCore

/// Ghostty 1.3.1 default colours (`ghostty +show-config --default`): background, foreground and the 16-colour
/// palette. The run log is drawn in these so it reads like the terminal the user works in.
enum GhosttyPalette {
    static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
    static let background = hex(0x282C34)
    static let foreground = hex(0xFFFFFF)
    static let black = hex(0x1D1F21), red = hex(0xCC6666), green = hex(0xB5BD68), yellow = hex(0xF0C674)
    static let blue = hex(0x81A2BE), magenta = hex(0xB294BB), cyan = hex(0x8ABEB7), white = hex(0xC5C8C6)
    static let brightBlack = hex(0x666666), brightRed = hex(0xD54E53), brightGreen = hex(0xB9CA4A), brightYellow = hex(0xE7C547)
    static let brightBlue = hex(0x7AA6DA), brightMagenta = hex(0xC397D8), brightCyan = hex(0x70C0B1), brightWhite = hex(0xEAEAEA)
}

/// One event turned into what a person reads in a terminal: a verb ("$", "读取", "修改"…), its subject, and a colour.
struct RelayEventLine: Identifiable {
    enum Tone { case command, read, write, search, text, status, error, usage, input, test, skill }
    var id: String
    var date: Date
    var roleID: String?
    var tone: Tone
    var verb: String
    var body: String

    static func from(_ event: RelayEvent) -> RelayEventLine {
        let base = { (tone: Tone, verb: String, body: String) in
            RelayEventLine(id: event.id, date: event.date, roleID: event.roleID, tone: tone, verb: verb, body: body)
        }
        switch event.kind {
        case .error: return base(.error, "错误", event.message)
        case .status: return base(.status, "状态", event.message)
        case .usage: return base(.usage, "用量", event.message)
        case .input: return base(.input, "指令", event.message)
        case .test: return base(.test, "测试", event.message)
        case .text: return base(.text, "", event.message)
        case .tool:
            guard let data = event.message.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return base(.command, "工具", event.message) }
            let (tone, verb, body) = describeTool(json)
            return base(tone, verb, body)
        }
    }

    /// Claude Code `tool_use` blocks and Codex `item` records, reduced to an action and its target.
    private static func describeTool(_ json: [String: Any]) -> (Tone, String, String) {
        // Skill use reads as such, whichever way the client loaded it (see `RelaySkills.name`).
        if let skill = RelaySkills.name(fromTool: json) {
            let input = json["input"] as? [String: Any] ?? [:]
            let args = (input["args"] as? String).map { "  " + $0 } ?? ""
            return (.skill, "技能", skill + args)
        }
        let input = json["input"] as? [String: Any] ?? [:]
        let string = { (key: String) in input[key] as? String ?? "" }
        if let name = json["name"] as? String {
            switch name {
            case "Bash": return (.command, "$", string("command"))
            case "Read": return (.read, "读取", string("file_path"))
            case "Edit", "MultiEdit":
                let edits = input["edits"] as? [[String: Any]] ?? [input]
                let diff = edits.map { edit in
                    let old = (edit["old_string"] as? String ?? "").components(separatedBy: "\n").map { "-" + $0 }
                    let new = (edit["new_string"] as? String ?? "").components(separatedBy: "\n").map { "+" + $0 }
                    return (old + new).joined(separator: "\n")
                }.joined(separator: "\n")
                return (.write, "修改", string("file_path") + "\n" + diff)
            case "Write": return (.write, "写入", string("file_path") + "\n" + string("content"))
            case "Glob": return (.search, "查找", [string("pattern"), string("path")].filter { !$0.isEmpty }.joined(separator: "  in "))
            case "Grep": return (.search, "搜索", [string("pattern"), string("path")].filter { !$0.isEmpty }.joined(separator: "  in "))
            case "StructuredOutput": return (.status, "提交", "结构化结果")
            default:
                let compact = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
                return (.command, name, compact)
            }
        }
        // DeepSeek Harness and other harnesses: {"type":"tool_call","tool":"bash","input":{…}}.
        if let tool = json["tool"] as? String {
            let path = string("file_path").isEmpty ? (string("path").isEmpty ? string("filePath") : string("path")) : string("file_path")
            switch tool.lowercased() {
            case "bash", "shell", "exec", "run_command", "terminal": return (.command, "$", string("command").isEmpty ? string("cmd") : string("command"))
            case "read", "read_file", "view", "cat": return (.read, "读取", path)
            case "write", "write_file", "create", "create_file": return (.write, "写入", path)
            case "edit", "edit_file", "str_replace", "multi_edit", "apply_patch", "patch": return (.write, "修改", path.isEmpty ? string("patch") : path)
            case "grep", "search", "rg": return (.search, "搜索", [string("pattern"), path].filter { !$0.isEmpty }.joined(separator: "  in "))
            case "glob", "ls", "list", "list_dir", "find": return (.search, "查找", [string("pattern"), path].filter { !$0.isEmpty }.joined(separator: "  in "))
            default:
                let compact = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
                return (.command, tool, compact)
            }
        }
        let item = json["item"] as? [String: Any] ?? json
        switch item["type"] as? String {
        case "command_execution":
            let command = item["command"] as? String ?? ""
            let output = item["aggregated_output"] as? String ?? item["aggregatedOutput"] as? String ?? ""
            let code = (item["exit_code"] as? Int ?? item["exitCode"] as? Int).map { "\n退出码 \($0)" } ?? ""
            return (.command, "$", command + (output.isEmpty ? "" : "\n" + output) + code)
        case "file_change":
            let paths = (item["changes"] as? [[String: Any]] ?? []).map { ($0["path"] as? String ?? "") + (($0["diff"] as? String).map { "\n" + $0 } ?? "") }
            return (.write, "修改", paths.joined(separator: "  "))
        case "tool_result":
            let content = item["content"] as? String ?? item["output"] as? String ?? (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            return (item["is_error"] as? Bool == true ? .error : .text, "输出", content)
        case "error": return (.error, "错误", item["message"] as? String ?? "")
        case "agent_message", "reasoning": return (.text, "", item["text"] as? String ?? "")
        default:
            let text = (try? JSONSerialization.data(withJSONObject: item, options: [.prettyPrinted, .sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
            return (.command, "工具", text ?? String(describing: item))
        }
    }

    var color: Color {
        switch tone {
        case .command: return GhosttyPalette.green
        case .read: return GhosttyPalette.cyan
        case .write: return GhosttyPalette.yellow
        case .search: return GhosttyPalette.blue
        case .text: return GhosttyPalette.foreground
        case .status: return GhosttyPalette.brightBlack
        case .error: return GhosttyPalette.brightRed
        case .usage: return GhosttyPalette.magenta
        case .input: return GhosttyPalette.brightMagenta
        case .test: return GhosttyPalette.brightYellow
        case .skill: return GhosttyPalette.brightMagenta
        }
    }
    /// The verb's colour in the run log: system colours, which adapt to light and dark appearance.
    var logColor: NSColor {
        switch tone {
        case .command: return .systemGreen
        case .read: return .systemTeal
        case .write: return .systemOrange
        case .search: return .systemPurple
        case .text: return .labelColor
        case .status: return .secondaryLabelColor
        case .error: return .systemRed
        case .usage: return .systemPink
        case .input: return .systemPurple
        case .test: return .systemBrown
        case .skill: return .systemIndigo
        }
    }
    /// A short plain description for chat bubbles and employee cards.
    var summary: String { verb.isEmpty ? body : "\(verb) \(body)" }
}

/// The run log as plain text on the page: one entry per event — time, employee, action, details — newest at the
/// bottom and following live, with search, an employee filter and copy. Drawn with system label colours so it reads
/// like a document in both appearances, not like a terminal embedded in the page.
struct RelayTerminalLog: View {
    var events: [RelayEvent]
    var roles: [RelayRole]
    var maxLines = 400
    /// Hide the toolbar when the log sits under a header that already names it.
    var showsToolbar = true
    @State private var query = ""
    @State private var roleFilter: String?
    @State private var kindFilter: LogKind?
    @State private var follow = true
    @State private var earlierLines = 0
    /// Categories the log can be narrowed to, by what each line is.
    enum LogKind: CaseIterable {
        case command, read, write, search, skill, text, input, status, test, error, usage
        var title: String {
            switch self {
            case .command: return "命令"
            case .read: return "读取文件"
            case .write: return "修改文件"
            case .search: return "搜索"
            case .skill: return "技能"
            case .text: return "说明与输出"
            case .input: return "指令"
            case .status: return "状态"
            case .test: return "测试"
            case .error: return "错误"
            case .usage: return "用量"
            }
        }
        static func of(_ line: RelayEventLine) -> LogKind {
            switch line.tone {
            case .command: return .command
            case .read: return .read
            case .write: return .write
            case .search: return .search
            case .skill: return .skill
            case .text: return .text
            case .input: return .input
            case .status: return .status
            case .test: return .test
            case .error: return .error
            case .usage: return .usage
            }
        }
    }
    private var counts: [LogKind: Int] {
        var result: [LogKind: Int] = [:]
        for event in events where roleFilter == nil || event.roleID == roleFilter { result[LogKind.of(RelayEventLine.from(event)), default: 0] += 1 }
        return result
    }
    private var matching: [RelayEvent] {
        events.filter { event in
            (roleFilter == nil || event.roleID == roleFilter) && (query.isEmpty || event.message.localizedCaseInsensitiveContains(query))
                && (kindFilter == nil || LogKind.of(RelayEventLine.from(event)) == kindFilter)
        }
    }
    private var lines: [RelayEventLine] { matching.suffix(maxLines + earlierLines).map(RelayEventLine.from) }
    private var activeRoles: [RelayRole] {
        let ids = Set(events.compactMap(\.roleID))
        return roles.filter { ids.contains($0.id) }
    }

    var body: some View {
        let shown = matching
        VStack(spacing: 0) {
            if showsToolbar {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                        TextField("搜索记录", text: $query).textFieldStyle(.plain).font(.system(size: 12))
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .frame(maxWidth: 260)
                    RelayPillMenu(title: kindFilter.map(\.title) ?? "全部类型", icon: "line.3.horizontal.decrease") {
                        Button("全部类型") { kindFilter = nil }
                        Divider()
                        ForEach(LogKind.allCases, id: \.self) { kind in
                            Button("\(kind.title)（\(counts[kind] ?? 0)）") { kindFilter = kind }.disabled((counts[kind] ?? 0) == 0)
                        }
                    }
                    if activeRoles.count > 1 {
                        RelayPillMenu(title: roleFilter.flatMap { id in roles.first { $0.id == id }?.name } ?? "全部员工", icon: "person") {
                            Button("全部员工") { roleFilter = nil }
                            Divider()
                            ForEach(activeRoles) { role in Button(role.name) { roleFilter = role.id } }
                        }
                    }
                    Spacer()
                    Text("\(shown.count) 条").font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                    Toggle("跟随最新", isOn: $follow).toggleStyle(.checkbox).font(.system(size: 12))
                    Button {
                        let text = shown.map(RelayEventLine.from).map { "\($0.date.formatted(date: .omitted, time: .standard)) \($0.summary)" }.joined(separator: "\n")
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("复制全部记录")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider().opacity(0.6)
            }
            if shown.count > maxLines + earlierLines {
                Button("加载更早的记录（还有 \(shown.count - maxLines - earlierLines) 条）") { earlierLines += maxLines }
                    .buttonStyle(.borderless).font(.system(size: 11)).padding(.top, 8)
            }
            if lines.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "text.alignleft").font(.system(size: 18)).foregroundStyle(.tertiary)
                    Text(query.isEmpty && roleFilter == nil && kindFilter == nil ? "等待执行事件…" : "没有匹配的记录").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 30)
            } else {
                // A real text view: drag across lines to select, ⌘C / ⌘A work, right-click copies.
                RelaySelectableLog(text: Self.attributed(lines, roles: roles), follow: follow)
            }
        }
        .background(RelayStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(RelayStyle.border))
    }

    /// The lines as one text: a muted time column, the employee in their colour, the action, then the details;
    /// wrapped and multi-line details are indented under the action so each entry reads as one block.
    static func attributed(_ lines: [RelayEventLine], roles: [RelayRole]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let medium = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        let indent = ("00:00:00  " as NSString).size(withAttributes: [.font: font]).width
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = indent
        paragraph.paragraphSpacing = 5
        paragraph.lineSpacing = 1.5
        // Lines after the first sit under the details, not under the time.
        let continued = (paragraph.mutableCopy() as? NSMutableParagraphStyle) ?? paragraph
        continued.firstLineHeadIndent = indent
        continued.paragraphSpacing = 1
        var colors: [String: NSColor] = [:]
        for role in roles { colors[role.id] = NSColor(RelayStyle.color(role.color)) }
        func add(_ text: String, _ color: NSColor, _ font: NSFont, _ style: NSParagraphStyle? = nil) {
            result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style ?? paragraph]))
        }
        let limit = 40
        // Tool results some clients send without content carry nothing to read.
        for line in lines where !(line.verb == "输出" && line.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            add(line.date.formatted(date: .omitted, time: .standard) + "  ", .tertiaryLabelColor, font)
            if let id = line.roleID, let role = roles.first(where: { $0.id == id }) {
                add(role.name + "  ", colors[id] ?? .secondaryLabelColor, medium)
            }
            if !line.verb.isEmpty { add(line.verb + "  ", line.logColor, medium) }
            let parts = line.body.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            let base: NSColor = switch line.tone {
            case .error: .systemRed
            case .status, .usage: .secondaryLabelColor
            default: .labelColor
            }
            let diff = line.tone == .write || line.tone == .command
            for (index, part) in parts.prefix(limit).enumerated() {
                if index > 0 { add("\n", base, font, continued) }
                var color = base
                if diff && index > 0 {
                    if part.hasPrefix("+") { color = .systemGreen }
                    else if part.hasPrefix("-") { color = .systemRed }
                    else if part.hasPrefix("@@") { color = .secondaryLabelColor }
                }
                add(part, color, font, index > 0 ? continued : nil)
            }
            if parts.count > limit { add("\n… 还有 \(parts.count - limit) 行（复制全部记录可取完整内容）", .tertiaryLabelColor, font, continued) }
            add("\n", base, font)
        }
        return result
    }
}

/// Read-only, selectable NSTextView for the run log; keeps the bottom in view while `follow` is on.
struct RelaySelectableLog: NSViewRepresentable {
    var text: NSAttributedString
    var follow: Bool
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.isAutomaticLinkDetectionEnabled = false
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { return }
        guard !storage.isEqual(to: text) else { return }
        // Keep a selection the user is making; only follow the bottom when nothing is selected.
        let selecting = view.selectedRange().length > 0
        let atBottom = scroll.contentView.bounds.maxY >= (scroll.documentView?.bounds.height ?? 0) - 30
        storage.setAttributedString(text)
        if follow && !selecting && (atBottom || context.coordinator.first) {
            view.scrollToEndOfDocument(nil)
        }
        context.coordinator.first = false
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var first = true }
}

struct RelayCodeOutput: View {
    let text: String
    @State private var expanded = false
    private var lines: [String] { text.components(separatedBy: "\n") }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("完成输出").font(.system(size: 12, weight: .medium))
                Spacer()
                Button("复制完整输出") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                    .buttonStyle(.plain).font(.caption)
            }.foregroundStyle(GhosttyPalette.white)
            Text(RelaySyntaxText.render((expanded ? lines : Array(lines.prefix(80))).joined(separator: "\n")))
                .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if lines.count > 80 {
                Button(expanded ? "收起" : "展开全部 \(lines.count) 行") { expanded.toggle() }.buttonStyle(.plain).foregroundStyle(GhosttyPalette.cyan)
            }
        }.padding(16).background(GhosttyPalette.background, in: RoundedRectangle(cornerRadius: 10))
    }
}

enum RelaySyntaxText {
    private static let rules: [(NSRegularExpression, Color)] = [
        (try! NSRegularExpression(pattern: #"\b(import|from|export|func|function|class|struct|enum|let|var|const|return|if|else|for|while|guard|try|catch|throw|async|await|def|self|public|private|static|true|false|null|nil)\b"#), GhosttyPalette.magenta),
        (try! NSRegularExpression(pattern: #"\b[0-9]+(?:\.[0-9]+)?\b"#), GhosttyPalette.yellow),
        (try! NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#), GhosttyPalette.green),
        (try! NSRegularExpression(pattern: #"(?:^\s*#|//).*$"#), GhosttyPalette.brightBlack)
    ]
    static func render(_ text: String, code: Bool = false, foreground: Color = GhosttyPalette.foreground) -> AttributedString {
        var result = AttributedString()
        var fenced = false
        let lines = text.components(separatedBy: "\n")
        // Only a diff (some lines added, some removed) gets +/− colours; a markdown "- item" list stays plain.
        let diff = lines.contains { $0.hasPrefix("+") && !$0.hasPrefix("+ ") } || (lines.contains { $0.hasPrefix("+") } && lines.contains { $0.hasPrefix("-") && !$0.hasPrefix("- ") })
        for (index, line) in lines.enumerated() {
            var part = AttributedString(line)
            part.foregroundColor = foreground
            if line.hasPrefix("```") { fenced.toggle(); part.foregroundColor = GhosttyPalette.brightBlack }
            else if line.hasPrefix("@@") { part.foregroundColor = GhosttyPalette.cyan }
            else if diff && line.hasPrefix("+") { part.foregroundColor = GhosttyPalette.green }
            else if diff && line.hasPrefix("-") { part.foregroundColor = GhosttyPalette.red }
            else if code || fenced {
                for (regex, color) in rules {
                    for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                        guard let range = Range(match.range, in: line), let start = AttributedString.Index(range.lowerBound, within: part),
                              let end = AttributedString.Index(range.upperBound, within: part) else { continue }
                        part[start..<end].foregroundColor = color
                    }
                }
            }
            result.append(part)
            if index < lines.count - 1 { result.append(AttributedString("\n")) }
        }
        return result
    }
}
