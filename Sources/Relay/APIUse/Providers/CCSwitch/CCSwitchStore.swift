import Foundation

/// The providers configured in [CC Switch](https://github.com/farion1231/cc-switch),
/// read from its own database.
///
/// **Read-only, and read at every fetch.** CC Switch owns the file; Pulse opens
/// it with `SQLITE_OPEN_READONLY` (`AgentSQLite`) and keeps nothing of it. A
/// key changed or a provider deleted in CC Switch is what the next pass sees,
/// and no copy of the key is ever written by Pulse.
///
/// ```
/// ~/.cc-switch/cc-switch.db
///   providers(id, app_type, name, settings_config, website_url, category, is_current, …)
/// ```
///
/// `settings_config` is the JSON CC Switch writes into the tool's own config
/// when the provider is switched to, and its shape differs per tool:
///
/// | `app_type` | address | key |
/// |---|---|---|
/// | `claude` | `env.ANTHROPIC_BASE_URL` | `env.ANTHROPIC_AUTH_TOKEN` or `env.ANTHROPIC_API_KEY` |
/// | `codex` | `base_url = "…"` in the `config` TOML string | `auth.OPENAI_API_KEY` |
/// | `gemini` | `env.GOOGLE_GEMINI_BASE_URL` | `env.GEMINI_API_KEY` |
/// | `opencode` | `options.baseURL` | `options.apiKey` |
enum CCSwitchStore {
    struct Entry: Sendable, Hashable, Identifiable {
        let providerID: String
        let appType: String
        let name: String
        let category: String?
        let websiteURL: String?
        let isCurrent: Bool
        let baseURL: String?
        let key: String?

        /// The Pulse account slot for this entry. Stable across imports, so
        /// importing again does not make a second ring for the same entry.
        var slot: String { "\(appType)-\(providerID)" }
        var id: String { slot }

        /// The tool this entry configures, as CC Switch names it.
        var appName: String {
            switch appType {
            case "claude": "Claude Code"
            case "codex": "Codex"
            case "gemini": "Gemini CLI"
            case "opencode": "OpenCode"
            case "claude-desktop": "Claude Desktop"
            default: appType
            }
        }

        /// The host the key is sent to, for display.
        var host: String? { baseURL.flatMap { URL(string: $0)?.host } }
    }

    static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cc-switch/cc-switch.db")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: databaseURL.path) }

    /// Every entry, in CC Switch's own order. Empty when CC Switch is not
    /// installed or its schema is not one this reader knows.
    static func entries(at url: URL = databaseURL) -> [Entry] {
        AgentSQLite.read(at: url) { db in
            var rows: [Entry] = []
            AgentSQLite.each(
                db,
                sql: """
                SELECT id, app_type, name, settings_config, category, website_url, is_current
                FROM providers ORDER BY app_type, sort_index, created_at
                """
            ) { statement in
                guard
                    let id = AgentSQLite.text(statement, column: 0),
                    let appType = AgentSQLite.text(statement, column: 1)
                else { return }
                let config = AgentSQLite.text(statement, column: 3) ?? "{}"
                let (baseURL, key) = endpoint(appType: appType, settingsConfig: config)
                rows.append(Entry(
                    providerID: id,
                    appType: appType,
                    name: AgentSQLite.text(statement, column: 2) ?? "",
                    category: AgentSQLite.text(statement, column: 4),
                    websiteURL: AgentSQLite.text(statement, column: 5),
                    isCurrent: AgentSQLite.text(statement, column: 6) == "1",
                    baseURL: baseURL,
                    key: key
                ))
            }
            return rows
        } ?? []
    }

    static func entry(slot: String, at url: URL = databaseURL) -> Entry? {
        entries(at: url).first { $0.slot == slot }
    }

    /// The entry CC Switch currently has switched on for Claude Code, which is
    /// what the primary CC Switch account follows.
    ///
    /// **A relay in use, not an official login.** The official logins have no
    /// balance to read — the Claude Code and Codex rings already show them —
    /// so an entry in use that has an address and a key comes first, Claude
    /// Code's before Codex's, and an official one only when nothing else is.
    static func current(at url: URL = databaseURL) -> Entry? {
        current(in: entries(at: url))
    }

    static func current(in all: [Entry]) -> Entry? {
        let inUse = all.filter(\.isCurrent)
        let order = ["claude", "codex", "gemini", "opencode"]
        let ranked = inUse.sorted {
            (order.firstIndex(of: $0.appType) ?? order.count) < (order.firstIndex(of: $1.appType) ?? order.count)
        }
        return ranked.first { $0.key != nil && CCSwitchUsageService.kind(of: $0) != .official } ?? ranked.first
    }

    /// The address and key out of one `settings_config`.
    static func endpoint(appType: String, settingsConfig: String) -> (baseURL: String?, key: String?) {
        guard
            let data = settingsConfig.data(using: .utf8),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return (nil, nil) }

        let env = json["env"] as? [String: Any] ?? [:]
        func string(_ value: Any?) -> String? {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return text
        }

        switch appType {
        case "codex":
            // CC Switch's `extract_codex_api_key`: the auth file's key, else
            // the TOML's `experimental_bearer_token`, which relay presets use.
            let auth = json["auth"] as? [String: Any] ?? [:]
            let toml = json["config"] as? String ?? ""
            return (tomlBaseURL(in: toml), string(auth["OPENAI_API_KEY"]) ?? tomlString("experimental_bearer_token", in: toml))
        case "opencode":
            let options = json["options"] as? [String: Any] ?? [:]
            return (string(options["baseURL"]), string(options["apiKey"]))
        case "gemini":
            return (string(env["GOOGLE_GEMINI_BASE_URL"]), string(env["GEMINI_API_KEY"]))
        default:
            return (
                string(env["ANTHROPIC_BASE_URL"]),
                string(env["ANTHROPIC_AUTH_TOKEN"]) ?? string(env["ANTHROPIC_API_KEY"])
            )
        }
    }

    /// The first `base_url = "…"` in Codex's TOML. Only the custom provider
    /// block carries one, so the first is the one in use.
    static func tomlBaseURL(in toml: String) -> String? { tomlString("base_url", in: toml) }

    /// The first `<key> = "…"` in a TOML string, the key matched whole.
    static func tomlString(_ key: String, in toml: String) -> String? {
        for line in toml.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "="),
                  trimmed[..<equals].trimmingCharacters(in: .whitespaces) == key else { continue }
            let value = trimmed[trimmed.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { return value }
        }
        return nil
    }
}
