import Foundation
import JavaScriptCore

/// A CC Switch usage query ("配置用量查询"), run the way CC Switch runs it.
///
/// CC Switch lets each provider carry a short script that names one request
/// and a function that reads the reply:
///
/// ```js
/// ({ request: { url: "{{baseUrl}}/user/balance", method: "GET", headers: {…} },
///    extractor: function (response) { return { remaining: response.balance, unit: "USD" } } })
/// ```
///
/// Ported from `src-tauri/src/usage_script.rs`, with its safeguards:
///
/// - `{{apiKey}}`, `{{baseUrl}}`, `{{accessToken}}` and `{{userId}}` are
///   substituted before the script runs.
/// - **The script never touches the network.** JavaScriptCore has no `fetch`;
///   the script only *describes* the request, and Pulse sends it.
/// - The request must be HTTPS (loopback excepted) and go to the provider's
///   own host and port — unless the template is `custom`, where CC Switch lets
///   the user point anywhere.
/// - Script time is capped (5 s) and the HTTP timeout clamped to 2–30 s.
enum CCSwitchUsageScript {
    /// One row of a result, as CC Switch's `UsageData`. Every field optional.
    struct UsageData: Sendable, Codable, Equatable {
        var planName: String?
        var remaining: Double?
        var total: Double?
        var used: Double?
        var unit: String?
        var isValid: Bool?
        var invalidMessage: String?
        var extra: String?
    }

    struct Failure: Error, Equatable {
        let message: String
    }

    struct Request: Sendable, Equatable {
        var url: String
        var method: String
        var headers: [String: String]
        var body: String?
    }

    static let scriptSeconds: Double = 5

    static func substituted(_ code: String, apiKey: String, baseURL: String,
                            accessToken: String?, userID: String?) -> String {
        var out = code.replacingOccurrences(of: "{{apiKey}}", with: apiKey)
            .replacingOccurrences(of: "{{baseUrl}}", with: baseURL)
        if let accessToken { out = out.replacingOccurrences(of: "{{accessToken}}", with: accessToken) }
        if let userID { out = out.replacingOccurrences(of: "{{userId}}", with: userID) }
        return out
    }

    static func run(code: String, apiKey: String, baseURL: String, timeout: Int,
                    accessToken: String?, userID: String?, templateType: String?,
                    session: URLSession = .shared) async -> Result<[UsageData], Failure> {
        let isCustom = templateType == "custom"
        let script = substituted(code, apiKey: apiKey, baseURL: baseURL, accessToken: accessToken, userID: userID)
        if !baseURL.isEmpty, !isCustom, let failure = validateBase(baseURL) { return .failure(failure) }

        let request: Request
        switch requestConfig(script) {
        case .success(let value): request = value
        case .failure(let failure): return .failure(failure)
        }
        if let failure = validateRequest(request.url, baseURL: baseURL, isCustom: isCustom) { return .failure(failure) }

        let body: String
        switch await send(request, timeout: timeout, session: session) {
        case .success(let text): body = text
        case .failure(let failure): return .failure(failure)
        }
        return extract(script, response: body)
    }

    // MARK: - The script

    private static func context() -> JSContext? {
        guard let context = JSContext() else { return nil }
        limitTime(of: context)
        return context
    }

    /// `JSContextGroupSetExecutionTimeLimit` is exported by JavaScriptCore but
    /// not in its public headers, so it is looked up at run time; without it
    /// the script simply runs unbounded, as it would in a browser tab.
    private static func limitTime(of context: JSContext) {
        typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, OpaquePointer?, UnsafeMutableRawPointer?) -> Void
        guard
            let handle = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_NOW),
            let symbol = dlsym(handle, "JSContextGroupSetExecutionTimeLimit")
        else { return }
        let setLimit = unsafeBitCast(symbol, to: SetLimit.self)
        setLimit(JSContextGetGroup(context.jsGlobalContextRef), scriptSeconds, nil, nil)
    }

    private static func evaluate(_ script: String, in context: JSContext) -> Result<JSValue, Failure> {
        var thrown: String?
        context.exceptionHandler = { _, exception in thrown = exception?.toString() }
        // Parenthesised so a bare object literal is an expression, as QuickJS
        // reads CC Switch's templates.
        let value = context.evaluateScript(script)
        if let thrown { return .failure(Failure(message: thrown)) }
        guard let value, value.isObject else { return .failure(Failure(message: "The usage script did not return an object.")) }
        return .success(value)
    }

    static func requestConfig(_ script: String) -> Result<Request, Failure> {
        guard let context = context() else { return .failure(Failure(message: "JavaScript is unavailable.")) }
        let config: JSValue
        switch evaluate(script, in: context) {
        case .success(let value): config = value
        case .failure(let failure): return .failure(failure)
        }
        guard let request = config.forProperty("request"), request.isObject,
              let url = request.forProperty("url")?.toString(), !url.isEmpty, url != "undefined"
        else { return .failure(Failure(message: "The usage script has no request.")) }
        let method = request.forProperty("method").flatMap { $0.isUndefined ? nil : $0.toString() } ?? "GET"
        var headers: [String: String] = [:]
        if let dict = request.forProperty("headers")?.toDictionary() {
            for (key, value) in dict { headers["\(key)"] = "\(value)" }
        }
        let bodyValue = request.forProperty("body")
        let body = (bodyValue == nil || bodyValue!.isUndefined || bodyValue!.isNull) ? nil : bodyValue!.toString()
        return .success(Request(url: url, method: method.uppercased(), headers: headers, body: body))
    }

    static func extract(_ script: String, response: String) -> Result<[UsageData], Failure> {
        guard let context = context() else { return .failure(Failure(message: "JavaScript is unavailable.")) }
        let config: JSValue
        switch evaluate(script, in: context) {
        case .success(let value): config = value
        case .failure(let failure): return .failure(failure)
        }
        guard let extractor = config.forProperty("extractor"), !extractor.isUndefined else {
            return .failure(Failure(message: "The usage script has no extractor."))
        }
        var thrown: String?
        context.exceptionHandler = { _, exception in thrown = exception?.toString() }
        guard let json = context.objectForKeyedSubscript("JSON"),
              let parsed = json.invokeMethod("parse", withArguments: [response]), thrown == nil
        else { return .failure(Failure(message: "The reply is not JSON.")) }
        let result = extractor.call(withArguments: [parsed])
        if let thrown { return .failure(Failure(message: thrown)) }
        guard let result,
              let text = json.invokeMethod("stringify", withArguments: [result])?.toString(),
              let data = text.data(using: .utf8)
        else { return .failure(Failure(message: "The extractor returned nothing.")) }
        return decode(data)
    }

    /// One object or an array of them, every field type-checked as CC Switch
    /// does; a wrongly typed field fails the whole result.
    static func decode(_ data: Data) -> Result<[UsageData], Failure> {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([UsageData].self, from: data) {
            return list.isEmpty ? .failure(Failure(message: "The usage script returned an empty list.")) : .success(list)
        }
        if let one = try? decoder.decode(UsageData.self, from: data) { return .success([one]) }
        return .failure(Failure(message: "The usage script returned an unexpected shape."))
    }

    // MARK: - Where the request may go

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        // An IPv4 literal in 127/8 only: `127.0.0.1.evil.com` is a domain.
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy { UInt8($0) != nil }
    }

    private static func port(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil)
    }

    static func validateBase(_ base: String) -> Failure? {
        guard let url = URL(string: base), let host = url.host, !host.isEmpty else {
            return Failure(message: "The provider address is not valid.")
        }
        if url.scheme?.lowercased() != "https", !isLoopback(url) {
            return Failure(message: "The provider address must use HTTPS.")
        }
        return nil
    }

    static func validateRequest(_ request: String, baseURL: String, isCustom: Bool) -> Failure? {
        guard let url = URL(string: request), url.host != nil else {
            return Failure(message: "The usage request address is not valid.")
        }
        if !isCustom, url.scheme?.lowercased() != "https", !isLoopback(url) {
            return Failure(message: "The usage request must use HTTPS.")
        }
        guard !baseURL.isEmpty, !isCustom else { return nil }
        guard let base = URL(string: baseURL) else { return Failure(message: "The provider address is not valid.") }
        if url.host?.lowercased() != base.host?.lowercased() || port(url) != port(base) {
            return Failure(message: "The usage request must go to the provider's own address.")
        }
        return nil
    }

    // MARK: - The request

    private static func send(_ request: Request, timeout: Int, session: URLSession) async -> Result<String, Failure> {
        guard let url = URL(string: request.url) else { return .failure(Failure(message: "The usage request address is not valid.")) }
        var urlRequest = URLRequest(url: url, timeoutInterval: TimeInterval(min(max(timeout, 2), 30)))
        urlRequest.httpMethod = request.method
        for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        if let body = request.body { urlRequest.httpBody = Data(body.utf8) }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            let text = String(decoding: data, as: UTF8.self)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(Failure(message: "HTTP \(http.statusCode)"))
            }
            return .success(text)
        } catch {
            return .failure(Failure(message: error.localizedDescription))
        }
    }
}
