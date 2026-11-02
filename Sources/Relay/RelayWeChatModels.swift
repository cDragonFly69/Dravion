import Foundation
import SQLite3
import SwiftUI
import RelayCore

/// Which model the OpenClaw WeChat channel answers with, chosen in 调度设置 → 微信远程.
///
/// Two sources, both read from what is already on this machine:
/// - OpenClaw's own catalog (`openclaw models list --json`), grouped by provider.
/// - The cc-switch providers the person already configured for Claude Code and Codex, imported on demand:
///   their base URL and token are copied into `~/.openclaw/openclaw.json` as a provider, and the picked model
///   becomes `agents.defaults.model`.
///
/// Writes go through `openclaw config patch`, so OpenClaw validates them itself; the gateway is restarted after.
/// Tokens are only ever passed on stdin and never shown, logged or kept in memory beyond the import.
@MainActor
enum RelayWeChatModels {
    struct Entry: Hashable, Sendable {
        var key: String
        var label: String
        var note: String?
    }
    struct Group: Identifiable, Sendable {
        var provider: String
        var title: String
        var note: String?
        var entries: [Entry]
        var id: String { provider }
    }
    /// A cc-switch provider that can be imported into OpenClaw.
    struct LocalProvider: Identifiable, Sendable {
        var id: String
        var name: String
        var app: String
        var baseURL: String
        var models: [String]
        var isCurrent: Bool
        var imported: Bool
    }

    // MARK: - What OpenClaw can answer with right now

    static var configFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openclaw/openclaw.json")
    }

    static func current() -> String? {
        guard let data = try? Data(contentsOf: configFile), data.count < 2_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = (root["agents"] as? [String: Any])?["defaults"] as? [String: Any],
              let model = defaults["model"] as? String, !model.isEmpty else { return nil }
        return model
    }

    static func utility() -> String? {
        guard let data = try? Data(contentsOf: configFile), data.count < 2_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = (root["agents"] as? [String: Any])?["defaults"] as? [String: Any],
              let model = defaults["utilityModel"] as? String, !model.isEmpty else { return nil }
        return model
    }

    /// Providers written into `models.providers` — the ones this app imported or the person configured.
    static func importedProviders() -> Set<String> {
        guard let data = try? Data(contentsOf: configFile), data.count < 2_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = (root["models"] as? [String: Any])?["providers"] as? [String: Any] else { return [] }
        return Set(providers.keys)
    }

    /// Everything the gateway says it can run, grouped by provider, in its own order.
    static func groups() async -> [Group] {
        // Fixture renders must not start a subprocess or read the real machine.
        guard !CommandLine.arguments.contains("--ui-test"), let openclaw = RelayWeChat.openclaw else { return [] }
        let result = try? await RelayProcessRunner().run(.init(
            command: openclaw, arguments: ["models", "list", "--json"],
            directory: NSTemporaryDirectory(), timeout: 45))
        guard let text = result?.stdout, let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["models"] as? [[String: Any]] else { return [] }
        let defaultModel = current()
        var order: [String] = []
        var byProvider: [String: [Entry]] = [:]
        for row in rows {
            guard let key = row["key"] as? String else { continue }
            let provider = key.split(separator: "/").first.map(String.init) ?? key
            let name = row["name"] as? String ?? key
            var notes: [String] = []
            if key == defaultModel { notes.append("当前") }
            if row["available"] as? Bool == false { notes.append("未认证") }
            if let input = row["input"] as? String, input.contains("image") { notes.append("可看图") }
            if byProvider[provider] == nil { order.append(provider) }
            byProvider[provider, default: []].append(.init(key: key, label: name, note: notes.isEmpty ? nil : notes.joined(separator: " · ")))
        }
        return order.map { .init(provider: $0, title: title(for: $0), note: nil, entries: byProvider[$0] ?? []) }
    }

    static func title(for provider: String) -> String {
        switch provider {
        case "claude-cli": return "Claude CLI（本机登录）"
        case "codex": return "Codex（本机登录）"
        case "agentrouter": return "AgentRouter"
        case "openai": return "OpenAI"
        case "anthropic": return "Anthropic"
        case "deepseek": return "DeepSeek"
        default: return provider
        }
    }

    // MARK: - cc-switch providers on this machine

    /// Claude Code and Codex providers the person already has in cc-switch, current one first. Names, model
    /// names and base URLs only — the token is read later, inside `importProvider`.
    static func localProviders() -> [LocalProvider] {
        let imported = importedProviders()
        var rows: [LocalProvider] = []
        var used = Set<String>()
        for app in ["claude", "codex"] {
            for (index, row) in ccSwitchRows(app).enumerated() {
                var id = providerID(app: app, name: row.name, index: index)
                var suffix = 2
                // cc-switch allows two providers with the same name; OpenClaw keys must stay unique.
                while used.contains(id) {
                    id = providerID(app: app, name: row.name, index: index) + "-\(suffix)"
                    suffix += 1
                }
                used.insert(id)
                rows.append(.init(id: id, name: row.name, app: app, baseURL: row.baseURL,
                                  models: row.models, isCurrent: row.isCurrent, imported: imported.contains(id)))
            }
        }
        return rows
    }

    private struct Row {
        var name: String
        var isCurrent: Bool
        var baseURL: String
        var models: [String]
        var settings: [String: Any]
    }

    private static func ccSwitchRows(_ app: String) -> [Row] {
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
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 0) else { continue }
            let config = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            guard let object = try? JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any] else { continue }
            let base = app == "claude" ? claudeBase(object) : codexBase(object)
            guard let base, !base.isEmpty else { continue }
            rows.append(.init(name: String(cString: name), isCurrent: sqlite3_column_int(statement, 1) == 1,
                              baseURL: base, models: models(of: object, app: app), settings: object))
        }
        return rows
    }

    private static func claudeBase(_ object: [String: Any]) -> String? {
        let env = object["env"] as? [String: Any] ?? [:]
        return (env["ANTHROPIC_BASE_URL"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Codex keeps its endpoint in the TOML `config` blob (`base_url = "…"`).
    private static func codexBase(_ object: [String: Any]) -> String? {
        guard let toml = object["config"] as? String else { return nil }
        for line in toml.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let equals = text.firstIndex(of: "="), text[..<equals].trimmingCharacters(in: .whitespaces) == "base_url" else { continue }
            return text[text.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'/"))
        }
        return nil
    }

    private static func models(of object: [String: Any], app: String) -> [String] {
        var names: [String] = []
        if let catalog = (object["modelCatalog"] as? [String: Any])?["models"] as? [[String: Any]] {
            names += catalog.compactMap { $0["model"] as? String }
        }
        if let config = object["config"] as? String { names += RelayClientCatalog.modelNames("{\"config\":\(quoted(config))}") }
        names += RelayClientCatalog.modelNames((try? String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8)) ?? "{}")
        var seen = Set<String>()
        let cleaned = names.map { stripSuffix($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty && !$0.contains("/") && !$0.contains("://") && seen.insert($0).inserted }
        return cleaned.isEmpty ? defaults(for: app) : cleaned
    }

    /// cc-switch marks context tiers in the name (`deepseek-v4-pro[1M]`); the endpoint wants the bare id.
    private static func stripSuffix(_ name: String) -> String {
        guard let bracket = name.firstIndex(of: "[") else { return name }
        return String(name[..<bracket]).trimmingCharacters(in: .whitespaces)
    }

    private static func quoted(_ text: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [text])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    static func defaults(for app: String) -> [String] {
        app == "claude"
            ? ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"]
            : ["gpt-6-astra", "gpt-5.6-sol", "gpt-6.1-sol"]
    }

    private static func providerID(app: String, name: String, index: Int) -> String {
        let ascii = String(name.lowercased().unicodeScalars.filter { scalar in
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains(scalar)
        }).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "cc-" + (ascii.isEmpty ? "\(app)-\(index + 1)" : ascii)
    }

    // MARK: - Writing OpenClaw's config

    /// Copies one cc-switch provider into OpenClaw and returns the provider id it landed under.
    static func importProvider(_ provider: LocalProvider) async throws -> String {
        let rows = ccSwitchRows(provider.app).filter { $0.name == provider.name }
        guard let row = rows.first else { throw RelayError.invalid("在 cc-switch 里没找到「\(provider.name)」，可能已被删除或改名。") }
        let token = provider.app == "claude" ? claudeToken(row.settings) : codexToken(row.settings)
        guard let token, !token.isEmpty else { throw RelayError.invalid("「\(provider.name)」在 cc-switch 里没有可用的令牌，先在 cc-switch 里检查这个服务商。") }
        let base = row.baseURL
        let api = provider.app == "claude" ? "anthropic-messages" : "openai-responses"
        let modelRows = provider.models.map { ["id": $0, "name": $0] as [String: Any] }
        var entry: [String: Any] = [
            "baseUrl": base,
            "api": api,
            "apiKey": token,
            "models": modelRows.isEmpty ? [] : modelRows
        ]
        // AgentRouter (and its clones) refuse a request that does not look like the client it expects.
        if base.lowercased().contains("agentrouter") {
            entry["headers"] = ["user-agent": "codex_cli_rs/0.52.0 (Mac OS 26.0; arm64) vscode", "originator": "codex_cli_rs"]
        }
        try await patch(["models": ["providers": [provider.id: entry]]])
        return provider.id
    }

    private static func claudeToken(_ object: [String: Any]) -> String? {
        let env = object["env"] as? [String: Any] ?? [:]
        return (env["ANTHROPIC_AUTH_TOKEN"] as? String) ?? (env["ANTHROPIC_API_KEY"] as? String)
    }

    private static func codexToken(_ object: [String: Any]) -> String? {
        if let auth = object["auth"] as? [String: Any], let key = auth["OPENAI_API_KEY"] as? String, !key.isEmpty { return key }
        guard let toml = object["config"] as? String else { return nil }
        for line in toml.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let equals = text.firstIndex(of: "=") else { continue }
            let key = text[..<equals].trimmingCharacters(in: .whitespaces)
            guard key == "experimental_bearer_token" || key == "api_key" else { continue }
            return text[text.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        return nil
    }

    /// Makes a catalog entry the model WeChat answers with, then restarts the gateway so the channel picks it up.
    static func select(_ key: String) async throws -> String {
        var defaults: [String: Any] = ["model": key]
        // A utility model left on a provider that no longer exists fails every short internal call.
        if let utility = utility(), !utility.hasPrefix(key.split(separator: "/").first.map(String.init) ?? "\u{0}") {
            defaults["utilityModel"] = key
        }
        try await patch(["agents": ["defaults": defaults]])
        try await restartGateway()
        return key
    }

    private static func patch(_ object: [String: Any]) async throws {
        guard let openclaw = RelayWeChat.openclaw else { throw RelayError.invalid("未找到 openclaw 命令。请先在“客户端版本”里安装 OpenClaw。") }
        let data = try JSONSerialization.data(withJSONObject: object)
        let result = try await RelayProcessRunner().run(.init(
            command: openclaw, arguments: ["config", "patch", "--stdin"],
            directory: NSTemporaryDirectory(), input: String(decoding: data, as: UTF8.self), timeout: 60))
        guard result.exitCode == 0 else {
            throw RelayError.executor("写入 OpenClaw 配置失败（\(result.exitCode)）：\(String((result.stderr + result.stdout).prefix(300)))")
        }
    }

    static func restartGateway() async throws {
        guard let openclaw = RelayWeChat.openclaw else { throw RelayError.invalid("未找到 openclaw 命令。") }
        let result = try await RelayProcessRunner().run(.init(
            command: openclaw, arguments: ["gateway", "restart"],
            directory: NSTemporaryDirectory(), timeout: 120))
        guard result.exitCode == 0 else {
            throw RelayError.executor("重启 OpenClaw Gateway 失败（\(result.exitCode)）：\(String((result.stderr + result.stdout).prefix(300)))")
        }
    }
}

/// 模型选择：供应商分组 → 模型；本地还没接入的服务商也在菜单里，选它的模型就直接接入并启用。
struct RelayWeChatModelPicker: View {
    var onStatus: (String) -> Void
    @State private var groups: [RelayWeChatModels.Group] = []
    @State private var locals: [RelayWeChatModels.LocalProvider] = []
    @State private var current: String?
    @State private var loading = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("回答模型").font(.system(size: 12, weight: .medium))
                RelayPillMenu(title: busy ? "切换中…" : (current ?? (loading ? "读取中…" : "未设置")), icon: "cpu") {
                    ForEach(groups) { group in
                        Section(group.title) {
                            ForEach(group.entries, id: \.key) { entry in
                                Button {
                                    choose(entry.key)
                                } label: {
                                    if let note = entry.note { Text("\(entry.label) — \(note)") } else { Text(entry.label) }
                                }
                            }
                        }
                    }
                    if !locals.isEmpty {
                        Divider()
                        Section("从本地服务商接入") {
                            ForEach(locals) { provider in
                                Menu("\(provider.name)（\(provider.app == "claude" ? "Claude Code" : "Codex")）") {
                                    ForEach(provider.models, id: \.self) { model in
                                        Button(model) { connect(provider, model: model) }
                                    }
                                }
                            }
                        }
                    }
                    if groups.isEmpty && locals.isEmpty { Text("没有读到可用的模型") }
                }
                .disabled(busy || loading)
                Button("刷新") { Task { await load() } }.buttonStyle(.borderless).disabled(busy || loading)
                Spacer()
            }
            Text("选项来自本机 OpenClaw 的模型目录，以及 cc-switch 里你已配好的 Claude Code / Codex 服务商。选中后写进 OpenClaw 的微信通道，Gateway 自动重启。本地服务商第一次选模型时，它的地址和令牌会复制到 ~/.openclaw/openclaw.json（权限 600），不显示、不记录。")
                .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        current = RelayWeChatModels.current()
        locals = RelayWeChatModels.localProviders()
        groups = await RelayWeChatModels.groups()
        loading = false
    }

    private func choose(_ key: String) {
        busy = true
        Task {
            do {
                _ = try await RelayWeChatModels.select(key)
                current = key
                await load()
                onStatus("微信远程将用 \(key) 回答，Gateway 已重启。")
            } catch {
                onStatus(error.localizedDescription)
            }
            busy = false
        }
    }

    /// 一步到位：接入这个 cc-switch 服务商，再把选中的模型设为回答模型。
    private func connect(_ provider: RelayWeChatModels.LocalProvider, model: String) {
        busy = true
        Task {
            do {
                let id = try await RelayWeChatModels.importProvider(provider)
                let key = "\(id)/\(model)"
                _ = try await RelayWeChatModels.select(key)
                current = key
                await load()
                onStatus("已接入「\(provider.name)」，微信远程将用 \(key) 回答，Gateway 已重启。")
            } catch {
                onStatus(error.localizedDescription)
                await load()
            }
            busy = false
        }
    }
}
