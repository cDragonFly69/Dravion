import Foundation

/// Wire types of `packages/contracts/src/device.ts` (D5). Field names match the JSON exactly.
public struct DravionDeviceClient: Codable, Equatable, Sendable {
    public var vendor: String
    public var version: String?
    public var available: Bool
    public init(vendor: String, version: String? = nil, available: Bool = true) { self.vendor = vendor; self.version = version; self.available = available }
}
public struct DravionCapabilities: Codable, Equatable, Sendable {
    public var clients: [DravionDeviceClient]
    public var directories: [String]
    public init(clients: [DravionDeviceClient], directories: [String]) { self.clients = clients; self.directories = directories }
}
public struct DravionLeaseOffer: Codable, Equatable, Sendable { public var leaseId, taskId, vendor, offeredAt: String }
public struct DravionLeasePoll: Codable, Equatable, Sendable { public var offered: [DravionLeaseOffer]; public var cancel: [String] }
public struct DravionLeasePayload: Codable, Equatable, Sendable {
    public struct ToolGateway: Codable, Equatable, Sendable { public var url: String; public var runToken: String }
    public var leaseId, runId, taskId, workspaceId, vendor, prompt: String
    public var model: String?
    public var maxWallSeconds: Int
    public var toolGateway: ToolGateway?
}

/// One RunEvent (packages/contracts/src/run.ts); only the variants a desktop run produces.
public enum DravionRunEvent: Encodable, Sendable {
    case message(seq: Int, text: String)
    case tool(seq: Int, id: String, name: String, failed: Bool)
    case usage(seq: Int, input: Int, output: Int)
    var seq: Int { switch self { case .message(let s, _), .tool(let s, _, _, _), .usage(let s, _, _): return s } }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(DravionRunEvent.runID, forKey: .runId); try c.encode(seq, forKey: .seq)
        try c.encode(ISO8601DateFormatter().string(from: Date()), forKey: .at)
        switch self {
        case .message(_, let text): try c.encode("agent_message", forKey: .type); try c.encode(text, forKey: .text)
        case .tool(_, let id, let name, let failed):
            try c.encode("tool_call", forKey: .type); try c.encode(id, forKey: .toolCallId); try c.encode(name, forKey: .tool)
            try c.encode(failed ? "failed" : "completed", forKey: .status)
        case .usage(_, let input, let output):
            try c.encode("usage", forKey: .type); try c.encode(input, forKey: .inputTokens); try c.encode(output, forKey: .outputTokens)
        }
    }
    enum Key: String, CodingKey { case runId, seq, at, type, text, toolCallId, tool, status, inputTokens, outputTokens }
    /// Set per batch by the client: events always belong to the lease's run.
    @TaskLocal static var runID = ""
}

public enum DravionOutcome: Encodable, Sendable {
    case finished(runID: String, cancelled: Bool)
    case failed(runID: String, code: String, message: String)
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .finished(let id, let cancelled):
            try c.encode("finished", forKey: .status); try c.encode(id, forKey: .runId)
            try c.encode(cancelled ? "cancelled" : "end_turn", forKey: .stopReason); try c.encode([String](), forKey: .artifacts)
        case .failed(let id, let code, let message):
            try c.encode("failed", forKey: .status); try c.encode(id, forKey: .runId)
            try c.encode(["code": code, "message": String(message.prefix(4_000))], forKey: .error)
        }
    }
    enum Key: String, CodingKey { case status, runId, stopReason, artifacts, error }
}

public struct DravionAPIError: LocalizedError, Sendable {
    public var status: Int; public var code: String; public var message: String
    public var errorDescription: String? { "Dravion \(status) \(code)：\(message)" }
}

/// Talks to the Dravion API (devices and leases) and, for the one-time sign-in, to the admin platform.
/// Every connection is opened by this side; the server never connects to the Mac.
public struct DravionClient: Sendable {
    public var apiURL: URL
    public var adminURL: URL
    var session: URLSession = .shared
    public init(apiURL: URL, adminURL: URL) { self.apiURL = apiURL; self.adminURL = adminURL }

    // MARK: Sign-in (admin platform, same as the web console)

    public struct Captcha: Sendable { public var uuid: String; public var image: Data }
    public func captcha() async throws -> Captcha {
        let data: [String: String] = try await admin("GET", "/api/auth/captcha")
        guard let uuid = data["uuid"], let image = data["image"], let comma = image.firstIndex(of: ","),
              let png = Data(base64Encoded: String(image[image.index(after: comma)...])) else { throw DravionAPIError(status: 0, code: "CAPTCHA", message: "验证码格式不对") }
        return .init(uuid: uuid, image: png)
    }
    public func login(username: String, password: String, captcha: String, captchaUUID: String) async throws -> String {
        struct Login: Decodable { var token: String }
        let body = ["username": username, "password": password, "captcha": captcha, "captchaUuid": captchaUUID]
        let reply: Login = try await admin("POST", "/api/auth/login", body: body)
        return reply.token
    }

    // MARK: Devices

    public struct Credential: Decodable, Sendable { public var deviceId: String; public var credential: String }
    public func registerDevice(token: String, name: String, capabilities: DravionCapabilities) async throws -> Credential {
        struct Body: Encodable { var name: String; var capabilities: DravionCapabilities }
        return try await api("POST", "/v1/devices", auth: "Bearer \(token)", body: Body(name: name, capabilities: capabilities))
    }
    public func presence(_ credential: String, capabilities: DravionCapabilities) async throws {
        struct Body: Encodable { var capabilities: DravionCapabilities }
        let _: Empty = try await api("POST", "/v1/devices/me/presence", auth: "Device \(credential)", body: Body(capabilities: capabilities))
    }
    public func poll(_ credential: String, waitSeconds: Int = 25) async throws -> DravionLeasePoll {
        try await api("GET", "/v1/devices/me/leases?waitSeconds=\(waitSeconds)", auth: "Device \(credential)", timeout: TimeInterval(waitSeconds + 15))
    }
    public func claim(_ credential: String, lease: String) async throws -> DravionLeasePayload {
        try await api("POST", "/v1/devices/me/leases/\(lease)/claim", auth: "Device \(credential)", body: Empty())
    }
    public func heartbeat(_ credential: String, lease: String) async throws -> Bool {
        struct Reply: Decodable { var cancel: Bool }
        let reply: Reply = try await api("POST", "/v1/devices/me/leases/\(lease)/heartbeat", auth: "Device \(credential)", body: Empty())
        return reply.cancel
    }
    public func send(_ credential: String, lease: String, runID: String, events: [DravionRunEvent]) async throws {
        struct Body: Encodable { var events: [DravionRunEvent] }
        let data = try DravionRunEvent.$runID.withValue(runID) { try JSONEncoder().encode(Body(events: events)) }
        let _: Empty = try await raw("POST", apiURL, "/v1/devices/me/leases/\(lease)/events", auth: "Device \(credential)", body: data)
    }
    public func finish(_ credential: String, lease: String, outcome: DravionOutcome) async throws {
        struct Body: Encodable { var outcome: DravionOutcome }
        let _: Empty = try await api("POST", "/v1/devices/me/leases/\(lease)/outcome", auth: "Device \(credential)", body: Body(outcome: outcome))
    }

    // MARK: Transport

    struct Empty: Codable {}
    struct AdminWrapped<T: Decodable>: Decodable { var code: Int; var message: String?; var data: T? }
    struct APIFailure: Decodable { struct Inner: Decodable { var code: String; var message: String }; var error: Inner }
    private func api<T: Decodable>(_ method: String, _ path: String, auth: String, body: (any Encodable)? = nil, timeout: TimeInterval = 30) async throws -> T {
        try await raw(method, apiURL, path, auth: auth, body: try body.map { try JSONEncoder().encode($0) }, timeout: timeout)
    }
    /// The admin platform wraps replies as `{code, message, data}`; code 200 is success.
    private func admin<T: Decodable>(_ method: String, _ path: String, body: [String: String]? = nil) async throws -> T {
        let wrapped: AdminWrapped<T> = try await raw(method, adminURL, path, auth: nil, body: try body.map { try JSONEncoder().encode($0) })
        guard wrapped.code == 200, let data = wrapped.data else { throw DravionAPIError(status: wrapped.code, code: "ADMIN", message: wrapped.message ?? "登录失败") }
        return data
    }
    private func raw<T: Decodable>(_ method: String, _ base: URL, _ path: String, auth: String?, body: Data?, timeout: TimeInterval = 30) async throws -> T {
        guard let url = URL(string: path, relativeTo: base) else { throw DravionAPIError(status: 0, code: "URL", message: path) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let auth { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let failure = try? JSONDecoder().decode(APIFailure.self, from: data)
            throw DravionAPIError(status: status, code: failure?.error.code ?? "HTTP", message: failure?.error.message ?? String(decoding: data.prefix(300), as: UTF8.self))
        }
        if T.self == Empty.self || data.isEmpty { return try JSONDecoder().decode(T.self, from: Data("{}".utf8)) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
