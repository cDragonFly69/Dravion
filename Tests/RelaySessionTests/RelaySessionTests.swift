// Includes a frame helper adapted from api-use@0a66c2e,
// Tests/PulseTests/StructuredLogReadersTests.swift (Apache-2.0, © 2026 qunqin24).
import Foundation
import Testing
import RelayCore
@testable import Relay

struct RelaySessionTests {
    @Test func conversationAndTrajectoryResolveTheSameTurnIDs() {
        var run = RelayRun(input: .init(title: "布局", goal: "目标", projectID: "p", executorIDs: ["e"]),
                           project: .init(id: "p", name: "P", path: "/tmp"),
                           roles: [.init(id: "e", name: "员工", stage: .executor, connectionID: "c")], connections: [])
        run.status = .executing
        let events = [
            RelayEvent(runID: run.id, kind: .input, message: "目标"),
            RelayEvent(runID: run.id, kind: .tool, message: "read", roleID: "e", taskID: "t"),
            RelayEvent(runID: run.id, kind: .text, message: "第一轮回复", roleID: "e", taskID: "t"),
            RelayEvent(runID: run.id, kind: .status, message: "阶段切换"),
            RelayEvent(runID: run.id, kind: .text, message: "第二轮回复", roleID: "e", taskID: "t")
        ]
        let items = RelayThreadItem.items(run, events: events)
        let graph = RelayTrajectory.build(run: run, events: events)
        #expect(items.count == 4)
        #expect(graph.records.allSatisfy { record in items.contains { $0.id == record.threadItemID } })
        let turns = items.compactMap { item -> RelayThreadTurn? in if case .turn(let turn) = item { return turn }; return nil }
        #expect(turns.map(\.reply) == ["第一轮回复", "第二轮回复"])
        #expect(turns.map(\.isLast) == [false, true])
    }

    @Test func terminalEventsKeepCommandOutputAndCodeChanges() throws {
        let command = #"{"type":"command_execution","command":"swift test","aggregatedOutput":"first\nlast","exitCode":7}"#
        let output = RelayEventLine.from(.init(runID: "fixture", kind: .tool, message: command))
        #expect(output.body == "swift test\nfirst\nlast\n退出码 7")
        let edit = #"{"name":"Edit","input":{"file_path":"Main.swift","old_string":"old\nline","new_string":"new\nline"}}"#
        let changed = RelayEventLine.from(.init(runID: "fixture", kind: .tool, message: edit))
        #expect(changed.body == "Main.swift\n-old\n-line\n+new\n+line")
    }

    @Test func employeeStateDistinguishesManualPauseAndWaitingForAnAnswer() throws {
        var state = RelayState.initial()
        let role = try #require(state.roles.first { $0.id == "engineer" })
        let input = RelayRunInput(title: "Fixture", goal: "Fixture", projectID: "fixture", executorIDs: [role.id])
        var run = RelayRun(input: input, project: .init(id: "fixture", name: "Fixture", path: "/tmp"), roles: [role], connections: [])
        run.status = .paused; run.currentRoleID = role.id; run.pause = .init(reason: .user, message: "手动暂停")
        state.runs = [run]
        #expect(RelayEmployeeState.of(role, in: state, events: [:]).kind == .paused)
        run.pendingQuestion = .init(question: "继续哪个步骤？")
        run.pause = .init(reason: .awaitingUser, message: "等回复")
        state.runs = [run]
        #expect(RelayEmployeeState.of(role, in: state, events: [:]).kind == .waitingUser)
        run.status = .executing; run.pendingQuestion = nil; run.pause = nil; run.waitingForSession = "等待席位"
        state.runs = [run]
        #expect(RelayEmployeeState.of(role, in: state, events: [:]).kind == .waitingSession)
    }

    @Test func compressedDeepSeekSessionsRemainSelectable() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".dsh/sessions/project/session-example")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"session","id":"session-example","cwd":"/workspace/example"}"#,
            #"{"type":"session/title","data":{"title":"Resume example"}}"#,
            #"{"type":"request/header","data":{"header":{"config":{"model":"test-model"}}}}"#,
        ]
        let plain = Data((lines.joined(separator: "\n") + "\n").utf8)
        try plain.write(to: directory.appendingPathComponent("session.jsonl"))
        try lines.reduce(into: Data()) { $0.append(frame($1 + "\n")) }
            .write(to: directory.appendingPathComponent("session.v4.jsonl.zstd"))

        let scan = RelayClientSessions.read(home: home, environment: [:])
        #expect(scan.issues.isEmpty)
        let session = try #require(scan.sessions.only)
        #expect(session.sessionID == "session-example")
        #expect(session.projectPath == "/workspace/example")
        #expect(session.title == "Resume example")
        #expect(session.model == "test-model")
        #expect(session.provider == .deepseekHarness)
    }

    @Test func unreadableCompressedSessionExplainsTheDecodeFailure() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".dsh/sessions/project/broken")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data(DSHZstdDecoder.magic) + Data("not a zstd frame".utf8)
        try corrupt.write(to: directory.appendingPathComponent("session.v4.jsonl.zstd"))

        let scan = RelayClientSessions.read(home: home, environment: [:])
        #expect(scan.sessions.isEmpty)
        let issue = try #require(scan.issues.only)
        #expect(issue.contains("zstd decode failed:"))
        #expect(!issue.contains("Failure"))
    }

    @Test func sessionDetailReadsIDsAndSortsClaudeAndCodexTurns() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let claude = home.appendingPathComponent("claude.jsonl")
        try [
            #"{"type":"user","sessionId":"11111111-2222-3333-4444-555555555555","cwd":"/tmp/fixture","timestamp":"2026-10-30T01:00:00.000Z","message":{"role":"user","content":"修复拖放"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","model":"claude-fixture","content":[{"type":"thinking","thinking":"先读代码"},{"type":"text","text":"好的"},{"type":"tool_use","name":"Edit","input":{"file_path":"A.swift"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok","is_error":true}]}}"#,
        ].joined(separator: "\n").write(to: claude, atomically: true, encoding: .utf8)
        let first = RelayTranscript.read(claude.path)
        #expect(first.sessionID == "11111111-2222-3333-4444-555555555555")
        #expect(first.model == "claude-fixture" && first.directory == "/tmp/fixture")
        #expect(first.entries.map(\.kind) == [.user, .thinking, .assistant, .tool, .result])
        #expect(first.entries.first { $0.kind == .tool }?.title == "Edit")
        #expect(first.entries.first { $0.kind == .result }?.title == "错误")

        let codex = home.appendingPathComponent("rollout-2026-10-30T01-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl")
        try [
            #"{"type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","cwd":"/tmp/codex"}}"#,
            #"{"type":"turn_context","payload":{"model":"codex-fixture"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"跑测试"}]}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"swift\",\"test\"]}"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","output":"{\"output\":\"passed\"}"}}"#,
        ].joined(separator: "\n").write(to: codex, atomically: true, encoding: .utf8)
        let second = RelayTranscript.read(codex.path)
        #expect(second.sessionID == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" && second.model == "codex-fixture")
        #expect(second.entries.map(\.kind) == [.system, .user, .tool, .result])
        #expect(second.entries[2].text == "swift test" && second.entries[3].text == "passed")
        #expect(RelayTranscript.idFromName(codex.lastPathComponent) == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    }

    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("DravionSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    // Adapted from api-use StructuredLogReadersTests (Apache-2.0, © 2026 qunqin24).
    // Each short JSONL record is a separate raw zstd frame, as in a live append-only transcript.
    private func frame(_ text: String) -> Data {
        let bytes = Data(text.utf8)
        precondition(bytes.count < 256)
        let header = UInt32(1) | (UInt32(bytes.count) << 3)
        return Data([0x28, 0xB5, 0x2F, 0xFD, 0x20, UInt8(bytes.count),
                     UInt8(header & 0xFF), UInt8((header >> 8) & 0xFF), UInt8((header >> 16) & 0xFF)]) + bytes
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
