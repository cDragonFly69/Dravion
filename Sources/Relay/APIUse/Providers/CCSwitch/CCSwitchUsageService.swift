import Foundation

/// The balance behind one CC Switch entry, asked of whatever service the entry
/// points at.
///
/// CC Switch stores an address and a key and nothing about what kind of
/// service answers there, so the kind is worked out from the address:
///
/// | Address | Asked as |
/// |---|---|
/// | `*.deepseek.com` | DeepSeek's documented `GET /user/balance` (`DeepSeekUsageService`) |
/// | `open.bigmodel.cn` / `api.z.ai` | the GLM Coding Plan monitor (`ZaiUsageService`) |
/// | none, or CC Switch's `official` category | nothing: the tool's own login, which the Claude Code or Codex ring already reads |
/// | anything else | a relay: New API's billing routes first, then sub2api's |
///
/// **A relay is tried as New API, then as sub2api**, and the first that
/// answers with figures wins. Both are asked with the entry's own key against
/// the entry's own host and nowhere else.
struct CCSwitchUsageService: Sendable {
    let account: AccountKey
    let entry: CCSwitchStore.Entry?
    let deepSeekBasis: BalanceBasis
    let deepSeekBudget: Double?
    let deepSeekCurrency: String?

    enum Kind: Equatable {
        case official
        case deepSeek
        case zhipu
        case zai
        case relay(root: String)
    }

    static func kind(of entry: CCSwitchStore.Entry) -> Kind {
        guard let base = entry.baseURL, let url = URL(string: base), let host = url.host?.lowercased() else {
            return .official
        }
        if host.hasSuffix("deepseek.com") { return .deepSeek }
        if host.hasSuffix("bigmodel.cn") { return .zhipu }
        if host == "api.z.ai" || host.hasSuffix(".z.ai") { return .zai }
        if host.hasSuffix("anthropic.com") || host.hasSuffix("openai.com") || host == "chatgpt.com" {
            return .official
        }
        // Relays are run at the root of their host: the path in the client's
        // config (`/v1`, `/anthropic`, `/codex`) is the protocol's, not the
        // deployment's.
        var components = URLComponents()
        components.scheme = url.scheme ?? "https"
        components.host = url.host
        components.port = url.port
        return .relay(root: components.string ?? base)
    }

    func fetch() async -> ProviderUsage {
        guard let entry else { return .unavailable(account, reason: .localAppMissing) }

        // **CC Switch's own usage query first**, where the entry has one: it
        // is what CC Switch shows for this provider, so the ring and CC Switch
        // agree, and it can reach an account balance a key route cannot (an
        // unlimited relay token, New API's access-token route).
        if let configured = CCSwitchBalances.configured().first(where: { $0.entry.slot == entry.slot }),
           let reading = Self.reading(await CCSwitchBalances.query(.init(configured: configured, members: [entry])),
                                      for: account) {
            return reading
        }

        switch Self.kind(of: entry) {
        case .official:
            return .unavailable(account, reason: .noLimitsReported)
        case .deepSeek:
            let service = DeepSeekUsageService(
                enteredKey: entry.key,
                basis: deepSeekBasis,
                budget: deepSeekBudget,
                currency: deepSeekCurrency
            )
            return await service.fetch().reassigned(to: account)
        case .zhipu:
            return await ZaiUsageService(provider: .glmCoding, enteredKey: entry.key).fetch().reassigned(to: account)
        case .zai:
            return await ZaiUsageService(provider: .zai, enteredKey: entry.key).fetch().reassigned(to: account)
        case .relay(let root):
            let newAPI = await NewAPIUsageService(enteredKey: entry.key, address: root).fetch()
            if newAPI.hasFigures { return newAPI.reassigned(to: account) }
            let sub2api = await Sub2APIUsageService(enteredKey: entry.key, address: root).fetch()
            if sub2api.hasFigures { return sub2api.reassigned(to: account) }
            // Neither answered with figures: report New API's reason, which is
            // the more common gateway and the more specific refusal.
            return newAPI.reassigned(to: account)
        }
    }
}

extension CCSwitchUsageService {
    /// A usage query's answer as a reading, or nil when it failed, so the
    /// address-based route below still gets its turn.
    static func reading(_ outcome: CCSwitchBalances.Outcome, for account: AccountKey, now: Date = Date()) -> ProviderUsage? {
        func wallet(_ row: CCSwitchUsageScript.UsageData) -> ProviderUsage.CreditAmount? {
            guard let remaining = row.remaining, remaining.isFinite else { return nil }
            return .init(amount: remaining, currency: Self.currency(row.unit))
        }
        func text(_ amount: ProviderUsage.CreditAmount?) -> String? {
            guard let amount else { return nil }
            let format = FloatingPointFormatStyle<Double>.Currency(code: amount.currency).precision(.fractionLength(2))
            return amount.amount.formatted(format)
        }
        switch outcome {
        case .failed:
            return nil
        case .plan(let name, let windows, let money):
            let amount = money.flatMap(wallet)
            return ProviderUsage(account: account, windows: windows, observedAt: now, state: .live, plan: name,
                                 creditBalance: text(amount), creditRemaining: amount)
        case .money(let rows):
            guard let row = rows.first(where: { $0.remaining != nil }) else { return nil }
            if row.isValid == false {
                return .unavailable(account, reason: .apiKeyRefused)
            }
            let amount = wallet(row)
            // A query that states both used and total is a provider's own
            // fraction, so it may draw a ring; money alone is a balance.
            var windows: [UsageWindow] = []
            if let used = row.used, let total = row.total, total > 0 {
                windows = [UsageWindow(id: "ccswitch-quota", kind: .balance, scope: nil,
                                       usedFraction: min(max(used / total, 0), 1), windowSeconds: 30 * 86_400,
                                       resetsAt: nil, reportsLength: false)]
            }
            let plan = row.planName.flatMap { $0.uppercased() == (row.unit ?? "").uppercased() ? nil : $0 }
            return ProviderUsage(account: account, windows: windows, observedAt: now, state: .live, plan: plan,
                                 creditBalance: text(amount), creditRemaining: amount)
        }
    }

    /// CC Switch's units as ISO codes: scripts write "USD", "CNY", "RMB" or "¥".
    static func currency(_ unit: String?) -> String {
        switch (unit ?? "USD").uppercased() {
        case "CNY", "RMB", "¥", "元": "CNY"
        case "USD", "$", "": "USD"
        default: (unit ?? "USD").uppercased()
        }
    }
}

extension ProviderUsage {
    /// Whether this reading carries anything to draw.
    var hasFigures: Bool {
        if case .unavailable = state { return false }
        return !windows.isEmpty || creditRemaining != nil || creditBalance != nil
    }

    /// The same reading, filed under another account. For a service that
    /// answers on behalf of an account it does not own, as CC Switch's do.
    func reassigned(to account: AccountKey) -> ProviderUsage {
        var copy = self
        copy.account = account
        return copy
    }
}
