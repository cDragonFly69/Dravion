import Foundation
import SQLite3
import RelayCore

/// Configuration is a snapshot, not proof of which model answered. Reported models come from call records.
enum RelayClientModels {
    struct Effective { var model: String; var detail: String }
    struct Configuration: Sendable { var model: String?; var effort: String?; var source: String? }

    static func effective(role: RelayRole, connection: RelayConnection?, configuration: Configuration?) -> Effective {
        let effort = role.effort == "default" ? configuration?.effort : role.effort
        guard let connection else { return .init(model: role.model.isEmpty ? "未知" : role.model, detail: "") }
        let chosen = role.model.isEmpty ? configuration?.model : role.model
        let detail = [role.model.isEmpty ? "客户端配置" : "角色指定", configuration?.source,
                      effort.map { "思考 \($0)" } ?? "思考级别未报告", connection.kind.label].compactMap { $0 }.joined(separator: " · ")
        return .init(model: chosen ?? "客户端模型未读取到", detail: detail)
    }

    /// Read only during an explicit refresh, never while a SwiftUI body is being evaluated.
    static func read() -> [RelayProviderKind: Configuration] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settings = (try? Data(contentsOf: home.appendingPathComponent(".claude/settings.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let env = settings?["env"] as? [String: Any]
        let toml = (try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)) ?? ""
        let claudeConfigured = settings?["model"] as? String ?? env?["ANTHROPIC_MODEL"] as? String
        let claudeRecent = claudeConfigured == nil ? recentClaudeModel(home) : nil
        let claudeSource = [ccSwitchProvider("claude").map { "cc-switch：\($0)" },
                            claudeConfigured == nil ? (claudeRecent == nil ? "未指定模型，用 Claude Code 默认" : "未指定模型，按最近会话实际使用") : nil]
        let buddy = buddyDefault()
        return [.claude: .init(model: claudeConfigured ?? claudeRecent ?? "Claude Code 默认模型",
                              effort: settings?["effortLevel"] as? String,
                              source: claudeSource.compactMap { $0 }.joined(separator: " · ")),
                .codex: .init(model: topLevel(toml, "model"), effort: topLevel(toml, "model_reasoning_effort"),
                             source: ccSwitchProvider("codex").map { "cc-switch：\($0)" }),
                .deepseekHarness: dshDefault(home),
                .workbuddy: .init(model: buddy ?? "WorkBuddy 默认模型", effort: nil, source: "WorkBuddy 默认"),
                .doubaoApp: .init(model: "豆包 App 当前模型", effort: nil, source: "在豆包应用里切换")]
    }

    /// The model the newest Claude Code transcript reports, when settings name none.
    private static func recentClaudeModel(_ home: URL) -> String? {
        let root = home.appendingPathComponent(".claude/projects")
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        guard let projects = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let newestProject = projects.max { modified($0) < modified($1) }
        guard let project = newestProject,
              let files = try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey]),
              let file = files.filter({ $0.pathExtension == "jsonl" })
                  .max(by: { modified($0) < modified($1) }),
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        let models = text.matches(of: #/"model":"([^"]+)"/#).map { String($0.1) }.filter { !$0.hasPrefix("<") }
        return models.last
    }

    /// DSH's default model in the `headless` profile Dravion runs, else its built-in default.
    private static func dshDefault(_ home: URL) -> Configuration {
        let file = home.appendingPathComponent(".dsh/profiles/headless/cordis.patch.yml")
        var provider: String?, model: String?, effort: String?
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            var inBlock = false
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- id:") { inBlock = trimmed.hasSuffix("agent-default-model"); continue }
                guard inBlock else { continue }
                let value = { (key: String) in trimmed.hasPrefix(key) ? trimmed.dropFirst(key.count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) : nil }
                provider = value("provider:") ?? provider; model = value("model:") ?? model; effort = value("reasoningEffort:") ?? effort
            }
        }
        if let model { return .init(model: [provider, model].compactMap { $0 }.joined(separator: "/"), effort: effort, source: "DSH headless 配置") }
        return .init(model: "deepseek-official/deepseek-flash", effort: nil, source: "DSH 内置默认")
    }

    /// The model WorkBuddy marks as its default, by display name.
    private static func buddyDefault() -> String? {
        guard let file = try? RelayProviders.buddyCatalog().file, let data = try? Data(contentsOf: file), data.count < 8 * 1024 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let row = (root["models"] as? [[String: Any]])?.first(where: { $0["isDefault"] as? Bool == true }),
              let id = row["id"] as? String else { return nil }
        return (row["name"] as? String).map { "\($0)（\(id)）" } ?? id
    }

    /// `key = "value"` at the top of a TOML file, before the first table.
    private static func topLevel(_ toml: String, _ key: String) -> String? {
        for line in toml.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("[") { break }
            guard text.hasPrefix(key), let equals = text.firstIndex(of: "=") else { continue }
            guard text[..<equals].trimmingCharacters(in: .whitespaces) == key else { continue }
            return text[text.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        return nil
    }

    /// The provider cc-switch currently routes the app through (its name only), read-only from cc-switch.db.
    private static func ccSwitchProvider(_ app: String) -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cc-switch/cc-switch.db").path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM providers WHERE app_type = ? AND is_current = 1 LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, app, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }
}
