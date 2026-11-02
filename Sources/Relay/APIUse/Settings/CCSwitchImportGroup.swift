import SwiftUI

/// Choosing which CC Switch providers get a ring of their own.
///
/// Each entry CC Switch holds can become an added CC Switch account, keyed by
/// the entry's own id (`CCSwitchStore.Entry.slot`), so switching one on twice
/// cannot make two rings. Nothing is copied: the account reads its address and
/// key from CC Switch's database at every pass, so a key changed there is the
/// key used here.
///
/// Entries with no address are the tools' own logins — the Claude Code and
/// Codex rings already read those — and are listed but cannot be switched on.
struct CCSwitchImportGroup: View {
    let settings: AppSettings

    @State private var entries: [CCSwitchStore.Entry] = []
    @State private var loaded = false

    var body: some View {
        SettingsGroup(String.localized("Import from CC Switch")) {
            if !CCSwitchStore.isInstalled {
                SettingsRow(
                    String.localized("CC Switch not found"),
                    subtitle: String.localized("Pulse reads ~/.cc-switch/cc-switch.db. Install CC Switch and add a provider first.")
                ) { EmptyView() }
            } else {
                SettingsRow(
                    String.localized("Providers in CC Switch"),
                    subtitle: String.localized("Switch one on to give it a ring. Its key is read from CC Switch each time and sent only to its own address.")
                ) {
                    HStack(spacing: 8) {
                        Button(String.localized("Add all relays")) { addAll() }
                        Button(String.localized("Look again")) { reload() }
                    }
                }

                ForEach(groups, id: \.self) { app in
                    SettingsRowDivider()
                    Text(appTitle(app))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)

                    ForEach(entries.filter { $0.appType == app }) { entry in
                        SettingsRowDivider()
                        row(for: entry)
                    }
                }
            }
        }
        .onAppear { if !loaded { reload() } }
    }

    private var groups: [String] {
        var seen: Set<String> = []
        return entries.map(\.appType).filter { seen.insert($0).inserted }
    }

    private func appTitle(_ appType: String) -> String {
        entries.first { $0.appType == appType }?.appName ?? appType
    }

    @ViewBuilder
    private func row(for entry: CCSwitchStore.Entry) -> some View {
        let importable = Self.isImportable(entry)
        SettingsRow(
            entry.name.isEmpty ? (entry.host ?? entry.appName) : entry.name,
            subtitle: subtitle(for: entry)
        ) {
            Toggle("", isOn: Binding(
                get: { isAdded(entry) },
                set: { $0 ? add(entry) : remove(entry) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(!importable)
        }
    }

    private func subtitle(for entry: CCSwitchStore.Entry) -> String {
        var parts: [String] = []
        switch CCSwitchUsageService.kind(of: entry) {
        case .official: parts.append(String.localized("Official login — shown on its own ring"))
        case .deepSeek: parts.append("DeepSeek")
        case .zhipu: parts.append("Zhipu GLM")
        case .zai: parts.append("z.ai")
        case .relay: parts.append(entry.host ?? "")
        }
        if entry.key == nil, Self.isImportable(entry) == false, entry.baseURL != nil {
            parts.append(String.localized("no key"))
        }
        if entry.isCurrent { parts.append(String.localized("in use")) }
        return parts.joined(separator: " · ")
    }

    static func isImportable(_ entry: CCSwitchStore.Entry) -> Bool {
        entry.key != nil && CCSwitchUsageService.kind(of: entry) != .official
    }

    private func key(for entry: CCSwitchStore.Entry) -> AccountKey { AccountKey(.ccSwitch, slot: entry.slot) }

    private func isAdded(_ entry: CCSwitchStore.Entry) -> Bool {
        settings.extraAccounts.contains { $0.key == key(for: entry) }
    }

    static func label(for entry: CCSwitchStore.Entry) -> String {
        let name = entry.name.isEmpty ? (entry.host ?? "CC Switch") : entry.name
        return "\(name) · \(entry.appName)"
    }

    private func add(_ entry: CCSwitchStore.Entry) {
        guard !isAdded(entry), Self.isImportable(entry) else { return }
        settings.addAccount(.ccSwitch, label: Self.label(for: entry), slot: entry.slot)
    }

    private func remove(_ entry: CCSwitchStore.Entry) {
        settings.removeAccount(key(for: entry))
    }

    /// Every importable entry, one per address and key: CC Switch keeps a
    /// separate entry per tool, so the same relay key configured for Claude
    /// Code and Codex would otherwise be two rings for one balance.
    private func addAll() {
        var seen: Set<String> = Set(
            entries.filter(isAdded).map { "\($0.host ?? "")|\($0.key ?? "")" }
        )
        for entry in entries where Self.isImportable(entry) && !isAdded(entry) {
            guard seen.insert("\(entry.host ?? "")|\(entry.key ?? "")").inserted else { continue }
            add(entry)
        }
    }

    private func reload() {
        entries = CCSwitchStore.entries()
        loaded = true
    }
}
