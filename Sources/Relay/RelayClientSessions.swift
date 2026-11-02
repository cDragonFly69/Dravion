import Foundation
import SQLite3
import RelayCore

enum RelayClientSessions {
    struct Scan: Sendable { var sessions: [RelayExternalSession] = []; var issues: [String] = [] }
    private static let metadataBytes = 160_000
    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> Scan {
        var scan = Scan()
        func attempt(_ name: String, _ operation: () throws -> [RelayExternalSession]) {
            do { scan.sessions += try operation() }
            catch { scan.issues.append("\(name) 会话读取失败：\(error.localizedDescription)") }
        }
        let codex = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        attempt("Codex") {
            guard FileManager.default.fileExists(atPath: codex.path) else { return [] }
            let databases = try FileManager.default.contentsOfDirectory(at: codex, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            if let database = databases.first {
                return try query(database, sql: "SELECT id, title, cwd, COALESCE(model,''), updated_at, rollout_path FROM threads WHERE archived = 0 ORDER BY updated_at DESC") { row in
                    let file = text(row, 5)
                    return .init(sessionID: text(row, 0), provider: .codex, title: title(text(row, 1), id: text(row, 0)), projectPath: text(row, 2), model: text(row, 3),
                                 updatedAt: stamp(sqlite3_column_double(row, 4)), recordPath: file, isActive: recentActiveTranscript(file, kind: .codex))
                }
            }
            return try transcripts(codex.appendingPathComponent("sessions"), kind: .codex, issues: &scan.issues)
        }
        let claude = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        attempt("Claude Code") { try transcripts(claude.appendingPathComponent("projects"), kind: .claude, issues: &scan.issues) }
        for name in [".workbuddy", ".workbuddy-ai"] {
            let root = home.appendingPathComponent(name)
            let database = root.appendingPathComponent("workbuddy.db")
            attempt("WorkBuddy") {
                guard FileManager.default.fileExists(atPath: database.path) else {
                    return try transcripts(root.appendingPathComponent("projects"), kind: .workbuddy, issues: &scan.issues)
                }
                return try query(database, sql: "SELECT id, COALESCE(custom_title,title,''), cwd, COALESCE(model,''), updated_at, status FROM sessions WHERE deleted_at IS NULL ORDER BY updated_at DESC") { row in
                    .init(sessionID: text(row, 0), provider: .workbuddy, title: title(text(row, 1), id: text(row, 0)), projectPath: text(row, 2), model: text(row, 3),
                          updatedAt: stamp(sqlite3_column_double(row, 4)), recordPath: database.path,
                          isActive: ["running", "working", "inprogress"].contains(text(row, 5).lowercased()))
                }
            }
        }
        attempt("DeepSeek Harness") { try transcripts(home.appendingPathComponent(".dsh/sessions"), kind: .deepseekHarness, issues: &scan.issues) }
        var unique: [String: RelayExternalSession] = [:]
        for session in scan.sessions {
            guard session.sessionID.range(of: #"^[A-Za-z0-9_:-]{1,200}$"#, options: .regularExpression) != nil,
                  session.projectPath.isEmpty || session.projectPath.hasPrefix("/") else {
                scan.issues.append("\(session.provider.label) 的一条会话元数据无效，已跳过。"); continue
            }
            if let old = unique[session.id], old.updatedAt > session.updatedAt { continue }
            unique[session.id] = session
        }
        scan.sessions = unique.values.sorted { $0.updatedAt > $1.updatedAt }
        scan.issues = Array(Set(scan.issues)).sorted()
        return scan
    }

    private static func query(_ url: URL, sql: String, row: (OpaquePointer) -> RelayExternalSession) throws -> [RelayExternalSession] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw RelayError.invalid("无法只读打开 \(url.lastPathComponent)。")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 500)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RelayError.invalid("\(url.lastPathComponent) 结构不兼容：\(String(cString: sqlite3_errmsg(database)))")
        }
        defer { sqlite3_finalize(statement) }
        var rows: [RelayExternalSession] = []
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw RelayError.invalid("会话数据库读取失败：\(String(cString: sqlite3_errmsg(database)))") }
            rows.append(row(statement))
        }
    }
    private static func text(_ row: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(row, index).map { String(cString: $0) } ?? ""
    }
    private static func stamp(_ number: Double) -> Date { Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number) }
    private static func title(_ value: String, id: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? id : String(cleaned.prefix(250))
    }
    private static func transcripts(_ root: URL, kind: RelayProviderKind, issues: inout [String]) throws -> [RelayExternalSession] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var enumerationError: Error?
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles], errorHandler: { _, error in enumerationError = error; return true }) else { throw RelayError.invalid("无法枚举会话目录。") }
        var result: [RelayExternalSession] = []
        for case let file as URL in files {
            try Task.checkCancellation()
            if file.lastPathComponent == "subagents" { files.skipDescendants(); continue }
            let accepted = kind == .deepseekHarness ? file.lastPathComponent.hasPrefix("session.") && file.lastPathComponent.contains(".jsonl") : file.pathExtension == "jsonl"
            guard accepted else { continue }
            do {
                if let session = try readTranscript(file, kind: kind) { result.append(session) }
            } catch { issues.append("\(kind.label) · \(file.lastPathComponent)：\(error.localizedDescription)") }
        }
        if let enumerationError { issues.append("\(kind.label) 部分目录无法读取：\(enumerationError.localizedDescription)") }
        return result
    }
    private static func sample(_ file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: metadataBytes) ?? Data()
        if DSHZstdDecoder.isZstd(prefix) {
            let size = try handle.seekToEnd()
            guard size <= DSHZstdDecoder.maxRawBytes else { throw RelayError.invalid("压缩会话超过 64 MB，无法读取。") }
            try handle.seek(toOffset: 0)
            let bytes = try handle.readToEnd() ?? Data()
            return try DSHZstdDecoder.decode(bytes)
        }
        let size = try handle.seekToEnd()
        guard size > metadataBytes else { return prefix }
        try handle.seek(toOffset: size - UInt64(metadataBytes))
        let suffix = try handle.readToEnd() ?? Data()
        // Discard the cut rows; metadata from a partial row is never accepted.
        let head = prefix.lastIndex(of: 10).map { Data(prefix[...$0]) } ?? Data()
        let tail = suffix.firstIndex(of: 10).map { Data(suffix[suffix.index(after: $0)...]) } ?? Data()
        return head + tail
    }
    private static func rows(_ data: Data) -> [[String: Any]] {
        data.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }
    private static func readTranscript(_ file: URL, kind: RelayProviderKind) throws -> RelayExternalSession? {
        let records = rows(try sample(file))
        var id = "", cwd = "", name = "", model = ""
        for row in records {
            let type = row["type"] as? String ?? ""
            if kind == .deepseekHarness {
                if type == "session" { id = row["id"] as? String ?? id; cwd = row["cwd"] as? String ?? cwd }
                let data = row["data"] as? [String: Any] ?? [:]
                if type == "request/header", let header = data["header"] as? [String: Any], let config = header["config"] as? [String: Any] { model = config["model"] as? String ?? model }
                if type == "user/message", name.isEmpty { name = content(data["content"] ?? data["message"]) }
                if type == "session/title" { name = data["title"] as? String ?? name }
            } else if kind == .codex {
                let payload = row["payload"] as? [String: Any] ?? [:]
                if type == "session_meta" { id = payload["id"] as? String ?? id; cwd = payload["cwd"] as? String ?? cwd }
                if type == "turn_context" { model = payload["model"] as? String ?? model }
                if type == "event_msg", payload["type"] as? String == "user_message", name.isEmpty { name = payload["message"] as? String ?? "" }
            } else {
                id = row["sessionId"] as? String ?? row["session_id"] as? String ?? id
                cwd = row["cwd"] as? String ?? cwd
                if type == "custom-title" { name = row["customTitle"] as? String ?? name }
                if type == "summary", name.isEmpty { name = row["summary"] as? String ?? name }
                if let message = row["message"] as? [String: Any] {
                    model = message["model"] as? String ?? model
                    if (type == "user" || row["role"] as? String == "user"), name.isEmpty { name = content(message["content"]) }
                }
            }
        }
        guard !id.isEmpty else { return nil }
        let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        return .init(sessionID: id, provider: kind, title: title(name, id: id), projectPath: cwd, model: model,
                     updatedAt: modified, recordPath: file.path, isActive: kind == .codex && active(records, modified: modified))
    }
    private static func content(_ object: Any?) -> String {
        if let text = object as? String { return text }
        if let parts = object as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined(separator: " ") }
        if let row = object as? [String: Any] { return content(row["content"]) }
        return ""
    }
    private static func recentActiveTranscript(_ path: String, kind: RelayProviderKind) -> Bool {
        let file = URL(fileURLWithPath: path)
        guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              Date().timeIntervalSince(modified) < 120, let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: size > 32_000 ? size - 32_000 : 0)
            return active(rows(try handle.readToEnd() ?? Data()), modified: modified)
        } catch { return false }
    }
    private static func active(_ records: [[String: Any]], modified: Date) -> Bool {
        guard Date().timeIntervalSince(modified) < 120 else { return false }
        for row in records.reversed() {
            let payload = row["payload"] as? [String: Any] ?? [:]
            let type = payload["type"] as? String ?? ""
            if ["task_complete", "turn_aborted", "turn_complete"].contains(type) { return false }
            if type == "task_started" { return true }
        }
        return false
    }
}
