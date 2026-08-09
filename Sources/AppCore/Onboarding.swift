import Foundation

/// Which of the Phase-8 audiences a launch belongs to.
///
/// The three audiences in the plan are deliberately NOT collapsed into one "first run" flag.
/// 2.0 reaches most people as a silent Sparkle update, so the majority case is an existing 1.x
/// user who must see no permission prompt and no welcome — only a one-time note that their
/// window snapping is now a tool called Zones.
public enum LaunchAudience: String, Equatable, Sendable {
    /// Never ran any Lineup: no `config.json`, no `zones.json`, no `lineup.didOnboard`.
    case brandNew
    /// Had Lineup 1.x and is seeing 2.0 for the first time. Their Accessibility grant, login item
    /// and shortcuts all persist — nothing may be re-requested.
    case upgradingFrom1x
    /// Already ran 2.0: `config.json` is on disk.
    case returning
}

/// Pure launch-time decisions for the onboarding / upgrade windows.
///
/// This lives in `AppCore` rather than in `AppShell` so the gating can be tested directly: the
/// cost of getting it wrong is either re-onboarding every existing user or prompting them for a
/// permission they never asked for.
public enum Onboarding {
    /// - Parameters:
    ///   - hasConfig: `config.json` was present at launch (the store loaded it, or rejected it —
    ///     a rejected file still means this is not a first run).
    ///   - hasLegacyZones: `~/.config/lineup/zones.json` exists.
    ///   - didOnboard: the `lineup.didOnboard` default, unchanged from 1.x.
    public static func audience(hasConfig: Bool, hasLegacyZones: Bool, didOnboard: Bool) -> LaunchAudience {
        if hasConfig { return .returning }
        if hasLegacyZones || didOnboard { return .upgradingFrom1x }
        return .brandNew
    }

    /// The Welcome window is for brand-new users only, and only until they have been onboarded.
    /// It is the ONLY place Lineup proactively asks for Accessibility.
    public static func shouldShowWelcome(audience: LaunchAudience, didOnboard: Bool) -> Bool {
        audience == .brandNew && !didOnboard
    }

    /// The 2.0 intro window. Shown once to anyone who already had Lineup, and never to a
    /// brand-new user — the Welcome window already introduces the three tools, and two windows
    /// on a first run is a worse first run.
    public static func shouldShowWhatsNew(audience: LaunchAudience,
                                          didShowWhatsNew2: Bool,
                                          showingWelcome: Bool) -> Bool {
        guard !didShowWhatsNew2, !showingWelcome else { return false }
        return audience != .brandNew
    }

    /// One line confirming what came across from standalone Cycler, or `nil` when there was
    /// nothing to import. Never claims an import that did not happen: a `bindings.json` holding
    /// zero bindings and a disabled hyper key produces no line at all.
    public static func cyclerImportSummary(_ report: LegacyImport.Report) -> String? {
        guard report.importedCycler else { return nil }
        let count = report.importedBindingCount
        let hyper = report.hyperkeyWasEnabled
        switch (count, hyper) {
        case (0, false):
            return nil
        case (0, true):
            return "Imported your Hyper Key setup from Cycler."
        case (let n, false):
            return "Imported \(n) Cycler shortcut\(n == 1 ? "" : "s")."
        case (let n, true):
            return "Imported \(n) Cycler shortcut\(n == 1 ? "" : "s") and your Hyper Key setup."
        }
    }

    /// The uninstall banner's body. Standalone Cycler registers the same Carbon combos and can
    /// hold its own Caps Lock remap, so leaving it installed is not merely redundant — whichever
    /// process registered first wins, and it is usually the login item that has been there longer.
    public static let cyclerUninstallBanner =
        "Quit and remove Cycler.app — Lineup now does this. Its shortcuts will otherwise win the race."

    /// Shown while standalone Cycler is actually RUNNING, where the conflict is live rather than
    /// merely possible.
    public static let cyclerRunningWarning = "⚠︎ Cycler.app is still running"
}
