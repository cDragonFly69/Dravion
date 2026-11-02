import Foundation

/// Every CC Switch provider whose usage query is switched on, asked the way
/// CC Switch asks it, for the desktop widget's balance list.
///
/// CC Switch keeps the query in `providers.meta.usage_script`:
///
/// | `templateType` | Asked |
/// |---|---|
/// | `balance` | the provider's own balance API, chosen by address (DeepSeek here) |
/// | `token_plan` | the coding plan's quota (Zhipu GLM / z.ai here) |
/// | anything else, or none | the script itself (`CCSwitchUsageScript`) |
///
/// **Entries that share an address and a key are asked once.** CC Switch
/// lists the same DeepSeek key under several names and tools; they are one
/// account with one balance, and asking three times would only triple the
/// requests. Each key goes to its own provider's address and nowhere else, and
/// none is written anywhere.
enum CCSwitchBalances {
    struct Script: Sendable, Equatable {
        var code: String
        var timeout: Int
        var templateType: String?
        var apiKey: String?
        var baseURL: String?
        var accessToken: String?
        var userID: String?
        var codingPlanProvider: String?
    }

    struct Configured: Sendable {
        let entry: CCSwitchStore.Entry
        let script: Script

        /// CC Switch's `resolve_script_credentials`: the script's own values
        /// when set, the provider's otherwise, the address without a trailing
        /// slash so `{{baseUrl}}/path` never doubles it.
        var apiKey: String { nonEmpty(script.apiKey) ?? entry.key ?? "" }
        var baseURL: String {
            var base = nonEmpty(script.baseURL) ?? entry.baseURL ?? ""
            while base.hasSuffix("/") { base.removeLast() }
            return base
        }
    }

    /// One account: every entry sharing a query, address and key.
    struct Group: Sendable {
        let configured: Configured
        var members: [CCSwitchStore.Entry]

        var id: String { configured.entry.slot }
        var names: [String] {
            var seen = Set<String>()
            return members.map(\.name).filter { seen.insert($0).inserted }
        }
        var apps: [String] {
            var seen = Set<String>()
            return members.map(\.appName).filter { seen.insert($0).inserted }
        }
        /// `"<app_type>|<provider_id>"`, as `CCSwitchUsageStats.providerDays` keys them.
        var usageKeys: [String] { members.map { "\($0.appType)|\($0.providerID)" } }
    }

    enum Outcome: Sendable {
        case money([CCSwitchUsageScript.UsageData])
        /// A subscription: its windows, and the account's money beside them
        /// where the provider reports both (Zhipu's plan and its balance).
        case plan(name: String?, windows: [UsageWindow], money: CCSwitchUsageScript.UsageData? = nil)
        case failed(String)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    // MARK: - Reading CC Switch

    /// Whether any query in CC Switch asks DeepSeek, so Settings offers the
    /// console's sign-in only where it adds something.
    static var hasDeepSeek: Bool {
        configured().contains { ($0.entry.host ?? "").lowercased().hasSuffix("deepseek.com") }
    }

    static func configured(at url: URL = CCSwitchStore.databaseURL) -> [Configured] {
        let entries = Dictionary(CCSwitchStore.entries(at: url).map { ($0.slot, $0) }, uniquingKeysWith: { a, _ in a })
        let scripts: [(String, Script)] = AgentSQLite.read(at: url) { db in
            var out: [(String, Script)] = []
            AgentSQLite.each(db, sql: "SELECT id, app_type, meta FROM providers ORDER BY app_type, sort_index, created_at") { statement in
                guard
                    let id = AgentSQLite.text(statement, column: 0),
                    let app = AgentSQLite.text(statement, column: 1),
                    let meta = AgentSQLite.text(statement, column: 2),
                    let script = script(fromMeta: meta)
                else { return }
                out.append(("\(app)-\(id)", script))
            }
            return out
        } ?? []
        return scripts.compactMap { slot, script in entries[slot].map { Configured(entry: $0, script: script) } }
    }

    /// The enabled usage query in one `meta`, or nil when there is none.
    static func script(fromMeta meta: String) -> Script? {
        guard
            let data = meta.data(using: .utf8),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let usage = json["usage_script"] as? [String: Any],
            usage["enabled"] as? Bool == true
        else { return nil }
        let template = nonEmpty(usage["templateType"] as? String)
        let code = usage["code"] as? String ?? ""
        // Only the two native templates may come without a script.
        guard template == "balance" || template == "token_plan" || !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return Script(
            code: code,
            timeout: (usage["timeout"] as? Int) ?? 10,
            templateType: template,
            apiKey: nonEmpty(usage["apiKey"] as? String),
            baseURL: nonEmpty(usage["baseUrl"] as? String),
            accessToken: nonEmpty(usage["accessToken"] as? String),
            userID: nonEmpty(usage["userId"] as? String),
            codingPlanProvider: nonEmpty(usage["codingPlanProvider"] as? String)
        )
    }

    static func groups(_ list: [Configured]) -> [Group] {
        var order: [String] = []
        var byKey: [String: Group] = [:]
        for item in list {
            let key = [item.script.templateType ?? "script", item.script.code, item.baseURL.lowercased(), item.apiKey,
                       item.script.accessToken ?? "", item.script.userID ?? ""].joined(separator: "\u{1}")
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = Group(configured: item, members: [item.entry])
            } else {
                byKey[key]?.members.append(item.entry)
            }
        }
        return order.compactMap { byKey[$0] }
    }

    // MARK: - Asking

    static func query(_ group: Group, session: URLSession = .shared) async -> Outcome {
        let item = group.configured
        switch item.script.templateType {
        case "balance":
            return await nativeBalance(baseURL: item.entry.baseURL ?? item.baseURL, apiKey: item.entry.key ?? item.apiKey, session: session)
        case "token_plan":
            return await codingPlan(baseURL: item.baseURL, apiKey: item.apiKey, session: session)
        default:
            switch await CCSwitchUsageScript.run(
                code: item.script.code, apiKey: item.apiKey, baseURL: item.baseURL, timeout: item.script.timeout,
                accessToken: item.script.accessToken, userID: item.script.userID,
                templateType: item.script.templateType, session: session
            ) {
            case .success(let rows): return .money(rows)
            case .failure(let failure):
                // The script's path is the user's; the gateway may still
                // answer its own billing routes with the same key on the same
                // host, as the CC Switch ring asks them.
                if let fallback = await relayFallback(item.entry) { return fallback }
                return .failed(failure.message)
            }
        }
    }

    /// New API's key routes, then sub2api's, at the root of the entry's own
    /// host — the CC Switch ring's relay route. Nil when neither has figures.
    static func relayFallback(_ entry: CCSwitchStore.Entry) async -> Outcome? {
        guard case .relay(let root) = CCSwitchUsageService.kind(of: entry), let key = entry.key else { return nil }
        for reading in [await NewAPIUsageService(enteredKey: key, address: root).fetch(),
                        await Sub2APIUsageService(enteredKey: key, address: root).fetch()] {
            guard reading.hasFigures, let money = reading.creditRemaining else { continue }
            return .money([.init(planName: reading.plan, remaining: money.amount, unit: money.currency, isValid: true)])
        }
        return nil
    }

    /// CC Switch's `balance::get_balance`, for the providers Pulse knows. The
    /// others it supports (StepFun, SiliconFlow, OpenRouter, Novita) are left
    /// to their own Pulse providers.
    static func nativeBalance(baseURL: String, apiKey: String, session: URLSession) async -> Outcome {
        guard !apiKey.isEmpty else { return .failed(L.noKey) }
        let lower = baseURL.lowercased()
        guard lower.contains("api.deepseek.com") else { return .failed(L.unsupported) }
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!, timeoutInterval: 15)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failed("HTTP \(http.statusCode)")
            }
            return deepSeek(data)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// CC Switch's `parse_deepseek_balance`: one row per currency wallet, and
    /// empty wallets dropped whenever another one has money in it.
    static func deepSeek(_ data: Data) -> Outcome {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failed(L.unreadable)
        }
        let available = json["is_available"] as? Bool ?? true
        var rows: [CCSwitchUsageScript.UsageData] = []
        for info in json["balance_infos"] as? [[String: Any]] ?? [] {
            let currency = info["currency"] as? String ?? "CNY"
            let total: Double? = switch info["total_balance"] {
            case let text as String: Double(text)
            case let number as NSNumber: number.doubleValue
            default: nil
            }
            rows.append(.init(planName: currency, remaining: total, unit: currency, isValid: available,
                              invalidMessage: available ? nil : "Insufficient balance"))
        }
        if rows.contains(where: { ($0.remaining ?? 0) > 0 }) {
            rows.removeAll { $0.remaining.map { $0 <= 0 } ?? false }
        }
        return rows.isEmpty ? .failed(L.unreadable) : .money(rows)
    }

    static func codingPlan(baseURL: String, apiKey: String, session: URLSession) async -> Outcome {
        guard !apiKey.isEmpty else { return .failed(L.noKey) }
        let host = URL(string: baseURL)?.host?.lowercased() ?? ""
        let provider: Provider
        if host.hasSuffix("bigmodel.cn") { provider = .glmCoding }
        else if host == "api.z.ai" || host.hasSuffix(".z.ai") { provider = .zai }
        else { return .failed(L.unsupported) }
        let reading = await ZaiUsageService(provider: provider, enteredKey: apiKey).fetch()
        switch reading.state {
        case .unavailable(.zaiNoCodingPlan):
            // CC Switch's rule (#8465): a pay-as-you-go account has no coding
            // plan, so its balance is shown instead of a failure.
            return await zhipuBalance(isChina: provider == .glmCoding, apiKey: apiKey, session: session)
        case .unavailable(let reason):
            return .failed(reason.message)
        default:
            // A subscriber's account can hold money too (top-ups for models
            // the plan does not cover), so it is shown beside the plan.
            let money: CCSwitchUsageScript.UsageData? = if case .money(let rows) = await zhipuBalance(
                isChina: provider == .glmCoding, apiKey: apiKey, session: session) { rows.first } else { nil }
            return .plan(name: reading.plan, windows: reading.windows, money: money)
        }
    }

    /// CC Switch's `query_zhipu_balance`: the account report, with the key
    /// as the bare `Authorization` value the plan route also takes.
    static func zhipuBalance(isChina: Bool, apiKey: String, session: URLSession) async -> Outcome {
        let host = isChina ? "https://open.bigmodel.cn" : "https://api.z.ai"
        var request = URLRequest(url: URL(string: "\(host)/api/biz/account/query-customer-account-report")!, timeoutInterval: 15)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failed("HTTP \(http.statusCode)")
            }
            return zhipu(data, isChina: isChina)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func zhipu(_ data: Data, isChina: Bool) -> Outcome {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failed(L.unreadable) }
        if json["success"] as? Bool == false { return .failed((json["msg"] as? String) ?? L.unreadable) }
        let body = json["data"] as? [String: Any] ?? json
        func number(_ key: String) -> Double? {
            switch body[key] {
            case let n as NSNumber: n.doubleValue
            case let t as String: Double(t)
            default: nil
            }
        }
        // `availableBalance` is what is left after anything frozen.
        guard let available = number("availableBalance") ?? number("balance"), available.isFinite else {
            return .failed(L.unreadable)
        }
        return .money([.init(planName: isChina ? "Zhipu GLM" : "Z.ai", remaining: available,
                             used: number("totalSpendAmount"), unit: isChina ? "CNY" : "USD", isValid: true)])
    }

    enum L {
        static var noKey: String { String.localized("No key is set for this provider in CC Switch.") }
        static var unsupported: String { String.localized("Pulse cannot run this kind of usage query yet.") }
        static var unreadable: String { String.localized("The reply could not be read.") }
    }
}

// MARK: - What Pulse has watched the balance do

/// Each CC Switch balance as Pulse has seen it over time, so the widget can
/// say what was spent and draw the trend.
///
/// **Watched, never inferred.** A drop between two readings is money spent; a
/// rise is a top-up and counts as nothing. Before the second reading there is
/// no figure at all, and the widget says so rather than drawing a zero.
struct BalanceHistory: Sendable {
    struct Sample: Codable, Sendable, Equatable {
        var at: Date
        var amount: Double
    }

    static let keptDays = 120

    var samples: [String: [Sample]] = [:]

    /// The key is the account's CC Switch slot and currency, never its key.
    static func key(id: String, currency: String) -> String { "\(id)|\(currency)" }

    /// Adds a reading when the balance moved, or when an hour has passed so a
    /// flat line is a known flat line. Old samples fall off.
    mutating func record(_ amount: Double, for key: String, at now: Date) {
        var list = samples[key] ?? []
        if let last = list.last, abs(last.amount - amount) < 0.000_1, now.timeIntervalSince(last.at) < 3600 { return }
        list.append(Sample(at: now, amount: amount))
        let cutoff = now.addingTimeInterval(-Double(Self.keptDays) * 86_400)
        list.removeAll { $0.at < cutoff }
        samples[key] = list
    }

    /// Money spent per local day: the sum of every drop that ended that day.
    func spentByDay(_ key: String, calendar: Calendar = .current) -> [Date: Double] {
        let list = samples[key] ?? []
        var out: [Date: Double] = [:]
        for (previous, next) in zip(list, list.dropFirst()) where previous.amount > next.amount {
            out[calendar.startOfDay(for: next.at), default: 0] += previous.amount - next.amount
        }
        return out
    }

    /// The balance at the end of each day that has a reading.
    func closingByDay(_ key: String, calendar: Calendar = .current) -> [Date: Double] {
        var out: [Date: Double] = [:]
        for sample in samples[key] ?? [] { out[calendar.startOfDay(for: sample.at)] = sample.amount }
        return out
    }

    /// When the first reading was taken, so "spent" can say since when.
    func since(_ key: String) -> Date? { samples[key]?.first?.at }

    // MARK: Disk

    static var file: URL { PulseStorage.directory.appending(path: "ccswitch-balance-history.json") }

    static func load(from file: URL = BalanceHistory.file) -> BalanceHistory {
        guard let data = try? Data(contentsOf: file) else { return BalanceHistory() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return BalanceHistory(samples: (try? decoder.decode([String: [Sample]].self, from: data)) ?? [:])
    }

    func store(to file: URL = BalanceHistory.file) {
        PulseStorage.prepare()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(samples) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
