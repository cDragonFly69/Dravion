import Darwin
import Foundation

/// Claude Code's own register of its running sessions, for the one state the
/// transcripts cannot show: **waiting on you** — a permission prompt or a
/// question the session will not get past without an answer.
///
/// Studied from [codenotch](https://github.com/vinzdg/codenotch) (MIT), which
/// reads the same register; approach only, no code. Claude Code writes one
/// file per interactive session, `~/.claude/sessions/<pid>.json`:
///
/// ```json
/// {"pid": 79048, "cwd": "…", "name": "api-use-6f", "status": "busy",
///  "statusUpdatedAt": 1792809605616, "entrypoint": "cli"}
/// ```
///
/// `status` is `busy`, `idle` or `waiting` (newer builds also write `tempo`:
/// `active`, `idle`, `blocked`). A desktop-hosted session writes no status and
/// is left to the transcripts. **A file is only a session while its process
/// lives**: a crash leaves the file behind, so every pid is checked.
enum ClaudeSessionRegistry {
    struct Session: Sendable, Equatable {
        enum State: String, Sendable { case busy, waiting, idle }

        let pid: Int32
        let name: String
        let state: State
        let since: Date?
        /// What it wants, where Claude Code says.
        let waitingFor: String?
        /// The conversation's id — its transcript is `<id>.jsonl` — and when
        /// the process started, where Claude Code writes them.
        var sessionID: String? = nil
        var startedAt: Date? = nil
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    }

    static func read(in directory: URL = directory, isAlive: (Int32) -> Bool = isAlive) -> [Session] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let session = session(from: json), isAlive(session.pid)
            else { return nil }
            return session
        }
    }

    /// Nil for a record without a pid or without a status this reader knows.
    static func session(from json: [String: Any]) -> Session? {
        guard let pid = (json["pid"] as? NSNumber)?.int32Value else { return nil }
        let state: Session.State
        switch (json["tempo"] as? String, json["status"] as? String) {
        case ("blocked", _), (_, "waiting"): state = .waiting
        case ("active", _), (_, "busy"): state = .busy
        case ("idle", _), (_, "idle"): state = .idle
        default: return nil
        }
        let millis = (json["statusUpdatedAt"] as? NSNumber)?.doubleValue ?? (json["updatedAt"] as? NSNumber)?.doubleValue
        let cwd = json["cwd"] as? String ?? ""
        return Session(
            pid: pid,
            name: (json["name"] as? String) ?? (cwd as NSString).lastPathComponent,
            state: state,
            since: millis.map { Date(timeIntervalSince1970: $0 / 1000) },
            waitingFor: (json["waitingFor"] as? String) ?? (json["needs"] as? String),
            sessionID: json["sessionId"] as? String,
            startedAt: ((json["startedAt"] as? NSNumber)?.doubleValue).map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }

    /// `kill(pid, 0)`: no signal is sent. `EPERM` is a process that exists
    /// but belongs to someone else, which still counts as alive.
    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
