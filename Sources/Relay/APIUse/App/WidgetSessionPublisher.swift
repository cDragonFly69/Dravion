import Foundation

/// The agent sessions behind the desktop widget's **Current session**: which
/// conversation, on which model, since when, whether it is working, and what
/// it has spent so far.
///
/// **Every agent's sessions, working ones first.** Claude Code registers each
/// running session (`ClaudeSessionRegistry`) with its id and whether it is
/// busy, waiting or idle. DeepSeek Harness holds a lock on each open session,
/// and WorkBuddy keeps a status per session in its database. Doubao's work
/// tasks are known by their output files' times alone, and carry no tokens
/// (`countsTokens` false): the widget says so rather than show a zero. Codex and every
/// other agent Token spend reads keep no such record, so a session of theirs
/// counts as working while it is being written to and is listed while it was
/// written within the last three hours (`WidgetSessionSources`). Transcripts
/// are read with the readers Token spend uses, so a session's figures are
/// counted by the same rules as every other total in the app. A file is read
/// again only when its size or modification time changed.
///
/// **Only with Token spend reading on.** That switch is the user's consent to
/// Pulse reading the agents' transcripts for counts; without it nothing is
/// read and the widget says where to turn it on. Agents whose quota provider
/// is not shown are not read either.
///
/// Written beside the quota snapshot as `sessions.json`. Counts, a model name
/// and the session's id only — no prompt, path or title leaves the transcript.
@MainActor
enum WidgetSessionPublisher {
    struct Sessions: Codable, Equatable {
        var schemaVersion = 1
        var generatedAt: Date
        /// False when Token spend reading is off, so the widget can say why it
        /// is empty.
        var isReading: Bool
        /// Newest first.
        var sessions: [Session]
    }

    struct Session: Codable, Equatable {
        var id: String
        /// Claude Code's name for the session (`pipinew1-53`), where it has one.
        var name: String? = nil
        var provider: String
        var agent: String
        var icon: String
        var model: String?
        var startedAt: Date?
        var lastActivity: Date
        /// `working`, `waiting` (stopped on a question for the user) or `idle`.
        var state: String
        /// When the current `working` or `waiting` began, for a live clock.
        var stateSince: Date?
        var input: Int
        var cacheWrite: Int
        var cacheRead: Int
        var output: Int
        var total: Int
        /// Cache reads over every input token; nil where the session's
        /// replies said nothing about the cache.
        var cacheHitRate: Double?
        /// Output over the timed replies' seconds (`ReplyTiming`); nil until
        /// a reply long enough to time has finished.
        var tokensPerSecond: Double?
        /// False for an agent that keeps no token count at all (Doubao), so
        /// its figures read as not reported rather than as nothing spent.
        var countsTokens: Bool? = nil
    }

    private static var loop: Task<Void, Never>?
    private static var workingSince: [Provider: Date] = [:]
    private static var waitingSince: [Provider: Date] = [:]
    private static var last: Sessions?
    private static let reader = UsageLedgerReader()
    private static var parsed: [URL: (size: Int, modified: Date, scanned: UsageLedgerReader.Scanned)] = [:]
    private static var harnessRecords: [URL: (size: Int, modified: Date, records: [AgentUsageRecord])] = [:]
    private static var sessionWorkingSince: [String: Date] = [:]

    static var url: URL? {
        WidgetSnapshotPublisher.snapshotURL?.deletingLastPathComponent().appendingPathComponent("sessions.json")
    }

    /// Re-reads every fifteen seconds. Between turns the files do not change,
    /// so the pass is a directory walk and nothing else.
    static func follow(store: UsageStore, settings: AppSettings) {
        guard loop == nil, url != nil else { return }
        loop = Task { @MainActor in
            while !Task.isCancelled {
                await publish(store: store, settings: settings)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private static func publish(store: UsageStore, settings: AppSettings) async {
        let now = Date()
        let running = store.activity.running
        waitingSince = store.activity.waitingSince
        workingSince = running.reduce(into: [:]) { $0[$1] = workingSince[$1] ?? now }

        var sessions: [Session] = []
        var used: Set<URL> = []
        func scanned(_ file: Transcript, _ provider: Provider) async -> UsageLedgerReader.Scanned {
            used.insert(file.url)
            if let cached = parsed[file.url], cached.size == file.size, cached.modified == file.modified {
                return cached.scanned
            }
            let scanned = await reader.parse(file.url, provider: provider)
            parsed[file.url] = (file.size, file.modified, scanned)
            return scanned
        }
        if settings.readsTokenSpend {
            let shown = Set(settings.shownAccounts.map(\.provider))
            // One entry per live Claude Code session, each with its own state.
            if shown.contains(.claudeCode) {
                let live = await Task.detached(priority: .utility) { liveClaudeSessions() }.value
                for (registered, file) in live {
                    let state: (String, Date?) = switch registered.state {
                    case .busy: ("working", registered.since)
                    case .waiting: ("waiting", registered.since)
                    case .idle: ("idle", nil)
                    }
                    var entry = session(provider: .claudeCode, file: file,
                                        scanned: await scanned(file, .claudeCode), state: state)
                    entry.name = registered.name
                    entry.startedAt = registered.startedAt ?? entry.startedAt
                    sessions.append(entry)
                }
                if live.isEmpty, let file = await Task.detached(priority: .utility, operation: {
                    newestTranscript(of: .claudeCode)
                }).value {
                    sessions.append(session(provider: .claudeCode, file: file,
                                            scanned: await scanned(file, .claudeCode),
                                            state: monitored(.claudeCode, file: file, now: now)))
                }
            }
            // Every Codex session written lately. The activity monitor's state
            // belongs to the newest; the others are working only while written to.
            if shown.contains(.codex) {
                let files = await Task.detached(priority: .utility) { recentCodexTranscripts(now: now) }.value
                for (index, file) in files.enumerated() {
                    let state = index == 0 ? monitored(.codex, file: file, now: now)
                        : now.timeIntervalSince(file.modified) < workingWindow ? ("working", nil) : ("idle", nil)
                    sessions.append(session(provider: .codex, file: file, scanned: await scanned(file, .codex), state: state))
                }
            }
            sessions += await harness(now: now, used: &used)
            sessions += await Task.detached(priority: .utility) { buddySessions(now: now) }.value.map { buddy($0, now: now) }
            sessions += await Task.detached(priority: .utility) { doubaoSessions(now: now) }.value.map { doubao($0, now: now) }
            sessions += await others(now: now)
        }
        // A working session without a start of its own keeps the moment it
        // was first seen working, for the clock.
        let working = Set(sessions.filter { $0.state == "working" }.map(\.id))
        sessionWorkingSince = sessionWorkingSince.filter { working.contains($0.key) }
        for index in sessions.indices where sessions[index].state == "working" && sessions[index].stateSince == nil {
            let since = sessionWorkingSince[sessions[index].id] ?? now
            sessionWorkingSince[sessions[index].id] = since
            sessions[index].stateSince = since
        }
        parsed = parsed.filter { used.contains($0.key) }
        harnessRecords = harnessRecords.filter { used.contains($0.key) }
        // An idle session that never counted a token — a Codex thread with no
        // reply yet — says nothing worth a row. An agent that counts none is
        // shown by its activity alone.
        sessions.removeAll { $0.state == "idle" && $0.total == 0 && $0.countsTokens != false }
        // Working and waiting sessions first, then the most recently written.
        sessions.sort { lhs, rhs in
            let l = lhs.state != "idle", r = rhs.state != "idle"
            return l != r ? l : lhs.lastActivity > rhs.lastActivity
        }
        sessions = Array(sessions.prefix(12))

        let current = Sessions(generatedAt: now, isReading: settings.readsTokenSpend, sessions: sessions)
        // The widget is asked to redraw only when something it shows changed.
        var unchanged = last
        unchanged?.generatedAt = now
        guard unchanged != current, let url else { return }
        last = current
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(current) else { return }
        try? data.write(to: url, options: .atomic)
        WidgetReloader.reloadAll()
    }

    /// The activity monitor's state for an agent's newest session, or the
    /// file's own recency where the monitor has none.
    private static func monitored(_ provider: Provider, file: Transcript, now: Date) -> (String, Date?) {
        if let since = waitingSince[provider] { return ("waiting", since) }
        if let since = workingSince[provider] { return ("working", since) }
        return now.timeIntervalSince(file.modified) < workingWindow ? ("working", nil) : ("idle", nil)
    }

    /// DeepSeek Harness: every open or recent session, counted with the
    /// reader Token spend uses. A transcript is decoded again only when it changed.
    private static func harness(now: Date, used: inout Set<URL>) async -> [Session] {
        let found = await Task.detached(priority: .utility) { harnessSessions(now: now) }.value
        var result: [Session] = []
        for harness in found {
            let file = harness.transcript
            used.insert(file.url)
            let records: [AgentUsageRecord]
            if let cached = harnessRecords[file.url], cached.size == file.size, cached.modified == file.modified {
                records = cached.records
            } else {
                let directory = harness.directory
                records = await Task.detached(priority: .utility) { DSHUsageReader.records(roots: [directory]) }.value
                harnessRecords[file.url] = (file.size, file.modified, records)
            }
            let agent = SpendAgent.dsh
            let working = harness.isOpen && now.timeIntervalSince(file.modified) < workingWindow
            result.append(counted(
                records, id: harness.id, name: "\(agent.displayName) · \(harness.project)", agent: agent,
                model: records.max { $0.timestamp < $1.timestamp }?.model,
                startedAt: records.map(\.timestamp).min() ?? file.created,
                lastActivity: max(file.modified, records.map(\.timestamp).max() ?? .distantPast),
                state: working ? "working" : "idle"
            ))
        }
        return result
    }

    private static func buddy(_ session: BuddySession, now: Date) -> Session {
        let agent = SpendAgent.workBuddy
        return Session(
            id: session.id, name: session.project.map { "\(agent.displayName) · \($0)" } ?? agent.displayName,
            provider: agent.rawValue, agent: agent.displayName, icon: agent.widgetIcon, model: session.model,
            startedAt: session.created, lastActivity: session.lastActivity,
            state: buddyIsWorking(session, now: now) ? "working" : "idle", stateSince: nil,
            input: 0, cacheWrite: 0, cacheRead: 0, output: 0, total: session.tokens,
            cacheHitRate: nil, tokensPerSecond: nil
        )
    }

    private static func doubao(_ session: DoubaoSession, now: Date) -> Session {
        Session(
            id: session.id, name: String.localized("Doubao work task"), provider: "doubao",
            agent: String.localized("Doubao"), icon: "volcengine", model: nil,
            startedAt: session.started, lastActivity: session.lastActivity,
            state: now.timeIntervalSince(session.lastActivity) < workingWindow ? "working" : "idle", stateSince: nil,
            input: 0, cacheWrite: 0, cacheRead: 0, output: 0, total: 0,
            cacheHitRate: nil, tokensPerSecond: nil, countsTokens: false
        )
    }

    /// Every other agent Token spend reads, from its last finished scan
    /// (`SpendWarmer` keeps it within minutes): the sessions that worked
    /// within `recentWindow`.
    private static func others(now: Date) async -> [Session] {
        guard let kept = await AgentLedgers.shared.keptSnapshot() else { return [] }
        let handled: Set<SpendAgent> = [.claudeCode, .codex, .dsh, .workBuddy]
        var result: [Session] = []
        for (agent, ledger) in kept.snapshot.ledgers where !handled.contains(agent) {
            for entry in ledger.sessions where now.timeIntervalSince(entry.end) < recentWindow {
                var models: [String: TokenTally] = [:]
                for slot in entry.slots {
                    for (model, tally) in slot.models { models[model, default: TokenTally()] = models[model, default: TokenTally()] + tally }
                }
                let tally = models.values.reduce(TokenTally(), +)
                let model = models.max { $0.value.total < $1.value.total }?.key
                let cacheable = tally.input + tally.cacheWrite + tally.cacheRead
                result.append(Session(
                    id: entry.id.components(separatedBy: "#").last ?? entry.id,
                    name: entry.project.map { "\(agent.displayName) · \($0.name)" } ?? agent.displayName,
                    provider: agent.rawValue, agent: agent.displayName, icon: agent.widgetIcon,
                    model: model.map { ledger.modelNames[$0] ?? $0 },
                    startedAt: entry.start, lastActivity: entry.end,
                    state: now.timeIntervalSince(entry.end) < workingWindow ? "working" : "idle", stateSince: nil,
                    input: tally.input, cacheWrite: tally.cacheWrite, cacheRead: tally.cacheRead, output: tally.output,
                    total: entry.tokens,
                    cacheHitRate: cacheable > 0 && !tally.reportsNoCache ? Double(tally.cacheRead) / Double(cacheable) : nil,
                    tokensPerSecond: nil
                ))
            }
        }
        return result
    }

    /// A session from decoded records: their kinds summed, and the bare
    /// totals some stores report beside them.
    private static func counted(
        _ records: [AgentUsageRecord], id: String, name: String, agent: SpendAgent, model: String?,
        startedAt: Date?, lastActivity: Date, state: String
    ) -> Session {
        let tally = records.map(\.tally).reduce(TokenTally(), +)
        let unclassified = records.reduce(0) { $0 + $1.unclassifiedTokens }
        let cacheable = tally.input + tally.cacheWrite + tally.cacheRead
        return Session(
            id: id, name: name, provider: agent.rawValue, agent: agent.displayName, icon: agent.widgetIcon,
            model: model, startedAt: startedAt, lastActivity: lastActivity, state: state, stateSince: nil,
            input: tally.input, cacheWrite: tally.cacheWrite, cacheRead: tally.cacheRead, output: tally.output,
            total: tally.total + unclassified,
            cacheHitRate: cacheable > 0 && !tally.reportsNoCache ? Double(tally.cacheRead) / Double(cacheable) : nil,
            tokensPerSecond: nil
        )
    }

    private static func session(
        provider: Provider, file: Transcript, scanned: UsageLedgerReader.Scanned, state: (String, Date?)
    ) -> Session {
        let days = scanned.allDays
        let tally = days.values.flatMap(\.values).reduce(TokenTally(), +)
        // The model of the newest quarter-hour with any work, and of that the
        // one that did the most.
        let model = days.keys.max().flatMap { slot in days[slot]?.max { $0.value.total < $1.value.total }?.key }
        let timing = scanned.allTimings.values.flatMap(\.values).reduce(ReplyTiming(), +)
        let cacheable = tally.input + tally.cacheWrite + tally.cacheRead
        return Session(
            id: file.sessionID, provider: provider.rawValue, agent: provider.displayName,
            icon: provider.iconResource, model: model, startedAt: file.created, lastActivity: file.modified,
            state: state.0, stateSince: state.1,
            input: tally.input, cacheWrite: tally.cacheWrite, cacheRead: tally.cacheRead, output: tally.output,
            total: tally.total,
            cacheHitRate: cacheable > 0 && !tally.reportsNoCache ? Double(tally.cacheRead) / Double(cacheable) : nil,
            tokensPerSecond: timing.replies > 0 && timing.seconds > 0 ? Double(timing.outputTokens) / timing.seconds : nil
        )
    }

    struct Transcript: Sendable {
        let url: URL
        let size: Int
        let created: Date?
        let modified: Date

        /// Claude Code names a transcript `<session id>.jsonl`; Codex names a
        /// rollout `rollout-<time>-<session id>.jsonl`. Both ids are UUIDs.
        var sessionID: String {
            let name = url.deletingPathExtension().lastPathComponent
            return name.count > 36 ? String(name.suffix(36)) : name
        }
    }

    /// Every live Claude Code session in its register, each with its
    /// transcript, `<project>/<session id>.jsonl`. A session whose transcript
    /// is not there yet — nothing sent — is left out.
    nonisolated static func liveClaudeSessions(
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> [(ClaudeSessionRegistry.Session, Transcript)] {
        let registered = ClaudeSessionRegistry.read().filter { $0.sessionID != nil }
        guard !registered.isEmpty, let root = AgentActivity.root(for: .claudeCode, home: home),
              let projects = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey, .fileSizeKey]
        return registered.compactMap { session in
            for project in projects {
                let url = project.appendingPathComponent("\(session.sessionID!).jsonl")
                guard let values = try? url.resourceValues(forKeys: keys),
                      let modified = values.contentModificationDate, let size = values.fileSize, size > 0
                else { continue }
                return (session, Transcript(url: url, size: size, created: values.creationDate, modified: modified))
            }
            return nil
        }
    }

    /// The agent's most recently written session file. A Claude Code
    /// sub-agent's transcript is its parent's work, not a session of its own.
    nonisolated static func newestTranscript(
        of provider: Provider, home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> Transcript? {
        guard let root = AgentActivity.root(for: provider, home: home) else { return nil }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        var newest: Transcript?
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl", !url.path.contains("/subagents/"),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate,
                  let size = values.fileSize, size > 0
            else { continue }
            if newest.map({ modified > $0.modified }) ?? true {
                newest = Transcript(url: url, size: size, created: values.creationDate, modified: modified)
            }
        }
        return newest
    }
}
