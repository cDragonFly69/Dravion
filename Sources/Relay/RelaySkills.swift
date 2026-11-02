import Foundation
import RelayCore

/// Skill use as the clients record it, and the switch that takes a skill out of every client.
enum RelaySkills {
    /// The skill a tool record uses: Claude Code's `Skill` tool, a harness `skill` tool, or any client opening a
    /// skill's `SKILL.md` (Read, or a shell command such as `cat …/skills/name/SKILL.md`).
    static func name(fromTool json: [String: Any]) -> String? {
        let input = json["input"] as? [String: Any] ?? [:]
        if let tool = (json["name"] ?? json["tool"]) as? String {
            switch tool.lowercased() {
            case "skill", "use_skill", "load_skill", "invoke_skill":
                return (input["skill"] ?? input["name"] ?? input["command"]) as? String
            default:
                let path = (input["file_path"] ?? input["path"] ?? input["command"] ?? input["cmd"]) as? String ?? ""
                return fromPath(path)
            }
        }
        let item = json["item"] as? [String: Any] ?? json
        if item["type"] as? String == "command_execution" { return fromPath(item["command"] as? String ?? "") }
        return nil
    }

    /// ".../skills/pdf/SKILL.md" → "pdf".
    static func fromPath(_ text: String) -> String? {
        guard text.contains("SKILL.md"),
              let match = text.firstMatch(of: /\/([^\/\s'"]+)\/SKILL\.md/) else { return nil }
        return String(match.output.1)
    }

    // MARK: Usage

    struct Usage: Sendable {
        var calls = 0
        var last: Date?
        /// Model (as the client reported it, else as configured, else the employee) → calls.
        var models: [String: Int] = [:]
        var runs: Set<String> = []
    }

    /// Every skill use in every run's saved events, by skill name. Reads the event files directly so it does not
    /// load all history into the app.
    static func usage(runs: [RelayRun], eventsDirectory: URL) -> [String: Usage] {
        var result: [String: Usage] = [:]
        let decoder = ISO8601DateFormatter()
        for run in runs {
            let file = eventsDirectory.appendingPathComponent("\(run.id).jsonl")
            guard let text = try? String(contentsOf: file, encoding: .utf8), text.contains("kill") else { continue }
            for line in text.split(separator: "\n") where line.contains("\"tool\"") && (line.contains("SKILL.md") || line.contains("kill")) {
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      event["kind"] as? String == "tool",
                      let message = event["message"] as? String,
                      let body = message.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let name = name(fromTool: json) else { continue }
                let date = (event["date"] as? String).flatMap { decoder.date(from: $0) }
                let roleID = event["roleID"] as? String
                let call = run.callRecords?.last { record in record.roleID == roleID && (date.map { record.startedAt <= $0 } ?? true) }
                let model = call?.reportedModel ?? call.flatMap { $0.requestedModel.isEmpty ? nil : $0.requestedModel }
                    ?? run.roles.first { $0.id == roleID }?.name ?? "未知模型"
                var entry = result[name] ?? Usage()
                entry.calls += 1
                entry.models[model, default: 0] += 1
                entry.runs.insert(run.id)
                if let date, date > (entry.last ?? .distantPast) { entry.last = date }
                result[name] = entry
            }
        }
        return result
    }

    // MARK: Turning a skill off everywhere

    /// Where switched-off skills wait: outside every client's skills folder, so no client loads them, keeping the
    /// path they came from under the home folder (…/disabled-skills/.claude/skills/pdf).
    static var disabledRoot: URL { RelayHostPaths.root.appendingPathComponent("disabled-skills", isDirectory: true) }

    /// Moves the skill's folder out of its client (off) or back where it was (on).
    static func setEnabled(_ enabled: Bool, skillFile: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let folder = URL(fileURLWithPath: skillFile).deletingLastPathComponent().standardizedFileURL
        let manager = FileManager.default
        if enabled {
            let prefix = disabledRoot.standardizedFileURL.path + "/"
            guard folder.path.hasPrefix(prefix) else { return }
            let destination = home.appendingPathComponent(String(folder.path.dropFirst(prefix.count)))
            guard !manager.fileExists(atPath: destination.path) else { throw RelayError.invalid("原位置已经有同名技能：\(destination.path)") }
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: folder, to: destination)
        } else {
            let homePrefix = home.standardizedFileURL.path + "/"
            guard folder.path.hasPrefix(homePrefix) else { throw RelayError.invalid("只能停用个人目录下的技能。") }
            let destination = disabledRoot.appendingPathComponent(String(folder.path.dropFirst(homePrefix.count)))
            guard !manager.fileExists(atPath: destination.path) else { throw RelayError.invalid("停用区已有同名技能：\(destination.path)") }
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: folder, to: destination)
        }
    }
}
