import Foundation
import SQLite3
import RelayCore

/// The models each client offers, in the client's own groups, for picking a model to give a time window.
/// Read during an explicit refresh only. Only names are read: never keys, tokens or endpoints.
enum RelayClientCatalog {
    struct Entry: Hashable, Sendable { var id: String; var label: String; var note: String? }
    struct Group: Identifiable, Sendable {
        var title: String
        var note: String?
        var entries: [Entry]
        var id: String { title }
    }

    static func groups(for connection: RelayConnection) -> [Group] {
        var groups: [Group]
        switch connection.kind {
        case .workbuddy: groups = workbuddy()
        case .deepseekHarness: groups = deepseekHarness()
        case .claude: groups = ccSwitch("claude", official: claudeOfficial())
        case .codex: groups = ccSwitch("codex", official: nil)
        default: groups = []
        }
        // Whatever the connection's last check found that no group lists yet.
        let listed = Set(groups.flatMap { $0.entries.map(\.id) })
        let rest = connection.models.filter { !listed.contains($0) }
        if !rest.isEmpty { groups.append(.init(title: "连接检测到的模型", entries: rest.map { .init(id: $0, label: $0) })) }
        return groups
    }

    // MARK: WorkBuddy — grouped by model family, with its credit rate and promotion notes.

    private static func workbuddy() -> [Group] {
        guard let file = try? RelayProviders.buddyCatalog().file, let data = try? Data(contentsOf: file), data.count < 8 * 1024 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agent = (root["agents"] as? [[String: Any]])?.first(where: { $0["name"] as? String == "cli" }),
              let ids = agent["models"] as? [String] else { return [] }
        let details = Dictionary((root["models"] as? [[String: Any]] ?? []).compactMap { row in (row["id"] as? String).map { ($0, row) } },
                                 uniquingKeysWith: { first, _ in first })
        let notes = RelayProviders.buddyModelNotes()
        let automatic: Set<String> = ["auto", "default", "fast-model", "balanced-model", "deep-model"]
        let families: [(prefix: String, title: String)] = [("deepseek", "DeepSeek"), ("glm", "智谱 GLM"), ("kimi", "Kimi"), ("hy", "腾讯混元"),
                                                            ("minimax", "MiniMax"), ("step", "阶跃 Step"), ("mimo", "小米 MiMo")]
        var order: [String] = []
        var byFamily: [String: [Entry]] = [:]
        for id in ids where !automatic.contains(id) {
            let family = families.first { id.lowercased().hasPrefix($0.prefix) }?.title ?? "其他"
            let detail = details[id]
            let note = [(detail?["credits"] as? String).map { "消耗 \($0)" }, notes[id]].compactMap { $0 }.joined(separator: " · ")
            if byFamily[family] == nil { order.append(family) }
            byFamily[family, default: []].append(.init(id: id, label: detail?["name"] as? String ?? id, note: note.isEmpty ? nil : note))
        }
        return order.map { .init(title: $0, entries: byFamily[$0] ?? []) }
    }

    // MARK: DeepSeek Harness — one group per provider declared in a DSH profile.

    /// Dravion runs DSH with the `headless` profile, so only providers that profile has can run; others are
    /// listed (they are the user's groups) with a note saying so.
    private static func deepseekHarness() -> [Group] {
        let profiles = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/profiles")
        var found: [(provider: String, profile: String, models: [(String, String?)])] = []
        for profile in ["headless", "desktop", "web"] {
            guard let text = try? String(contentsOf: profiles.appendingPathComponent("\(profile)/cordis.patch.yml"), encoding: .utf8) else { continue }
            for (provider, models) in dshProviders(text) where !found.contains(where: { $0.provider == provider }) {
                found.append((provider, profile, models))
            }
        }
        // The account provider is built in: the default model of the headless profile.
        var groups: [Group] = [.init(title: "DeepSeek 官方账号", note: "deepseek-official · DSH 内置",
                                     entries: [.init(id: "deepseek-official/deepseek-flash", label: "deepseek-flash", note: "DSH 默认模型")])]
        for item in found where item.provider != "deepseek-official" {
            let usable = item.profile == "headless"
            groups.append(.init(title: item.provider, note: usable ? "headless 配置" : "来自 \(item.profile) 配置；Dravion 使用 headless 配置，需先把这个服务商加进去",
                                entries: item.models.map { .init(id: "\(item.provider)/\($0.0)", label: $0.1 ?? $0.0, note: $0.1 == nil ? nil : $0.0) }))
        }
        return groups
    }

    /// `llm-pi-ai` providers in a DSH patch file: `providers:` → `<name>:` → `models:` → `- id:` / `name:`.
    /// A small indentation reader for that one shape; anything else is skipped.
    static func dshProviders(_ text: String) -> [(String, [(String, String?)])] {
        var result: [(String, [(String, String?)])] = []
        var providersIndent: Int?
        var providerIndent: Int?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indent = line.prefix { $0 == " " }.count
            if trimmed == "providers:" { providersIndent = indent; providerIndent = nil; continue }
            guard let base = providersIndent else { continue }
            if indent <= base { providersIndent = nil; continue }
            if providerIndent == nil || indent <= providerIndent!, trimmed.hasSuffix(":"), !trimmed.contains(" ") {
                providerIndent = indent
                result.append((String(trimmed.dropLast()), []))
            } else if trimmed.hasPrefix("- id:"), !result.isEmpty {
                let id = trimmed.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                result[result.count - 1].1.append((id, nil))
            } else if trimmed.hasPrefix("name:"), !result.isEmpty, !result[result.count - 1].1.isEmpty,
                      result[result.count - 1].1[result[result.count - 1].1.count - 1].1 == nil {
                let name = trimmed.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                let last = result[result.count - 1].1.count - 1
                result[result.count - 1].1[last].1 = name
            }
        }
        return result.filter { !$0.1.isEmpty }
    }

    // MARK: Claude Code / Codex — one group per cc-switch provider, the current one first.

    private static func claudeOfficial() -> Group {
        .init(title: "Claude 官方", note: "Claude Code 内置别名和模型 ID",
              entries: [.init(id: "opus", label: "opus", note: "别名，随 Claude Code 版本"),
                        .init(id: "sonnet", label: "sonnet", note: "别名"),
                        .init(id: "haiku", label: "haiku", note: "别名"),
                        .init(id: "claude-opus-5-5", label: "claude-opus-5-5"),
                        .init(id: "claude-sonnet-5-5", label: "claude-sonnet-5-5"),
                        .init(id: "claude-haiku-5-5", label: "claude-haiku-5-5"),
                        .init(id: "claude-fable-5-1", label: "claude-fable-5-1")])
    }

    private static func ccSwitch(_ app: String, official: Group?) -> [Group] {
        var groups: [Group] = []
        var current: Group?
        for provider in ccSwitchProviders(app) {
            if provider.current, provider.models.isEmpty, var official {
                official.title = "\(provider.name)（当前）"
                current = official
                continue
            }
            guard !provider.models.isEmpty, !groups.contains(where: { $0.title == provider.name }) else { continue }
            let group = Group(title: provider.current ? "\(provider.name)（当前）" : provider.name,
                              note: provider.current ? "cc-switch 当前服务商" : "需要先在 cc-switch 切换到这个服务商",
                              entries: provider.models.map { .init(id: $0, label: $0) })
            if provider.current { current = group } else { groups.append(group) }
        }
        if let current { groups.insert(current, at: 0) } else if let official { groups.insert(official, at: 0) }
        return groups
    }

    /// Provider names and the model names in their settings, from cc-switch.db, read-only.
    private static func ccSwitchProviders(_ app: String) -> [(name: String, current: Bool, models: [String])] {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cc-switch/cc-switch.db").path
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT name, is_current, settings_config FROM providers WHERE app_type = ? ORDER BY is_current DESC, sort_index, created_at"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, app, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var rows: [(String, Bool, [String])] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 0) else { continue }
            let config = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            rows.append((String(cString: name), sqlite3_column_int(statement, 1) == 1, modelNames(config)))
        }
        return rows
    }

    /// Model names only: `env.*MODEL*` values (Claude) and `model = "…"` in the TOML `config` (Codex).
    static func modelNames(_ json: String) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return [] }
        var names: [String] = []
        if let model = object["model"] as? String { names.append(model) }
        for (key, value) in (object["env"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key })
        where key.contains("MODEL") && !key.contains("KEY") && !key.contains("TOKEN") {
            if let text = value as? String, !text.isEmpty, !text.contains("://") { names.append(text) }
        }
        if let toml = object["config"] as? String {
            for line in toml.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("["), !names.isEmpty { break }
                guard text.hasPrefix("model"), let equals = text.firstIndex(of: "="),
                      text[..<equals].trimmingCharacters(in: .whitespaces) == "model" else { continue }
                names.append(text[text.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'")))
            }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}
