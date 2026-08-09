import Foundation
import CyclerCore
import HyperkeyCore
import ZonesCore

/// One-time, idempotent seeding of `config.json` from the two legacy files.
///
/// Hard rule: **read-only on both sources.** `~/.config/lineup/zones.json` and
/// `~/.config/cycler/bindings.json` are never written, renamed, backed up, or deleted.
/// `zones.json` in particular is the rollback safety net — a user who downgrades to Lineup 1.x
/// must find a valid schema-3 file exactly where they left it.
///
/// Field mapping:
///
/// | Legacy | New |
/// |---|---|
/// | `zones.json` (whole file) | `tools.zones.settings`, `tools.zones.enabled = true` |
/// | `bindings.json → bindings` | `tools.cycler.settings.bindings` (coalesced first) |
/// | `bindings.json → hyperKey` | `tools.hyperkey.settings` + `tools.hyperkey.enabled` |
/// | `bindings.json → showMenuBarIcon` | `general.showMenuBarIcon`, **only for a Cycler-only migrant** |
///
/// That last row is a deliberate departure from a straight copy: in standalone Cycler the flag hid
/// *Cycler's own* second menu-bar icon, whereas in 2.0 there is one icon for the whole suite. See
/// `importCycler`.
public enum LegacyImport {
    public struct Report: Equatable {
        public var importedZones = false
        /// The legacy layout belongs to a display that isn't connected. Nothing was written and
        /// `didImportLegacyZones` stays false, so the import retries when it reconnects.
        public var zonesDeferred = false
        public var importedCycler = false
        public var importedBindingCount = 0
        public var importedHyperkey = false
        public var hyperkeyWasEnabled = false
        public var zonesError: String?
        public var cyclerError: String?

        public init() {}

        public var didAnything: Bool { importedZones || importedCycler }
    }

    /// Idempotent, per-source: the two `didImport*` flags are independent, so a failed Cycler
    /// import never blocks the Zones import or vice versa.
    ///
    /// - Parameters:
    ///   - hasLineupHistory: this machine also has Lineup 1.x traces (`zones.json`, or the
    ///     `lineup.didOnboard` default). It decides ONE thing: whether standalone Cycler's
    ///     `showMenuBarIcon` is adopted — see `importCycler`.
    ///   - resolveLegacyScreen: maps a pre-schema-3 `ColumnConfig` onto the display its
    ///     seams were drawn on, or `nil` to DEFER. Same closure `LineupConfig.loadOrMigrate` takes.
    @discardableResult
    public static func run(into config: inout LineupAppConfig,
                           zonesURL: URL,
                           cyclerBindingsURL: URL,
                           now: String,
                           hasLineupHistory: Bool = false,
                           resolveLegacyScreen: (ColumnConfig) -> ScreenInfo?) -> Report {
        var report = Report()
        importZones(into: &config, url: zonesURL, now: now,
                    resolveLegacyScreen: resolveLegacyScreen, report: &report)
        importCycler(into: &config, url: cyclerBindingsURL,
                     hasLineupHistory: hasLineupHistory, report: &report)
        return report
    }

    // MARK: - Zones

    private static func importZones(into config: inout LineupAppConfig,
                                    url: URL,
                                    now: String,
                                    resolveLegacyScreen: (ColumnConfig) -> ScreenInfo?,
                                    report: inout Report) {
        guard !config.general.didImportLegacyZones else { return }
        do {
            let outcome = try LineupConfig.loadOrMigrate(
                from: url, now: now,
                // No backup is needed (or allowed): we never replace the legacy file, so the
                // original bytes are their own backup.
                backup: { _ in },
                resolveLegacyTarget: resolveLegacyScreen)
            switch outcome {
            case .loaded(let cfg), .migrated(let cfg):
                try config.setSettings(cfg, for: .zones)
                // Zones is Lineup's incumbent behaviour — always on after an import.
                config.setEnabled(true, for: .zones)
                config.general.didImportLegacyZones = true
                report.importedZones = true
            case .fresh:
                // No zones.json at all. Nothing to import; seed the incumbent default so a
                // brand-new user still gets Zones running, and don't look again.
                if config.section(for: .zones) == nil {
                    try config.setSettings(LineupConfig(), for: .zones)
                    config.setEnabled(true, for: .zones)
                }
                config.general.didImportLegacyZones = true
            case .deferred:
                // The saved layout belongs to a display that isn't connected. Write NOTHING and
                // leave the flag false so this retries once the display is back.
                report.zonesDeferred = true
            }
        } catch {
            // Corrupt or newer-than-we-understand zones.json. Surface it and leave both the
            // legacy file and the zones section untouched; the tool falls back to defaults.
            report.zonesError = "\(error)"
        }
    }

    // MARK: - Cycler + Hyperkey (the split)

    private static func importCycler(into config: inout LineupAppConfig,
                                     url: URL,
                                     hasLineupHistory: Bool,
                                     report: inout Report) {
        guard !config.general.didImportLegacyCycler else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Never had standalone Cycler. Nothing to do, and nothing to retry.
            config.general.didImportLegacyCycler = true
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let legacy = try CyclerConfig.decode(data).coalescingDuplicateShortcuts()

            // The split: bindings go to Cycler, hyper-key state goes to Hyperkey, and the
            // menu-bar preference is now app-wide. The cycler section must NOT contain a
            // `hyperKey` key — CyclerToolSettings has no such field by design.
            try config.setSettings(CyclerToolSettings(bindings: legacy.bindings), for: .cycler)
            config.setEnabled(!legacy.bindings.isEmpty, for: .cycler)

            try config.setSettings(legacy.hyperKey, for: .hyperkey)
            config.setEnabled(legacy.hyperKey.enabled, for: .hyperkey)

            // `showMenuBarIcon` is the one field where the naive migration is WRONG for the
            // commonest case. In standalone Cycler it hid Cycler's OWN extra menu-bar icon, next
            // to Lineup's. In 2.0 there is a single icon for the whole suite, so adopting a
            // Cycler `false` on a machine that also ran Lineup 1.x would silently remove the only
            // way into the app — for a user who never asked for that, mid-auto-update.
            //
            // So it is adopted only from a Cycler-ONLY migrant, who demonstrably chose to live
            // without a menu-bar icon and has no Lineup icon to lose.
            if !hasLineupHistory {
                config.general.showMenuBarIcon = legacy.showMenuBarIcon
            }
            config.general.didImportLegacyCycler = true

            report.importedCycler = true
            report.importedBindingCount = legacy.bindings.count
            report.importedHyperkey = true
            report.hyperkeyWasEnabled = legacy.hyperKey.enabled
        } catch {
            // Leave the flag false: a corrupt bindings.json the user later fixes still imports.
            report.cyclerError = "\(error)"
        }
    }
}
