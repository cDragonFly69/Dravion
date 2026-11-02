import Foundation

/// Token usage for the desktop widget: today, the last five hours and seven
/// days, cache hit rates, the models doing the work and a daily heatmap.
///
/// **CC Switch first.** Where CC Switch is installed its own usage records
/// are the source (`CCSwitchUsageStats`), counted exactly the way its
/// dashboard counts them, so the widget and CC Switch show the same numbers.
/// Without it, Pulse's own Token spend ledgers are used instead.
///
/// Written beside the quota snapshot as `spend.json`. Counts only, already
/// added up — no prompt, path, session or key leaves either source.
enum WidgetSpendPublisher {
    struct Spend: Codable {
        var schemaVersion = 3
        var generatedAt: Date
        /// `ccSwitch` or `pulse`.
        var source: String
        var today: Totals
        var last5h: Totals
        var week: Totals
        /// One per calendar day, oldest first, ending today.
        var days: [Day]
        var modelsToday: [Model]
        var modelsWeek: [Model]
        /// Everything on record, and the models it went to — the quota
        /// widget's total and its breakdown.
        var all: Totals? = nil
        var modelsAll: [Model]? = nil
        /// CC Switch only: everything on record by tool (`app_type`), then by
        /// model — the quota widget's line per tool.
        var appModels: [String: [Model]]? = nil
        /// Spending per tool, CC Switch only (its own `app_type`).
        var apps: [AppCost]? = nil
    }

    /// One tool's or one agent's spending over the four spans the widget shows.
    struct AppCost: Codable {
        var id: String
        var name: String
        var icon: String
        var currency: String?
        var today: Amount
        var week: Amount
        var month: Amount
        var all: Amount
        /// Newest record (CC Switch) or the first day with any use (local).
        var lastRecord: Date?
        var since: Date?
        /// Everything this agent recorded, by model (Pulse's own ledgers only),
        /// so the widget can add an agent CC Switch does not see to its
        /// breakdown.
        var models: [Model]? = nil
        /// The part of `all.tokens` read from the prompt cache.
        var cacheRead: Int? = nil
    }

    struct Amount: Codable {
        var cost: Double
        var tokens: Int
    }

    /// Pulse's own reading of each agent's local logs, priced at API rates.
    struct LocalCosts: Codable {
        var schemaVersion = 1
        var generatedAt: Date
        var agents: [AppCost]
    }

    struct Totals: Codable {
        var tokens: Int
        var requests: Int?
        var cost: Double
        var cacheHitRate: Double?
    }

    struct Day: Codable {
        var date: Date
        var tokens: Int
    }

    struct Model: Codable {
        var name: String
        var tokens: Int
        var requests: Int?
        var cost: Double?
        var cacheHitRate: Double?
        /// The part of `tokens` read from the prompt cache: the same context
        /// counted again on every request, which the quota widget shows apart.
        var cacheRead: Int? = nil
    }

    static let heatmapDays = 26 * 7

    private static var url: URL? {
        get async {
            await MainActor.run { WidgetSnapshotPublisher.snapshotURL }?
                .deletingLastPathComponent().appendingPathComponent("spend.json")
        }
    }

    private static func write(_ spend: Spend) async {
        guard let url = await url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(spend) else { return }
        try? data.write(to: url, options: .atomic)
        WidgetReloader.reloadAll()
    }

    // MARK: - CC Switch

    /// Re-reads CC Switch's records every minute while Pulse runs. The read is
    /// a handful of indexed queries — milliseconds on tens of thousands of
    /// requests — so there is nothing to save by reading less often.
    @MainActor private static var loop: Task<Void, Never>?

    @MainActor static func startFollowingCCSwitch() {
        guard loop == nil, CCSwitchStore.isInstalled else { return }
        loop = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                await publishFromCCSwitch()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    static func publishFromCCSwitch(now: Date = Date(), calendar: Calendar = .current) async {
        guard let report = CCSwitchUsageStats.report(now: now, calendar: calendar, heatmapDays: heatmapDays) else { return }
        func totals(_ t: CCSwitchUsageStats.Totals) -> Totals {
            Totals(tokens: t.tokens, requests: t.requests, cost: t.cost, cacheHitRate: t.cacheHitRate)
        }
        func models(_ list: [CCSwitchUsageStats.Model], limit: Int = 8) -> [Model] {
            list.prefix(limit).map {
                Model(name: $0.name, tokens: $0.totals.tokens, requests: $0.totals.requests,
                      cost: $0.totals.cost, cacheHitRate: $0.totals.cacheHitRate, cacheRead: $0.totals.cacheRead)
            }
        }
        await write(Spend(
            generatedAt: now,
            source: "ccSwitch",
            today: totals(report.today),
            last5h: totals(report.last5h),
            week: totals(report.week),
            days: days(report.days, now: now, calendar: calendar),
            modelsToday: models(report.modelsToday),
            modelsWeek: models(report.modelsWeek),
            all: totals(report.all),
            // Every model, not the top few: the widget groups them by family,
            // and a family made of many small models is still a large share.
            modelsAll: models(report.modelsAll, limit: 200),
            appModels: report.appModelsAll.mapValues { models($0, limit: 40) },
            apps: (CCSwitchUsageStats.costs(now: now, calendar: calendar) ?? []).map { cost in
                func amount(_ t: CCSwitchUsageStats.Totals) -> Amount { Amount(cost: t.cost, tokens: t.tokens) }
                let (name, icon): (String, String) = switch cost.app {
                case "claude": ("Claude Code", "claude")
                case "codex": ("Codex", "openai")
                case "gemini": ("Gemini CLI", "gemini")
                case "opencode": ("OpenCode", "opencode")
                default: (cost.app, "ccswitch")
                }
                // CC Switch prices everything in dollars.
                return AppCost(id: cost.app, name: name, icon: icon, currency: "USD",
                               today: amount(cost.today), week: amount(cost.week), month: amount(cost.month),
                               all: amount(cost.all), lastRecord: cost.lastRecord)
            }
        ))
    }

    /// Each agent's spending from Pulse's own ledgers — Codex's
    /// `~/.codex/sessions`, Claude Code's transcripts and so on — written on
    /// every Token spend scan whether or not CC Switch is installed. CC
    /// Switch's figures and these count many of the same requests, so the
    /// widget shows them side by side and never adds one to the other.
    static func publishLocalCosts(_ ledgers: [SpendAgent: UsageLedger], now: Date = Date(), calendar: Calendar = .current) async {
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let monthStart = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        var agents: [AppCost] = []
        for (agent, ledger) in ledgers where ledger.origin.supportsTokenSpend {
            func amount(from start: Date?) -> Amount {
                let days = ledger.days.filter { day in start.map { calendar.startOfDay(for: day.date) >= $0 } ?? true }
                return Amount(cost: days.reduce(0) { $0 + $1.cost }, tokens: days.reduce(0) { $0 + $1.tokens })
            }
            let all = amount(from: nil)
            guard all.tokens > 0 else { continue }
            var models: [String: (tokens: Int, cacheRead: Int)] = [:]
            var cacheRead = 0
            for day in ledger.days {
                cacheRead += day.tally.cacheRead
                for (id, tokens) in day.models where tokens > 0 {
                    let name = ledger.modelNames[id] ?? id
                    let read = day.modelTallies[id]?.cacheRead ?? 0
                    models[name] = ((models[name]?.tokens ?? 0) + tokens, (models[name]?.cacheRead ?? 0) + read)
                }
            }
            agents.append(AppCost(
                id: agent.rawValue, name: agent.displayName, icon: agent.widgetIcon, currency: ledger.currency ?? "USD",
                today: amount(from: today), week: amount(from: weekStart), month: amount(from: monthStart), all: all,
                since: ledger.days.first { $0.tokens > 0 }?.date,
                models: models.sorted { $0.value.tokens > $1.value.tokens }.prefix(40)
                    .map { Model(name: $0.key, tokens: $0.value.tokens, cacheRead: $0.value.cacheRead) },
                cacheRead: cacheRead
            ))
        }
        agents.sort { $0.month.cost != $1.month.cost ? $0.month.cost > $1.month.cost : $0.all.cost > $1.all.cost }
        guard let url = await url?.deletingLastPathComponent().appendingPathComponent("local-costs.json") else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(LocalCosts(generatedAt: now, agents: Array(agents.prefix(24)))) else { return }
        try? data.write(to: url, options: .atomic)
        WidgetReloader.reloadAll()
    }

    // MARK: - Pulse's own ledgers (no CC Switch)

    static func publish(_ ledgers: [SpendAgent: UsageLedger], now: Date = Date(), calendar: Calendar = .current) async {
        await publishLocalCosts(ledgers, now: now, calendar: calendar)
        // CC Switch's figures win wherever it is installed; this would only
        // overwrite them with a differently counted total.
        guard !CCSwitchStore.isInstalled else { return }

        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let heatStart = calendar.date(byAdding: .day, value: -(heatmapDays - 1), to: today) ?? today
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)

        var byDay: [Date: Int] = [:]
        var todayTally = TokenTally(), weekTally = TokenTally()
        var todayCost = 0.0, weekCost = 0.0, last5h = 0, last5hCost = 0.0
        var modelsToday: [String: Int] = [:], modelsWeek: [String: Int] = [:], modelsAll: [String: Int] = [:]
        var allTally = TokenTally(), allTokens = 0, allCost = 0.0

        // The same gate as every Token spend total: a provider's own
        // statistics are not this Mac's records.
        for ledger in ledgers.values where ledger.origin.supportsTokenSpend {
            func name(_ id: String) -> String { ledger.modelNames[id] ?? id }
            for day in ledger.days where day.tokens > 0 {
                let date = calendar.startOfDay(for: day.date)
                allTokens += day.tokens
                allCost += day.cost
                allTally = allTally + day.tally
                for (id, tokens) in day.models { modelsAll[name(id), default: 0] += tokens }
                guard date >= heatStart, date <= today else { continue }
                byDay[date, default: 0] += day.tokens
                if date >= weekStart {
                    weekCost += day.cost
                    weekTally = weekTally + day.tally
                    for (id, tokens) in day.models { modelsWeek[name(id), default: 0] += tokens }
                }
                if date == today {
                    todayCost += day.cost
                    todayTally = todayTally + day.tally
                    for (id, tokens) in day.models { modelsToday[name(id), default: 0] += tokens }
                }
            }
            for slot in ledger.slots where slot.start >= fiveHoursAgo && slot.start <= now {
                last5h += slot.tokens
                last5hCost += slot.cost
            }
        }

        func hitRate(_ tally: TokenTally) -> Double? {
            let cacheable = tally.input + tally.cacheWrite + tally.cacheRead
            return cacheable > 0 ? Double(tally.cacheRead) / Double(cacheable) : nil
        }
        func top(_ models: [String: Int], limit: Int = 8) -> [Model] {
            models.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(limit)
                .map { Model(name: $0.key, tokens: $0.value) }
        }
        let shownDays = days(byDay, now: now, calendar: calendar)
        await write(Spend(
            generatedAt: now,
            source: "pulse",
            today: Totals(tokens: byDay[today] ?? 0, cost: todayCost, cacheHitRate: hitRate(todayTally)),
            last5h: Totals(tokens: last5h, cost: last5hCost),
            week: Totals(tokens: shownDays.filter { $0.date >= weekStart }.reduce(0) { $0 + $1.tokens },
                         cost: weekCost, cacheHitRate: hitRate(weekTally)),
            days: shownDays,
            modelsToday: top(modelsToday),
            modelsWeek: top(modelsWeek),
            all: Totals(tokens: allTokens, cost: allCost, cacheHitRate: hitRate(allTally)),
            modelsAll: top(modelsAll, limit: 200)
        ))
    }

    private static func days(_ byDay: [Date: Int], now: Date, calendar: Calendar) -> [Day] {
        let today = calendar.startOfDay(for: now)
        guard var cursor = calendar.date(byAdding: .day, value: -(heatmapDays - 1), to: today) else { return [] }
        var days: [Day] = []
        while cursor <= today {
            days.append(Day(date: cursor, tokens: byDay[cursor] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }
}

extension SpendAgent {
    /// The widget's asset name for this agent: the provider marks it ships.
    var widgetIcon: String {
        // The mark Token spend draws for the agent, which the widget's
        // catalog carries too; none where the icon set has no honest one.
        iconResource ?? "sparkle"
    }
}
