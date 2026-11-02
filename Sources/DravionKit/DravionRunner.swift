import Foundation
import Observation
import RelayCore

/// The desktop runner (D6): lets the Dravion platform run tasks on this Mac with the local clients.
/// It signs in once to register the device, then only uses the device credential (Keychain). Runs are
/// claimed one at a time, in the one directory the user allowed, and never while a local Relay task
/// holds that project. Everything the client prints goes back as RunEvents; cancelling on the
/// platform stops the local process.
@MainActor @Observable public final class DravionRunner {
    public struct Active: Equatable, Sendable { public var leaseID, taskID, vendor: String; public var startedAt: Date }

    public private(set) var status = "未开启"
    public private(set) var active: Active?
    public private(set) var log: [String] = []
    public private(set) var deviceID: String?

    // Settings (UserDefaults); the credential itself lives only in the Keychain.
    public var apiURL: String { didSet { save() } }
    public var adminURL: String { didSet { save() } }
    public var deviceName: String { didSet { save() } }
    public var directory: String { didSet { save() } }
    public private(set) var enabled: Bool

    @ObservationIgnored private let store: RelayStore
    @ObservationIgnored private let executor: any RelayAgentExecuting
    @ObservationIgnored private let secrets: any RelaySecretStorage
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var cancelled = false

    /// Platform vendor names for the local clients a dispatched run may use (no Claude: ADR-012/029).
    public static let vendors: [RelayProviderKind: String] = [.codex: "codex", .deepseekHarness: "deepseek-harness"]
    static let credentialKey = "dravion-device"
    static let heartbeatSeconds: UInt64 = 10

    public init(store: RelayStore, executor: any RelayAgentExecuting,
                secrets: any RelaySecretStorage = RelayKeychain(service: "ai.dravion.desktop.device"), defaults: UserDefaults = .standard) {
        self.store = store; self.executor = executor; self.secrets = secrets; self.defaults = defaults
        apiURL = defaults.string(forKey: "dravion.apiURL") ?? "http://127.0.0.1:3300"
        adminURL = defaults.string(forKey: "dravion.adminURL") ?? "http://127.0.0.1:8090"
        deviceName = defaults.string(forKey: "dravion.deviceName") ?? (Host.current().localizedName ?? "Mac")
        directory = defaults.string(forKey: "dravion.directory") ?? ""
        enabled = defaults.bool(forKey: "dravion.enabled")
        deviceID = defaults.string(forKey: "dravion.deviceID")
        if enabled { start() }
    }
    private func save() {
        defaults.set(apiURL, forKey: "dravion.apiURL"); defaults.set(adminURL, forKey: "dravion.adminURL")
        defaults.set(deviceName, forKey: "dravion.deviceName"); defaults.set(directory, forKey: "dravion.directory")
        defaults.set(enabled, forKey: "dravion.enabled"); defaults.set(deviceID, forKey: "dravion.deviceID")
    }
    public var registered: Bool { (try? secrets.read(Self.credentialKey)) != nil }
    func client() throws -> DravionClient {
        guard let api = URL(string: apiURL), let admin = URL(string: adminURL) else { throw DravionAPIError(status: 0, code: "URL", message: "服务地址无效") }
        return DravionClient(apiURL: api, adminURL: admin)
    }

    public func capabilities() -> DravionCapabilities {
        let kinds = Set(store.state.connections.map(\.kind))
        let clients = Self.vendors.filter { kinds.contains($0.key) }.map { DravionDeviceClient(vendor: $0.value) }.sorted { $0.vendor < $1.vendor }
        return .init(clients: clients, directories: directory.isEmpty ? [] : [directory])
    }

    // MARK: Sign-in and registration

    public func captcha() async throws -> DravionClient.Captcha { try await client().captcha() }
    /// The platform token is used once, to register; only the device credential is kept.
    public func register(username: String, password: String, captcha: String, captchaUUID: String) async throws {
        let client = try client()
        let token = try await client.login(username: username, password: password, captcha: captcha, captchaUUID: captchaUUID)
        let device = try await client.registerDevice(token: token, name: deviceName, capabilities: capabilities())
        try secrets.write(device.credential, for: Self.credentialKey)
        deviceID = device.deviceId; save()
        note("已注册为设备 \(device.deviceId)")
    }
    public func forget() {
        stop()
        try? secrets.write(nil, for: Self.credentialKey)
        deviceID = nil; save(); note("已移除本机设备凭据；在平台吊销该设备可让它立即失效")
    }

    // MARK: Loop

    public func start() {
        enabled = true; save()
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }
    public func stop() {
        enabled = false; save()
        loop?.cancel(); loop = nil
        status = active == nil ? "已关闭" : "已关闭（当前任务做完为止）"
    }
    private func run() async {
        var lastPresence = Date.distantPast
        while !Task.isCancelled {
            do {
                guard let credential = try secrets.read(Self.credentialKey) else { status = "未注册：先登录平台注册本机"; try await Task.sleep(for: .seconds(5)); continue }
                let client = try client()
                if Date().timeIntervalSince(lastPresence) > 60 { try await client.presence(credential, capabilities: capabilities()); lastPresence = Date() }
                status = active == nil ? "在线，等待平台派活" : "执行中"
                let poll = try await client.poll(credential, waitSeconds: 25)
                if let active, poll.cancel.contains(active.leaseID) { cancelled = true; work?.cancel() }
                if active == nil, let offer = poll.offered.first(where: { offer in Self.vendors.values.contains(offer.vendor) }), let reason = blocked() {
                    status = "有任务待领取，但\(reason)"; _ = offer
                } else if active == nil, let offer = poll.offered.first(where: { offer in Self.vendors.values.contains(offer.vendor) }) {
                    let payload = try await client.claim(credential, lease: offer.leaseId)
                    start(payload, client: client, credential: credential)
                }
            } catch is CancellationError {
                return
            } catch {
                status = "连接出错，稍后重试：\(error.localizedDescription)"
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
    /// Why a lease must not be claimed now, or nil.
    func blocked() -> String? {
        guard !directory.isEmpty, FileManager.default.fileExists(atPath: directory) else { return "还没选允许平台使用的目录" }
        if store.state.runs.contains(where: { $0.status.holdsProject && RelayWorkspace.overlaps($0.root.isEmpty ? $0.project.path : $0.root, directory) }) {
            return "本机任务正占用这个项目，等它结束"
        }
        return nil
    }

    // MARK: One run

    private func start(_ lease: DravionLeasePayload, client: DravionClient, credential: String) {
        active = .init(leaseID: lease.leaseId, taskID: lease.taskId, vendor: lease.vendor, startedAt: Date())
        cancelled = false
        note("领取任务 \(lease.taskId)（\(lease.vendor)）")
        work = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.execute(lease, client: client, credential: credential)
            do { try await client.finish(credential, lease: lease.leaseId, outcome: outcome) } catch { self.note("回报结果失败：\(error.localizedDescription)") }
            self.note("任务 \(lease.taskId) 结束：\(Self.describe(outcome))")
            self.active = nil; self.work = nil
        }
    }
    static func describe(_ outcome: DravionOutcome) -> String {
        switch outcome {
        case .finished(_, let cancelled): return cancelled ? "已取消" : "完成"
        case .failed(_, let code, let message): return "失败 \(code)：\(message.prefix(120))"
        }
    }

    func execute(_ lease: DravionLeasePayload, client: DravionClient, credential: String) async -> DravionOutcome {
        let failed = { (code: String, message: String) in DravionOutcome.failed(runID: lease.runId, code: code, message: message) }
        // Pack tools need the client to be pointed at the Tool Gateway's MCP endpoint; not wired yet.
        guard lease.toolGateway == nil else { return failed("PACKS_NOT_SUPPORTED", "桌面端暂不支持带 Pack 工具的任务") }
        guard let kind = Self.vendors.first(where: { $0.value == lease.vendor })?.key,
              let connection = store.state.connections.first(where: { $0.kind == kind }) else {
            return failed("NO_LOCAL_CLIENT", "本机没有配置 \(lease.vendor) 连接")
        }
        let role = RelayRole(id: "dravion-\(lease.leaseId)", name: "Dravion 派发", stage: .executor, connectionID: connection.id, model: lease.model ?? "")
        var request = RelayAgentRequest(role: role, connection: connection, stage: .executor, directory: directory,
            artifactDirectory: store.directory.appendingPathComponent("dravion/\(lease.leaseId)"),
            prompt: "【Dravion 平台派发的任务，工作目录：\(directory)】\n" + lease.prompt,
            timeout: TimeInterval(lease.maxWallSeconds), idleTimeout: 900)
        request.writableDirectories = []

        var seq = 0
        var buffer: [DravionRunEvent] = []
        func flush() async {
            guard !buffer.isEmpty else { return }
            let batch = buffer; buffer = []
            do { try await client.send(credential, lease: lease.leaseId, runID: lease.runId, events: batch) } catch { note("事件回传失败：\(error.localizedDescription)") }
        }
        let beat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeatSeconds))
                guard let self, !Task.isCancelled else { return }
                if (try? await client.heartbeat(credential, lease: lease.leaseId)) == true { self.cancelled = true; self.work?.cancel() }
                await flush()
            }
        }
        defer { beat.cancel() }
        do {
            let result = try await executor.execute(request, emit: { kind, message in
                seq += 1
                switch kind {
                case .tool:
                    let name = (try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])?["name"] as? String
                    buffer.append(.tool(seq: seq, id: "local-\(seq)", name: name ?? "tool", failed: false))
                case .error: buffer.append(.message(seq: seq, text: "错误：" + message))
                default: buffer.append(.message(seq: seq, text: message))
                }
            }, session: { _ in })
            seq += 1
            buffer.append(.usage(seq: seq, input: result.inputTokens + result.cachedInputTokens + result.cacheWriteTokens, output: result.outputTokens))
            await flush()
            return .finished(runID: lease.runId, cancelled: false)
        } catch {
            await flush()
            if cancelled || Task.isCancelled { return .finished(runID: lease.runId, cancelled: true) }
            return failed("DESKTOP_ERROR", store.redact(error.localizedDescription))
        }
    }

    private func note(_ line: String) {
        log.append("\(Date().formatted(date: .omitted, time: .shortened)) \(line)")
        if log.count > 30 { log.removeFirst(log.count - 30) }
    }
}
