import CoreGraphics
import Foundation
import ZonesCore

func runAppPlacementTests() throws {
    let screen = ScreenInfo(key: "external-uuid", label: "External", pixelsWide: 2000,
                            pixelsHigh: 1000, keyIsStable: true)
    let frame = CGRect(x: 1000, y: -200, width: 1000, height: 800)
    let visible = CGRect(x: 1000, y: -180, width: 1000, height: 760)
    let left = CGRect(x: 1000, y: -180, width: 500, height: 760)
    let right = CGRect(x: 1500, y: -180, width: 500, height: 760)
    var config = LineupConfig().setting(layout: .halves, for: screen, now: nil)
    let first = AppZonePlacement(screenKey: screen.key, layout: .halves, target: left,
                                 frame: frame, visibleFrame: visible, pixelsWide: 2000)
    let second = AppZonePlacement(screenKey: screen.key, layout: .halves, target: right,
                                  frame: frame, visibleFrame: visible, pixelsWide: 2000)
    config.rememberPlacement(first, for: "app.one", succeeded: true)
    config.rememberPlacement(second, for: "app.two", succeeded: true)
    check(config.appPlacements?["app.one"] == first, "placement: explicit placement learns the application's destination")
    config.rememberPlacement(second, for: "app.one", succeeded: false)
    check(config.appPlacements?["app.one"] == first, "placement: failed movement keeps the previous destination")
    config.rememberPlacement(second, for: "app.one", succeeded: true)
    check(config.appPlacements?["app.one"] == second && config.appPlacements?.count == 2,
          "placement: replacement keeps one destination per app and preserves other apps")

    func resolve(_ placement: AppZonePlacement, _ cfg: LineupConfig, key: String = "external-uuid") -> CGRect? {
        placement.rect(in: cfg, connectedKey: key, frame: frame, visibleFrame: visible, pixelsWide: 2000)
    }
    check(resolve(second, config) == right, "placement: restores the saved leaf on an offset display")
    check(resolve(second, config, key: "lookalike-uuid") == nil,
          "placement: a disconnected display never falls back to a lookalike or main display")
    check(config.appPlacements?["app.one"] == second && resolve(second, config) == right,
          "placement: disconnect preserves the association for a later launch after reconnect")
    var renumbered = config
    renumbered.screens[screen.key]?.shortcutOrder = 8
    let other = ScreenInfo(key: "other", label: "Other", pixelsWide: 2000, pixelsHigh: 1000, keyIsStable: true)
    renumbered = renumbered.setting(layout: .thirds, for: other, now: nil)
    renumbered.screens[other.key]?.shortcutOrder = 1
    check(resolve(second, renumbered) == right, "placement: display order and other displays' zone counts cannot retarget an app")
    var changed = config.setting(layout: .thirds, for: screen, now: nil)
    check(resolve(second, changed) == nil, "placement: a reused zone index in an edited layout is not the saved zone")
    changed.preservePlacements(from: config)
    changed = changed.setting(layout: .halves, for: screen, now: nil)
    check(changed.appPlacements?["app.one"] == nil,
          "placement: recreating a deleted layout does not revive its invalidated association")
    var staleEditor = LineupConfig().setting(layout: .halves, for: screen, now: nil)
    staleEditor.preservePlacements(from: config)
    check(staleEditor.appPlacements == config.appPlacements,
          "placement: saving an open editor preserves newer learned destinations")
    let quarter = CGRect(x: 1750, y: 200, width: 250, height: 380)
    let edge = AppZonePlacement(screenKey: screen.key, layout: .halves, target: quarter,
                                frame: frame, visibleFrame: visible, pixelsWide: 2000)
    check(resolve(edge, config) == quarter, "placement: drag edge and corner targets retain the fraction within their zone")
    let full = CGRect(x: 1000, y: -180, width: 1000, height: 760)
    let quick = AppZonePlacement(screenKey: screen.key, layout: .halves, target: full,
                                 frame: frame, visibleFrame: visible, pixelsWide: 2000)
    check(resolve(quick, config) == full, "placement: quick actions spanning multiple zones retain their target")
    let resized = second.rect(in: config, connectedKey: screen.key,
                              frame: CGRect(x: -800, y: 900, width: 1600, height: 900),
                              visibleFrame: CGRect(x: -800, y: 920, width: 1600, height: 850), pixelsWide: 3200)
    check(resized == CGRect(x: 0, y: 920, width: 800, height: 850),
          "placement: resolves against current display geometry rather than old absolute coordinates")

    var sessions = ZoneLaunchRestoration(runningProcesses: [10])
    check(!sessions.launched(process: 10, placement: first, accessibilityTrusted: true),
          "launch: enabling Zones does not rearrange already-running applications")
    check(!sessions.launched(process: 11, placement: nil, accessibilityTrusted: true),
          "launch: applications without an association keep their current behavior")
    check(!sessions.launched(process: 12, placement: first, accessibilityTrusted: false),
          "launch: missing Accessibility prevents restoration")
    check(!sessions.launched(process: 12, placement: first, accessibilityTrusted: true),
          "launch: granting permission later does not reattempt that launch")
    check(sessions.launched(process: 13, placement: first, accessibilityTrusted: true),
          "launch: a new associated app waits for its first regular window")
    check(sessions.firstWindow(process: 13, isRegular: false, accessibilityTrusted: true) == nil
            && sessions.isPending(13), "launch: splash screens and sheets do not consume restoration")
    check(sessions.firstWindow(process: 13, isRegular: true, accessibilityTrusted: true) == first,
          "launch: first regular window consumes the saved destination")
    check(sessions.firstWindow(process: 13, isRegular: true, accessibilityTrusted: true) == nil
            && !sessions.launched(process: 13, placement: second, accessibilityTrusted: true),
          "launch: later windows and duplicate launch events cannot restore again, even after a failed move")
    check(!sessions.isPending(13),
          "launch: no pending restoration remains to enforce placement after free movement")
    _ = sessions.launched(process: 17, placement: first, accessibilityTrusted: true)
    let unavailable = sessions.firstWindow(process: 17, isRegular: true, accessibilityTrusted: true)
    check(unavailable.flatMap { resolve($0, config, key: "other-display") } == nil
            && sessions.firstWindow(process: 17, isRegular: true, accessibilityTrusted: true) == nil,
          "launch: an unavailable destination consumes the attempt and leaves later windows alone")
    sessions.terminated(13)
    check(sessions.launched(process: 13, placement: second, accessibilityTrusted: true)
            && sessions.firstWindow(process: 13, isRegular: true, accessibilityTrusted: true) == second,
          "launch: quit and relaunch uses the latest explicit destination, including PID reuse")
    _ = sessions.launched(process: 14, placement: first, accessibilityTrusted: true)
    sessions.cancel(14)
    check(sessions.firstWindow(process: 14, isRegular: true, accessibilityTrusted: true) == nil,
          "launch: explicit user placement cancels a pending automatic placement")
    _ = sessions.launched(process: 15, placement: first, accessibilityTrusted: true)
    check(sessions.firstWindow(process: 15, isRegular: false, accessibilityTrusted: false) == nil
            && !sessions.isPending(15), "launch: revoked Accessibility cancels even while waiting on a splash screen")
    _ = sessions.launched(process: 16, placement: first, accessibilityTrusted: true)
    sessions = ZoneLaunchRestoration(runningProcesses: [16])
    check(sessions.firstWindow(process: 16, isRegular: true, accessibilityTrusted: true) == nil,
          "launch: stop and re-enable drops pending work instead of replaying it")

    let old = Data(#"{"schemaVersion":3,"screens":{},"defaultLayout":{"type":"leaf"}}"#.utf8)
    check(try JSONDecoder().decode(LineupConfig.self, from: old).appPlacements == nil,
          "placement: old Zones settings load without associations or a migration")
    let malformed = Data(#"{"schemaVersion":3,"screens":{},"defaultLayout":{"type":"leaf"},"appPlacements":{"app.one":{"screenKey":9}}}"#.utf8)
    check((try? JSONDecoder().decode(LineupConfig.self, from: malformed)) == nil,
          "placement: malformed saved associations reject the section instead of dropping user data")
}
