import Foundation

/// The desktop widget's balance list: every CC Switch provider whose usage
/// query is switched on, with what is left, what was spent and how both
/// moved over the last thirty days.
///
/// Written beside the quota snapshot as `balances.json`. Figures only — names,
/// amounts, dates. No key, address path or raw reply leaves Pulse.
///
/// Three sources, each named for what it is:
///
/// - **What is left** is the provider's own figure, asked the way CC Switch
///   asks it (`CCSwitchBalances`).
/// - **Spent** is the provider's `used` where its query reports one;
///   otherwise the drops Pulse has watched in the balance (`BalanceHistory`),
///   with the date watching began, and nothing before a second reading.
/// - **Tokens per day** are CC Switch's own records for those providers
///   (`CCSwitchUsageStats.providerDays`), so the trend is there on day one.
enum WidgetBalancePublisher {
    struct Balances: Codable {
        var schemaVersion = 1
        var generatedAt: Date
        var items: [Item]
    }

    struct Item: Codable {
        var id: String
        var name: String
        var names: [String]
        var apps: [String]
        var icon: String
        /// `money`, `plan` or `failed`.
        var kind: String
        var planName: String?
        var remaining: Double?
        var used: Double?
        var total: Double?
        var unit: String?
        var isValid: Bool
        var message: String?
        var windows: [Window]
        /// When Pulse began watching this balance; nil when `used` is the provider's.
        var watchedSince: Date?
        /// Where the spending figures come from: `console` (DeepSeek's own
        /// thirty days), `watched` (drops Pulse saw), or nil.
        var spentSource: String?
        var spent7d: Double?
        var spent30d: Double?
        var spentDays: [Point]
        var balanceDays: [Point]
        var usageDays: [UsageDay]
        var tokens7d: Int
        var cost7d: Double
        var requests7d: Int
    }

    struct Window: Codable {
        var kind: String
        var name: String
        var usedFraction: Double
        var resetsAt: Date?
        var isExhausted: Bool
    }

    struct Point: Codable {
        var date: Date
        var value: Double
    }

    struct UsageDay: Codable {
        var date: Date
        var tokens: Int
        var cost: Double
    }

    static let days = 30
    static let interval: Duration = .seconds(5 * 60)

    @MainActor private static var loop: Task<Void, Never>?

    /// Asks every five minutes — CC Switch's own default for DeepSeek — while
    /// `isEnabled` says the CC Switch provider is on. Off means not asked.
    @MainActor static func start(isEnabled: @escaping @MainActor () -> Bool) {
        guard loop == nil, CCSwitchStore.isInstalled else { return }
        loop = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if await isEnabled() { await publish() }
                try? await Task.sleep(for: interval)
            }
        }
    }

    static func icon(for entry: CCSwitchStore.Entry) -> String {
        let host = entry.host?.lowercased() ?? ""
        if host.contains("deepseek") { return "deepseek" }
        if host.hasSuffix("bigmodel.cn") || host.hasSuffix("z.ai") { return "zai" }
        if host.contains("moonshot") || host.contains("kimi") { return "kimi" }
        if host.contains("minimax") { return "minimax" }
        if host.contains("volces") || host.contains("volcengine") { return "volcengine" }
        if host.contains("stepfun") { return "stepfun" }
        if host.contains("dashscope") || host.contains("aliyun") { return "qwen" }
        return "ccswitch"
    }

    static func publish(now: Date = Date(), calendar: Calendar = .current) async {
        let groups = CCSwitchBalances.groups(CCSwitchBalances.configured())
        guard !groups.isEmpty else { return }

        // Asked side by side: each is a different provider, and the slowest
        // should not hold the others back by its timeout.
        let outcomes = await withTaskGroup(of: (Int, CCSwitchBalances.Outcome).self) { tasks in
            for (index, group) in groups.enumerated() {
                tasks.addTask { (index, await CCSwitchBalances.query(group)) }
            }
            var out: [Int: CCSwitchBalances.Outcome] = [:]
            for await (index, outcome) in tasks { out[index] = outcome }
            return out
        }

        var history = BalanceHistory.load()
        let usage = CCSwitchUsageStats.providerDays(now: now, calendar: calendar, days: days) ?? [:]
        let today = calendar.startOfDay(for: now)
        let shownDays = (0..<days).compactMap { calendar.date(byAdding: .day, value: $0 - (days - 1), to: today) }
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today

        var items: [Item] = []
        for (index, group) in groups.enumerated() {
            let entry = group.configured.entry
            var item = Item(
                id: group.id, name: group.names.first ?? entry.name, names: group.names, apps: group.apps,
                icon: icon(for: entry), kind: "failed", isValid: true, windows: [],
                spentDays: [], balanceDays: [], usageDays: [], tokens7d: 0, cost7d: 0, requests7d: 0
            )

            switch outcomes[index] ?? .failed(CCSwitchBalances.L.unreadable) {
            case .failed(let message):
                item.message = message
            case .plan(let name, let windows, let money):
                item.kind = "plan"
                item.planName = name
                item.windows = windows.map {
                    Window(kind: kindName($0.kind), name: $0.name, usedFraction: $0.usedFraction,
                           resetsAt: $0.resetsAt, isExhausted: $0.isExhausted)
                }
                if let money { apply(money, to: &item, group: group) }
            case .money(let rows):
                let row = rows.first { $0.remaining != nil } ?? rows[0]
                item.kind = "money"
                apply(row, to: &item, group: group)
            }

            func apply(_ row: CCSwitchUsageScript.UsageData, to item: inout Item, group: CCSwitchBalances.Group) {
                if item.kind == "money" { item.planName = row.planName }
                item.remaining = row.remaining
                item.used = row.used
                item.total = row.total
                item.unit = row.unit
                item.isValid = row.isValid ?? true
                item.message = row.isValid == false ? row.invalidMessage : nil
                if let remaining = row.remaining {
                    let key = BalanceHistory.key(id: group.id, currency: row.unit ?? "")
                    history.record(remaining, for: key, at: now)
                    let spent = history.spentByDay(key, calendar: calendar)
                    let closing = history.closingByDay(key, calendar: calendar)
                    item.spentDays = shownDays.map { Point(date: $0, value: spent[$0] ?? 0) }
                    item.balanceDays = shownDays.compactMap { day in closing[day].map { Point(date: day, value: $0) } }
                    // A figure only once there are two readings to compare.
                    if (history.samples[key]?.count ?? 0) > 1 {
                        item.spentSource = "watched"
                        item.watchedSince = history.since(key)
                        item.spent7d = spent.filter { $0.key >= weekStart }.values.reduce(0, +)
                        item.spent30d = spent.values.reduce(0, +)
                    }
                }
            }

            var perDay: [Date: CCSwitchUsageStats.Totals] = [:]
            for key in group.usageKeys {
                for (day, totals) in usage[key] ?? [:] { perDay[day, default: .init()].add(totals) }
            }
            item.usageDays = shownDays.map { UsageDay(date: $0, tokens: perDay[$0]?.tokens ?? 0, cost: perDay[$0]?.cost ?? 0) }
            let week = perDay.filter { $0.key >= weekStart }.values
            item.tokens7d = week.reduce(0) { $0 + $1.tokens }
            item.cost7d = week.reduce(0) { $0 + $1.cost }
            item.requests7d = week.reduce(0) { $0 + $1.requests }
            items.append(item)
        }
        history.store()
        await applyDeepSeekConsole(to: &items, today: today, weekStart: weekStart, shownDays: shownDays, calendar: calendar)
        await write(Balances(generatedAt: now, items: items))
    }

    /// DeepSeek's own thirty days, where the console's sign-in is kept, on
    /// every CC Switch DeepSeek entry that is that account.
    ///
    /// **Matched by balance, not by key.** The console is signed in to an
    /// account and the keys belong to accounts, but neither says which: a
    /// DeepSeek balance is the account's, so every key whose balance equals
    /// the console's to the fen is a key of that account. No match, no
    /// history — another account's spending is never shown under this one.
    static func applyDeepSeekConsole(to items: inout [Item], today: Date, weekStart: Date,
                                     shownDays: [Date], calendar: Calendar) async {
        guard let token = DeepSeekConsole.keptToken else { return }
        guard case .success(let reply) = await DeepSeekConsole.balance(token: token) else { return }
        let balances = (reply.balanceInfos ?? []).compactMap { info -> (String, Double)? in
            guard let currency = info.currency, let total = info.totalBalance.flatMap(Double.init) else { return nil }
            return (currency, total)
        }
        let matches = items.indices.filter { index in
            items[index].icon == "deepseek" && items[index].kind == "money" && balances.contains { currency, total in
                currency == items[index].unit && abs(total - (items[index].remaining ?? .nan)) < 0.005
            }
        }
        guard let first = matches.first else { return }
        guard case .answered(let ledger) = await DeepSeekConsoleHistory.shared.ledger(token: token, currency: items[first].unit)
        else { return }
        let byDay = Dictionary(ledger.days.map { (calendar.startOfDay(for: $0.date), $0) }, uniquingKeysWith: { a, _ in a })
        let sameCurrency = ledger.currency == nil || ledger.currency == items[first].unit
        for index in matches {
            items[index].spentSource = "console"
            items[index].watchedSince = nil
            items[index].usageDays = shownDays.map { UsageDay(date: $0, tokens: byDay[$0]?.tokens ?? 0, cost: 0) }
            items[index].tokens7d = ledger.days.filter { $0.date >= weekStart }.reduce(0) { $0 + $1.tokens }
            items[index].cost7d = 0
            if sameCurrency {
                items[index].spentDays = shownDays.map { Point(date: $0, value: byDay[$0]?.cost ?? 0) }
                items[index].spent7d = ledger.days.filter { $0.date >= weekStart }.reduce(0) { $0 + $1.cost }
                items[index].spent30d = ledger.days.reduce(0) { $0 + $1.cost }
            }
        }
    }

    private static func kindName(_ kind: UsageWindow.Kind) -> String {
        switch kind {
        case .fiveHour: "fiveHour"
        case .weekly: "weekly"
        case .daily: "daily"
        case .monthly: "monthly"
        default: "other"
        }
    }

    private static func write(_ balances: Balances) async {
        guard let url = await MainActor.run(body: { WidgetSnapshotPublisher.snapshotURL })?
            .deletingLastPathComponent().appendingPathComponent("balances.json") else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(balances) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        WidgetReloader.reloadAll()
    }
}
