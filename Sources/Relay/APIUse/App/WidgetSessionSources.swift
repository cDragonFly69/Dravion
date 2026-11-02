import Darwin
import Foundation
import SQLite3

/// Where the widget's **Sessions** finds the agents other than Claude Code:
/// each one's own record of which conversations are open and when they last
/// worked. Nothing here writes, locks or sends anything.
extension WidgetSessionPublisher {
    /// How far back a session that is not known to be open still counts.
    nonisolated static let recentWindow: TimeInterval = 3 * 60 * 60
    /// A session written to this recently is taken as working.
    nonisolated static let workingWindow: TimeInterval = 90

    /// Every Codex rollout written within `recentWindow`, newest first.
    /// Codex keeps no register of open sessions, so recency is all there is.
    nonisolated static func recentCodexTranscripts(
        now: Date = Date(), home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> [Transcript] {
        guard let root = AgentActivity.root(for: .codex, home: home) else { return [] }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [Transcript] = []
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) < recentWindow,
                  let size = values.fileSize, size > 0
            else { continue }
            found.append(Transcript(url: url, size: size, created: values.creationDate, modified: modified))
        }
        return found.sorted { $0.modified > $1.modified }
    }

    // MARK: - DeepSeek Harness

    struct HarnessSession: Sendable {
        let id: String
        let project: String
        let directory: URL
        let transcript: Transcript
        /// DeepSeek Harness holds `session.lock` for as long as the session is
        /// open in it.
        let isOpen: Bool
    }

    /// DeepSeek Harness sessions that are open, or were written within
    /// `recentWindow`: `~/.dsh/sessions/<encoded cwd>/session-<id>/`.
    nonisolated static func harnessSessions(
        now: Date = Date(), home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> [HarnessSession] {
        let root = home.appending(path: ".dsh/sessions")
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey, .fileSizeKey]
        guard let projects = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var found: [HarnessSession] = []
        for project in projects {
            guard let directories = try? manager.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)
            else { continue }
            for directory in directories where directory.lastPathComponent.hasPrefix("session-") {
                guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
                else { continue }
                // `session.jsonl`, `session.v4.jsonl.zstd` and the like name one
                // transcript; the newest copy stands for it.
                let transcript = files.filter {
                    $0.lastPathComponent.hasPrefix("session.") && $0.lastPathComponent.contains(".jsonl")
                }.compactMap { url -> Transcript? in
                    guard let values = try? url.resourceValues(forKeys: keys),
                          let modified = values.contentModificationDate, let size = values.fileSize, size > 0
                    else { return nil }
                    return Transcript(url: url, size: size, created: values.creationDate, modified: modified)
                }.max { $0.modified < $1.modified }
                guard let transcript else { continue }
                let isOpen = isLocked(directory.appending(path: "session.lock"))
                guard isOpen || now.timeIntervalSince(transcript.modified) < recentWindow else { continue }
                found.append(HarnessSession(
                    id: String(directory.lastPathComponent.dropFirst("session-".count)),
                    project: projectName(project.lastPathComponent),
                    directory: directory, transcript: transcript, isOpen: isOpen
                ))
            }
        }
        return found
    }

    /// Whether another process holds a lock on the file. `F_GETLK` only asks;
    /// it takes no lock of its own.
    nonisolated static func isLocked(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var probe = flock()
        probe.l_type = Int16(F_WRLCK)
        probe.l_whence = Int16(SEEK_SET)
        guard fcntl(descriptor, F_GETLK, &probe) == 0 else { return false }
        return probe.l_type != Int16(F_UNLCK)
    }

    /// `--Users-me-code-pipinew1--` is the directory's path with its slashes
    /// replaced; only the last component is shown.
    nonisolated static func projectName(_ encoded: String) -> String {
        let trimmed = encoded.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let last = trimmed.components(separatedBy: "-").last ?? trimmed
        return last.replacingOccurrences(of: "~0020", with: " ")
    }

    // MARK: - WorkBuddy

    struct BuddySession: Sendable {
        let id: String
        let project: String?
        let model: String?
        let status: String
        let created: Date?
        let lastActivity: Date
        let tokens: Int
    }

    /// WorkBuddy's sessions active within `recentWindow`, from its own
    /// database (`workbuddy.db`): status, model and the token count it keeps
    /// per session, which Token spend counts too.
    nonisolated static func buddySessions(
        now: Date = Date(), home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> [BuddySession] {
        let cutoff = Int((now.timeIntervalSince1970 - recentWindow) * 1000)
        let sql = """
            SELECT s.id, s.cwd, s.model, s.status, s.created_at,
                   COALESCE(s.last_activity_at, s.updated_at), COALESCE(u.used, 0)
            FROM sessions s LEFT JOIN session_usage u ON u.session_id = s.id
            WHERE COALESCE(s.last_activity_at, s.updated_at) >= \(cutoff)
              AND (s.deleted_at IS NULL OR s.deleted_at <= 0)
            """
        return [".workbuddy", ".workbuddy-ai"].flatMap { folder -> [BuddySession] in
            AgentSQLite.read(at: home.appending(path: "\(folder)/workbuddy.db")) { database in
                var rows: [BuddySession] = []
                AgentSQLite.each(database, sql: sql) { statement in
                    guard let id = AgentSQLite.text(statement, column: 0),
                          let last = EditorLog.autoEpoch(DatabaseReaderSupport.intColumn(statement, 5))
                    else { return }
                    rows.append(BuddySession(
                        id: id,
                        project: AgentSQLite.text(statement, column: 1).map { URL(fileURLWithPath: $0).lastPathComponent },
                        model: AgentSQLite.text(statement, column: 2),
                        status: AgentSQLite.text(statement, column: 3) ?? "",
                        created: EditorLog.autoEpoch(DatabaseReaderSupport.intColumn(statement, 4)),
                        lastActivity: last,
                        tokens: DatabaseReaderSupport.intColumn(statement, 6) ?? 0
                    ))
                }
                return rows
            } ?? []
        }
    }

    // MARK: - Doubao

    struct DoubaoSession: Sendable, Equatable {
        let id: String
        let started: Date
        let lastActivity: Date
        /// The commands the run has started.
        let tasks: Int
    }

    /// Doubao's work tasks (`com.bot.pc.doubao`). A task runs its commands in
    /// Doubao's own sandbox and keeps each command's output in
    /// `Default/agent_infra/to/lr_<run>/task_outputs/<command id>/output.log`
    /// under its Application Support folder. Only the files' times are read —
    /// when the run's first command started, when the newest one last wrote,
    /// how many there were — never what they printed. Doubao keeps its
    /// conversations on its servers and no token count on the Mac.
    nonisolated static func doubaoSessions(
        now: Date = Date(), home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> [DoubaoSession] {
        let root = home.appending(path: "Library/Application Support/Doubao/Default/agent_infra/to")
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        guard let runs = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return runs.compactMap { run -> DoubaoSession? in
            let name = run.lastPathComponent
            guard name.hasPrefix("lr_"),
                  let commands = try? manager.contentsOfDirectory(
                      at: run.appending(path: "task_outputs"), includingPropertiesForKeys: Array(keys))
            else { return nil }
            var started: Date?, last: Date?
            for command in commands {
                let created = (try? command.resourceValues(forKeys: keys))?.creationDate
                let log = command.appending(path: "output.log")
                let written = (try? log.resourceValues(forKeys: keys))?.contentModificationDate
                    ?? (try? command.resourceValues(forKeys: keys))?.contentModificationDate
                if let created { started = min(started ?? created, created) }
                if let written { last = max(last ?? written, written) }
            }
            guard let last, now.timeIntervalSince(last) < recentWindow else { return nil }
            return DoubaoSession(id: String(name.dropFirst(3)), started: started ?? last, lastActivity: last,
                                 tasks: commands.count)
        }
    }

    /// WorkBuddy marks a finished turn `completed` or `error`; any other
    /// status on a recent session is a turn still running.
    nonisolated static func buddyIsWorking(_ session: BuddySession, now: Date) -> Bool {
        let finished: Set<String> = ["completed", "error", "failed", "cancelled", "canceled", "aborted", "stopped", "idle"]
        let quiet = now.timeIntervalSince(session.lastActivity)
        return quiet < workingWindow || (!finished.contains(session.status.lowercased()) && quiet < 30 * 60)
    }
}
