import Foundation
import SQLite3

/// Token usage as CC Switch's own usage dashboard counts it, read from its
/// database so the two never disagree.
///
/// Every rule here is CC Switch's, ported from `src-tauri/src/services/`
/// (`sql_helpers.rs`, `usage_stats.rs`):
///
/// - **Two tables.** `proxy_request_logs` holds recent requests one row each;
///   `usage_daily_rollups` holds older days already added up. A day is in one
///   or the other, and a rolled-up day is counted only when the range covers
///   it whole.
/// - **Fresh input.** Codex, Gemini and Grok Build report input *including*
///   the cached part, Claude reports it without; `input_token_semantics`
///   says which a row uses (0 legacy, 1 total, 2 already fresh).
/// - **Real total** = fresh input + output + cache write + cache read.
/// - **Cache hit rate** = cache read / (fresh input + cache write + cache read).
/// - **Duplicates.** A request seen both by CC Switch's proxy and in a
///   session log is counted once: the session row is dropped when a
///   successful proxy row with the same counts and model sits within ten
///   minutes of it.
/// - **Model** is `pricing_model` when set, else `model`.
/// - **Ranges** are CC Switch's presets: today from local midnight, 7 days
///   from local midnight six days ago, both to now.
enum CCSwitchUsageStats {
    struct Totals: Sendable, Codable, Equatable {
        var tokens = 0
        var requests = 0
        var cost = 0.0
        var input = 0
        var output = 0
        var cacheWrite = 0
        var cacheRead = 0

        var cacheHitRate: Double? {
            let cacheable = input + cacheWrite + cacheRead
            return cacheable > 0 ? Double(cacheRead) / Double(cacheable) : nil
        }

        mutating func add(_ other: Totals) {
            tokens += other.tokens
            requests += other.requests
            cost += other.cost
            input += other.input
            output += other.output
            cacheWrite += other.cacheWrite
            cacheRead += other.cacheRead
        }
    }

    struct Model: Sendable, Codable, Equatable {
        var name: String
        var totals: Totals
    }

    struct Report: Sendable {
        var today = Totals()
        var last5h = Totals()
        var week = Totals()
        var modelsToday: [Model] = []
        var modelsWeek: [Model] = []
        /// Everything on record, and by model.
        var all = Totals()
        var modelsAll: [Model] = []
        /// Everything on record by tool (`app_type`) and then by model.
        var appModelsAll: [String: [Model]] = [:]
        /// Local calendar day (start of day) → real total tokens.
        var days: [Date: Int] = [:]
    }

    static let freshInput = """
        CASE WHEN l.input_token_semantics = 2 THEN l.input_tokens
             WHEN l.app_type IN ('codex','gemini','grokbuild') AND l.input_token_semantics = 1
                  AND l.input_tokens >= l.cache_read_tokens + l.cache_creation_tokens
               THEN l.input_tokens - l.cache_read_tokens - l.cache_creation_tokens
             WHEN l.app_type IN ('codex','gemini','grokbuild') AND l.input_token_semantics = 0
                  AND l.input_tokens >= l.cache_read_tokens
               THEN l.input_tokens - l.cache_read_tokens
             ELSE l.input_tokens END
        """

    static let notDuplicate = """
        NOT (COALESCE(l.data_source,'proxy') IN ('session_log','codex_session','gemini_session','opencode_session')
          AND EXISTS (SELECT 1 FROM proxy_request_logs p
            WHERE COALESCE(p.data_source,'proxy') = 'proxy'
              AND p.app_type IN (l.app_type, CASE WHEN l.app_type = 'claude' THEN 'claude-desktop' ELSE l.app_type END)
              AND p.status_code >= 200 AND p.status_code < 300
              AND p.input_tokens = l.input_tokens AND p.output_tokens = l.output_tokens
              AND p.cache_read_tokens = l.cache_read_tokens
              AND (p.cache_creation_tokens = l.cache_creation_tokens
                   OR (l.cache_creation_tokens = 0
                       AND COALESCE(l.data_source,'proxy') IN ('codex_session','gemini_session','opencode_session'))
                   OR (p.cache_creation_tokens = 0 AND p.input_token_semantics = 0
                       AND COALESCE(l.data_source,'proxy') = 'codex_session'))
              AND p.created_at BETWEEN l.created_at - 600 AND l.created_at + 600
              AND (LOWER(p.model) = LOWER(l.model) OR LOWER(p.model) = 'unknown' OR LOWER(l.model) = 'unknown')))
        """

    /// The detail rows of a time range, one aggregate row per `group`.
    static func detailSQL(from start: Int, to end: Int, group: String) -> String {
        """
        SELECT \(group), COUNT(*), COALESCE(SUM(CAST(l.total_cost_usd AS REAL)), 0),
               COALESCE(SUM(\(freshInput)), 0), COALESCE(SUM(l.output_tokens), 0),
               COALESCE(SUM(l.cache_creation_tokens), 0), COALESCE(SUM(l.cache_read_tokens), 0)
        FROM proxy_request_logs l
        WHERE l.created_at >= \(start) AND l.created_at <= \(end) AND \(notDuplicate)
        GROUP BY 1
        """
    }

    /// Rolled-up days between two local dates, inclusive, one row per `group`.
    static func rollupSQL(fromDay start: String, toDay end: String, group: String) -> String {
        let fresh = freshInput.replacingOccurrences(of: "l.", with: "r.")
        return """
        SELECT \(group), COALESCE(SUM(r.request_count), 0), COALESCE(SUM(CAST(r.total_cost_usd AS REAL)), 0),
               COALESCE(SUM(\(fresh)), 0), COALESCE(SUM(r.output_tokens), 0),
               COALESCE(SUM(r.cache_creation_tokens), 0), COALESCE(SUM(r.cache_read_tokens), 0)
        FROM usage_daily_rollups r
        WHERE r.date >= '\(start)' AND r.date <= '\(end)'
        GROUP BY 1
        """
    }

    /// Each provider's days, keyed `"<app_type>|<provider_id>"` and then by
    /// local day, counted by the same rules as `report`. This is what CC
    /// Switch recorded going through each provider, so it is there from the
    /// first launch, unlike a balance history Pulse has to watch build up.
    static func providerDays(at url: URL = CCSwitchStore.databaseURL, now: Date = Date(),
                             calendar: Calendar = .current, days: Int = 30) -> [String: [Date: Totals]]? {
        let today = calendar.startOfDay(for: now)
        guard
            let start = calendar.date(byAdding: .day, value: -(days - 1), to: today),
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        else { return nil }
        let dayFormat = DateFormatter()
        dayFormat.calendar = calendar
        dayFormat.timeZone = calendar.timeZone
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.dateFormat = "yyyy-MM-dd"

        return AgentSQLite.read(at: url) { db -> [String: [Date: Totals]] in
            var out: [String: [Date: Totals]] = [:]
            func collect(_ sql: String) {
                AgentSQLite.each(db, sql: sql) { statement in
                    guard let key = AgentSQLite.text(statement, column: 0) else { return }
                    let parts = key.split(separator: "|", omittingEmptySubsequences: false)
                    guard parts.count == 3, let day = dayFormat.date(from: String(parts[2])) else { return }
                    let input = Int(sqlite3_column_int64(statement, 3))
                    let output = Int(sqlite3_column_int64(statement, 4))
                    let write = Int(sqlite3_column_int64(statement, 5))
                    let read = Int(sqlite3_column_int64(statement, 6))
                    let totals = Totals(tokens: input + output + write + read,
                                        requests: Int(sqlite3_column_int64(statement, 1)),
                                        cost: sqlite3_column_double(statement, 2),
                                        input: input, output: output, cacheWrite: write, cacheRead: read)
                    out["\(parts[0])|\(parts[1])", default: [:]][calendar.startOfDay(for: day), default: Totals()].add(totals)
                }
            }
            collect(detailSQL(
                from: Int(start.timeIntervalSince1970), to: Int(now.timeIntervalSince1970),
                group: "l.app_type || '|' || l.provider_id || '|' || date(l.created_at, 'unixepoch', 'localtime')"
            ))
            collect(rollupSQL(
                fromDay: dayFormat.string(from: start), toDay: dayFormat.string(from: yesterday),
                group: "r.app_type || '|' || r.provider_id || '|' || r.date"
            ))
            return out
        }
    }

    /// What one tool spent, as CC Switch recorded it.
    struct AppCost: Sendable, Equatable {
        var app: String
        var today = Totals()
        var week = Totals()
        var month = Totals()
        var all = Totals()
        /// The newest record of this tool, so a reader can tell figures that
        /// stopped being collected from a tool that stopped being used.
        var lastRecord: Date?
    }

    /// Spending per tool (`app_type`) for today, 7 days, 30 days and
    /// everything CC Switch holds, by the same rules as `report`.
    static func costs(at url: URL = CCSwitchStore.databaseURL, now: Date = Date(),
                      calendar: Calendar = .current) -> [AppCost]? {
        let today = calendar.startOfDay(for: now)
        guard
            let weekStart = calendar.date(byAdding: .day, value: -6, to: today),
            let monthStart = calendar.date(byAdding: .day, value: -29, to: today),
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        else { return nil }
        let dayFormat = DateFormatter()
        dayFormat.calendar = calendar
        dayFormat.timeZone = calendar.timeZone
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.dateFormat = "yyyy-MM-dd"
        let end = Int(now.timeIntervalSince1970)
        let lastFullDay = dayFormat.string(from: yesterday)

        return AgentSQLite.read(at: url) { db -> [AppCost] in
            var byApp: [String: AppCost] = [:]
            func collect(_ sql: String, into path: WritableKeyPath<AppCost, Totals>) {
                AgentSQLite.each(db, sql: sql) { statement in
                    guard let app = AgentSQLite.text(statement, column: 0) else { return }
                    let input = Int(sqlite3_column_int64(statement, 3))
                    let output = Int(sqlite3_column_int64(statement, 4))
                    let write = Int(sqlite3_column_int64(statement, 5))
                    let read = Int(sqlite3_column_int64(statement, 6))
                    byApp[app, default: AppCost(app: app)][keyPath: path].add(Totals(
                        tokens: input + output + write + read, requests: Int(sqlite3_column_int64(statement, 1)),
                        cost: sqlite3_column_double(statement, 2),
                        input: input, output: output, cacheWrite: write, cacheRead: read))
                }
            }
            func range(_ start: Date, _ path: WritableKeyPath<AppCost, Totals>, rollups: Bool) {
                collect(detailSQL(from: Int(start.timeIntervalSince1970), to: end, group: "l.app_type"), into: path)
                if rollups {
                    collect(rollupSQL(fromDay: dayFormat.string(from: start), toDay: lastFullDay, group: "r.app_type"), into: path)
                }
            }
            range(today, \.today, rollups: false)
            range(weekStart, \.week, rollups: true)
            range(monthStart, \.month, rollups: true)
            collect(detailSQL(from: 0, to: end, group: "l.app_type"), into: \.all)
            collect(rollupSQL(fromDay: "0000-01-01", toDay: lastFullDay, group: "r.app_type"), into: \.all)

            AgentSQLite.each(db, sql: "SELECT app_type, MAX(created_at) FROM proxy_request_logs GROUP BY 1") { statement in
                guard let app = AgentSQLite.text(statement, column: 0) else { return }
                let at = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1)))
                byApp[app, default: AppCost(app: app)].lastRecord = max(byApp[app]?.lastRecord ?? at, at)
            }
            AgentSQLite.each(db, sql: "SELECT app_type, MAX(date) FROM usage_daily_rollups GROUP BY 1") { statement in
                guard let app = AgentSQLite.text(statement, column: 0),
                      let day = AgentSQLite.text(statement, column: 1).flatMap(dayFormat.date(from:)),
                      let end = calendar.date(byAdding: .day, value: 1, to: day)?.addingTimeInterval(-1)
                else { return }
                if (byApp[app]?.lastRecord ?? .distantPast) < end { byApp[app, default: AppCost(app: app)].lastRecord = end }
            }
            return byApp.values.filter { $0.all.tokens > 0 || $0.all.cost > 0 }.sorted { $0.all.cost > $1.all.cost }
        }
    }

    static func report(at url: URL = CCSwitchStore.databaseURL, now: Date = Date(),
                       calendar: Calendar = .current, heatmapDays: Int = 182) -> Report? {
        let today = calendar.startOfDay(for: now)
        guard
            let weekStart = calendar.date(byAdding: .day, value: -6, to: today),
            let heatStart = calendar.date(byAdding: .day, value: -(heatmapDays - 1), to: today),
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        else { return nil }
        let end = Int(now.timeIntervalSince1970)
        let dayFormat = DateFormatter()
        dayFormat.calendar = calendar
        dayFormat.timeZone = calendar.timeZone
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.dateFormat = "yyyy-MM-dd"

        return AgentSQLite.read(at: url) { db -> Report in
            func rows(_ sql: String) -> [(key: String, totals: Totals)] {
                var out: [(String, Totals)] = []
                AgentSQLite.each(db, sql: sql) { statement in
                    let input = Int(sqlite3_column_int64(statement, 3))
                    let output = Int(sqlite3_column_int64(statement, 4))
                    let write = Int(sqlite3_column_int64(statement, 5))
                    let read = Int(sqlite3_column_int64(statement, 6))
                    out.append((
                        AgentSQLite.text(statement, column: 0) ?? "",
                        Totals(tokens: input + output + write + read,
                               requests: Int(sqlite3_column_int64(statement, 1)),
                               cost: sqlite3_column_double(statement, 2),
                               input: input, output: output, cacheWrite: write, cacheRead: read)
                    ))
                }
                return out
            }
            func sum(_ rows: [(key: String, totals: Totals)]) -> Totals {
                rows.reduce(into: Totals()) { $0.add($1.totals) }
            }
            func models(_ rows: [(key: String, totals: Totals)]) -> [Model] {
                var merged: [String: Totals] = [:]
                for row in rows { merged[row.key, default: Totals()].add(row.totals) }
                return merged.map { Model(name: $0.key, totals: $0.value) }
                    .filter { $0.totals.tokens > 0 }
                    .sorted { $0.totals.tokens > $1.totals.tokens }
            }

            let model = "COALESCE(NULLIF(l.pricing_model, ''), l.model)"
            let rollupModel = "COALESCE(NULLIF(r.pricing_model, ''), r.model)"
            let localDay = "date(l.created_at, 'unixepoch', 'localtime')"
            let todayStart = Int(today.timeIntervalSince1970)
            let weekStartTS = Int(weekStart.timeIntervalSince1970)
            let weekFirstDay = dayFormat.string(from: weekStart)
            let lastFullDay = dayFormat.string(from: yesterday)

            var report = Report()

            let todayRows = rows(detailSQL(from: todayStart, to: end, group: model))
            report.today = sum(todayRows)
            report.modelsToday = models(todayRows)

            report.last5h = sum(rows(detailSQL(from: end - 5 * 3600, to: end, group: "1")))

            let weekRows = rows(detailSQL(from: weekStartTS, to: end, group: model))
                + rows(rollupSQL(fromDay: weekFirstDay, toDay: lastFullDay, group: rollupModel))
            report.week = sum(weekRows)
            report.modelsWeek = models(weekRows)

            // Every detail row still kept, and every day already rolled up —
            // the same pair the week is read from, without its lower edge.
            let allRows = rows(detailSQL(from: 0, to: end, group: model))
                + rows(rollupSQL(fromDay: "0000-01-01", toDay: lastFullDay, group: rollupModel))
            report.all = sum(allRows)
            report.modelsAll = models(allRows)

            // The same rows split by tool. The separator is a control
            // character no app type or model name contains.
            let byApp = rows(detailSQL(from: 0, to: end, group: "l.app_type || char(31) || \(model)"))
                + rows(rollupSQL(fromDay: "0000-01-01", toDay: lastFullDay,
                                 group: "r.app_type || char(31) || \(rollupModel)"))
            var split: [String: [(key: String, totals: Totals)]] = [:]
            for row in byApp {
                let parts = row.key.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                split[String(parts[0]), default: []].append((String(parts[1]), row.totals))
            }
            report.appModelsAll = split.mapValues(models)

            let heatRows = rows(detailSQL(from: Int(heatStart.timeIntervalSince1970), to: end, group: localDay))
                + rows(rollupSQL(fromDay: dayFormat.string(from: heatStart), toDay: lastFullDay, group: "r.date"))
            for row in heatRows {
                guard let day = dayFormat.date(from: row.key) else { continue }
                report.days[calendar.startOfDay(for: day), default: 0] += row.totals.tokens
            }
            return report
        }
    }
}
