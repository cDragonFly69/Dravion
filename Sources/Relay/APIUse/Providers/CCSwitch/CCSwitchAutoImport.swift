import Foundation

/// The first time CC Switch is switched on, give it the rings someone most
/// likely wants without making them find the import list first: the relay
/// each tool is using right now, and every DeepSeek and GLM key, one ring per
/// address and key. Runs once; after that the import list in Settings is the
/// only thing that adds or removes CC Switch accounts.
@MainActor
enum CCSwitchAutoImport {
    static let doneKey = "ccSwitch.autoImported"

    static func runIfNeeded(_ settings: AppSettings, defaults: UserDefaults = .standard) {
        guard
            !defaults.bool(forKey: doneKey),
            settings.isEnabled(AccountKey(.ccSwitch)),
            CCSwitchStore.isInstalled
        else { return }
        defaults.set(true, forKey: doneKey)

        let entries = CCSwitchStore.entries()
        let primary = CCSwitchStore.current(in: entries)
        var seen: Set<String> = primary.map { [identity($0)] } ?? []
        for entry in entries where CCSwitchImportGroup.isImportable(entry) {
            let wanted: Bool = switch CCSwitchUsageService.kind(of: entry) {
            case .deepSeek, .zhipu, .zai: true
            case .relay: entry.isCurrent
            case .official: false
            }
            guard wanted, seen.insert(identity(entry)).inserted else { continue }
            guard !settings.extraAccounts.contains(where: { $0.key == AccountKey(.ccSwitch, slot: entry.slot) }) else { continue }
            settings.addAccount(.ccSwitch, label: CCSwitchImportGroup.label(for: entry), slot: entry.slot)
        }
    }

    static func identity(_ entry: CCSwitchStore.Entry) -> String { "\(entry.host ?? "")|\(entry.key ?? "")" }
}
