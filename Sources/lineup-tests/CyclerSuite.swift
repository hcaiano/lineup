import AppCore
import Foundation
import CyclerCore

// Cycler checks — copied verbatim from cycler-tests/main.swift. The hyper-key checks
// that used to live in the middle of this file now live in HyperkeySuite.swift, because
// TriggerKey/HyperKeySettings moved to HyperkeyCore (see CyclerCore/Bindings.swift).

func runCyclerTests() throws {
    // Carbon hyper mask (⌃⌥⇧⌘), duplicated here so the test target needs no Carbon import.
    let hyperMask: UInt32 = 0x100 | 0x800 | 0x200 | 0x1000 // shift | cmd | option | control

    // ---- SemVer ----
    check(SemVer.isNewer("1.7.0", than: "1.6.4"), "1.7.0 > 1.6.4")
    check(SemVer.isNewer("v2.0.0", than: "1.9.9"), "v2.0.0 > 1.9.9 (leading v)")
    check(!SemVer.isNewer("1.0.0", than: "1.0.0"), "equal is not newer")
    check(!SemVer.isNewer("1.0", than: "1.0.0"), "1.0 == 1.0.0")
    check(!SemVer.isNewer("garbage", than: "1.0.0"), "unparseable is not newer")

    // ---- WindowCycle: the press-again-to-advance order ----
    check(WindowCycle.next(count: 0, current: nil) == nil, "no windows -> nil")
    check(WindowCycle.next(count: 3, current: nil) == 0, "first engagement focuses window 0")
    check(WindowCycle.next(count: 1, current: nil) == 0, "single window -> 0")
    check(WindowCycle.next(count: 1, current: 0) == 0, "single window repeat stays at 0")
    check(WindowCycle.next(count: 3, current: 0) == 1, "advance 0 -> 1")
    check(WindowCycle.next(count: 3, current: 1) == 2, "advance 1 -> 2")
    check(WindowCycle.next(count: 3, current: 2) == 0, "advance wraps 2 -> 0")
    check(WindowCycle.next(count: 3, current: 0, direction: .backward) == 2, "backward wraps 0 -> 2")
    check(WindowCycle.next(count: 3, current: 2, direction: .backward) == 1, "backward 2 -> 1")
    check(WindowCycle.next(count: 3, current: 9) == 1, "stale out-of-range index is normalised (9%3=0 -> 1)")

    // ---- WindowRoutingSelector: pure Tiles-aware candidate ranking ----
    let visibleRouting = WindowRoutingSelector.select([
        WindowRoutingCandidate(windowID: 40, isMinimized: true, disposition: .currentContext),
        WindowRoutingCandidate(windowID: 20, isMinimized: false, disposition: .unmanaged),
        WindowRoutingCandidate(windowID: 30, isMinimized: false,
                               disposition: .inactiveWorkspace(workspace: 2, focusEpoch: 99)),
        WindowRoutingCandidate(windowID: 10, isMinimized: false, disposition: .currentContext),
    ])
    check(visibleRouting.indices == [1, 3] && visibleRouting.hasCurrentCandidates,
          "visible current and unmanaged windows win in stable input order")

    let minimizedRouting = WindowRoutingSelector.select([
        WindowRoutingCandidate(windowID: 50, isMinimized: true, disposition: .currentContext),
        WindowRoutingCandidate(windowID: 15, isMinimized: true, disposition: .unmanaged),
        WindowRoutingCandidate(windowID: 5, isMinimized: false,
                               disposition: .inactiveWorkspace(workspace: 2, focusEpoch: 100)),
    ])
    check(minimizedRouting.indices == [1] && minimizedRouting.hasCurrentCandidates,
          "one current minimized window wins by stable window ID before inactive workspaces")

    let inactiveRouting = WindowRoutingSelector.select([
        WindowRoutingCandidate(windowID: 40, isMinimized: false,
                               disposition: .inactiveWorkspace(workspace: 2, focusEpoch: 7)),
        WindowRoutingCandidate(windowID: 30, isMinimized: false,
                               disposition: .inactiveWorkspace(workspace: 3, focusEpoch: 9)),
        WindowRoutingCandidate(windowID: 20, isMinimized: false,
                               disposition: .inactiveWorkspace(workspace: 4, focusEpoch: 9)),
        WindowRoutingCandidate(windowID: 10, isMinimized: false,
                               disposition: .unavailable(message: "Tiles is paused")),
    ])
    check(inactiveRouting.indices == [2] && !inactiveRouting.hasCurrentCandidates,
          "inactive fallback prefers latest Tiles focus then the lowest stable ID")
    check(inactiveRouting.unavailableMessage == "Tiles is paused",
          "routing preserves unavailable feedback while choosing an inactive candidate")

    // ---- CyclerConfig: round-trips and tolerates a missing/empty file ----
    do {
        let cfg = CyclerConfig(bindings: [
            AppBinding(keyCode: 18, modifiers: hyperMask, bundleIdentifier: "com.google.Chrome"),
            AppBinding(keyCode: 19, modifiers: hyperMask, bundleIdentifier: "com.apple.Safari"),
        ])
        let data = try cfg.encoded()
        let back = try CyclerConfig.decode(data)
        check(back == cfg, "CyclerConfig encode/decode round-trips")
        check(back.bindings.count == 2, "two bindings survive the round-trip")
    }
    do {
        let empty = try CyclerConfig.decode(Data("{\"bindings\":[]}".utf8))
        check(empty.bindings.isEmpty, "empty bindings array decodes to no bindings")
        check(empty.showMenuBarIcon, "legacy config shows the menu-bar icon by default")
    }
    do {
        let cfg = CyclerConfig(showMenuBarIcon: false)
        let back = try CyclerConfig.decode(try cfg.encoded())
        check(!back.showMenuBarIcon, "hidden menu-bar preference round-trips")
        let json = String(decoding: try cfg.encoded(), as: UTF8.self)
        check(json.contains("\"showMenuBarIcon\" : false"), "encode emits hidden menu-bar preference")
    }

    // ---- AppBinding: legacy decode, canonical encode, group shape ----
    do {
        // Legacy single-app JSON (the only shape v0.2 wrote) still decodes.
        let legacy = try CyclerConfig.decode(Data(
            "{\"bindings\":[{\"keyCode\":18,\"modifiers\":6912,\"bundleIdentifier\":\"com.google.Chrome\"}]}".utf8))
        check(legacy.bindings.count == 1, "legacy bundleIdentifier decodes to one binding")
        check(legacy.bindings.first?.bundleIdentifiers == ["com.google.Chrome"], "legacy id lands in the array")
        check(legacy.bindings.first?.isGroup == false, "single-app binding is not a group")
    }
    do {
        // Canonical encoding is always the bundleIdentifiers array, even for one app.
        let cfg = CyclerConfig(bindings: [AppBinding(keyCode: 18, modifiers: hyperMask, bundleIdentifier: "com.apple.Safari")])
        let json = String(decoding: try cfg.encoded(), as: UTF8.self)
        check(json.contains("\"bundleIdentifiers\""), "encode emits bundleIdentifiers")
        check(!json.contains("\"bundleIdentifier\""), "encode drops the legacy singular key")
    }
    do {
        // A multi-app group round-trips with its order intact.
        let group = AppBinding(keyCode: 18, modifiers: hyperMask,
                               bundleIdentifiers: ["com.apple.Safari", "com.apple.mail", "com.apple.Notes"])
        let cfg = CyclerConfig(bindings: [group])
        let back = try CyclerConfig.decode(try cfg.encoded())
        check(back == cfg, "group binding round-trips")
        check(back.bindings.first?.isGroup == true, "three-app binding is a group")
        check(back.bindings.first?.bundleIdentifiers == ["com.apple.Safari", "com.apple.mail", "com.apple.Notes"],
              "group order survives the round-trip")
    }
    do {
        // An explicitly empty target list is rejected, not silently turned into an unusable binding.
        var threw = false
        do { _ = try CyclerConfig.decode(Data(
            "{\"bindings\":[{\"keyCode\":18,\"modifiers\":6912,\"bundleIdentifiers\":[]}]}".utf8)) }
        catch { threw = true }
        check(threw, "empty bundleIdentifiers array is rejected")
    }
    do {
        // A binding with neither key is rejected.
        var threw = false
        do { _ = try CyclerConfig.decode(Data("{\"bindings\":[{\"keyCode\":18,\"modifiers\":6912}]}".utf8)) }
        catch { threw = true }
        check(threw, "binding with no target list is rejected")
    }
    do {
        // Duplicate shortcuts are normalised into one group, preserving the first shortcut's position.
        let cfg = CyclerConfig(bindings: [
            AppBinding(keyCode: 18, modifiers: hyperMask, bundleIdentifier: "com.openai.codex"),
            AppBinding(keyCode: 19, modifiers: hyperMask, bundleIdentifier: "com.apple.Safari"),
            AppBinding(keyCode: 18, modifiers: hyperMask, bundleIdentifier: "com.anthropic.claudefordesktop"),
            AppBinding(keyCode: 18, modifiers: hyperMask,
                       bundleIdentifiers: ["com.openai.codex", "com.google.Gemini"]),
        ])
        let merged = cfg.coalescingDuplicateShortcuts()
        check(merged.bindings.count == 2, "duplicate shortcut bindings coalesce")
        check(merged.bindings[0].bundleIdentifiers == [
            "com.openai.codex",
            "com.anthropic.claudefordesktop",
            "com.google.Gemini",
        ], "coalescing preserves order and skips repeated apps")
        check(merged.bindings[1].bundleIdentifiers == ["com.apple.Safari"],
              "distinct shortcuts stay separate")
    }

    do {
        let cfg = CyclerConfig(
            bindings: [
                AppBinding(keyCode: 18, modifiers: hyperMask, bundleIdentifier: "com.openai.codex"),
                AppBinding(keyCode: 18, modifiers: hyperMask, bundleIdentifier: "com.google.Gemini"),
            ],
            showMenuBarIcon: false)
        let merged = cfg.coalescingDuplicateShortcuts()
        check(!merged.showMenuBarIcon, "coalescing preserves hidden menu-bar preference")
    }

    // ---- AppGroupCycle: the press-again-to-cycle-apps order ----
    let safari = "com.apple.Safari", mail = "com.apple.mail", notes = "com.apple.Notes"
    let trio = [safari, mail, notes]
    let allInstalled = Set(trio)

    // Nothing running: launch the first installed app in order.
    check(AppGroupCycle.next(group: trio, installed: allInstalled, running: [], frontmost: nil) == .launch(safari),
          "none running -> launch first installed")
    // First app missing: launch the next installed one instead.
    check(AppGroupCycle.next(group: trio, installed: [mail, notes], running: [], frontmost: nil) == .launch(mail),
          "none running, first not installed -> launch next installed")
    // Nothing installed at all: do nothing.
    check(AppGroupCycle.next(group: trio, installed: [], running: [], frontmost: nil) == AppGroupCycle.Action.none,
          "none running, none installed -> none")
    // Empty group: do nothing.
    check(AppGroupCycle.next(group: [], installed: [], running: [], frontmost: nil) == AppGroupCycle.Action.none,
          "empty group -> none")

    // Exactly one member running: activate it when it's not frontmost, hide it when it is.
    check(AppGroupCycle.next(group: trio, installed: allInstalled, running: [mail], frontmost: safari) == .activate(mail),
          "one running, not frontmost -> activate it")
    check(AppGroupCycle.next(group: trio, installed: allInstalled, running: [mail], frontmost: mail) == .hide(mail),
          "one running, frontmost -> hide it")

    // Several running: step to the next/previous running app in group order.
    check(AppGroupCycle.next(group: trio, installed: allInstalled, running: allInstalled, frontmost: safari) == .activate(mail),
          "multiple running, forward from first -> second")
    check(AppGroupCycle.next(group: trio, installed: allInstalled, running: allInstalled, frontmost: notes) == .activate(safari),
          "multiple running, forward wraps last -> first")
    check(AppGroupCycle.next(group: trio, installed: allInstalled, running: allInstalled, frontmost: mail, direction: .backward) == .activate(safari),
          "multiple running, backward from middle -> previous")
    check(AppGroupCycle.next(group: trio, installed: allInstalled, running: allInstalled, frontmost: safari, direction: .backward) == .activate(notes),
          "multiple running, backward wraps first -> last")

    // Frontmost is outside the group: enter at the first running (forward) / last running (backward).
    check(AppGroupCycle.next(group: trio, installed: allInstalled, running: [safari, notes], frontmost: "com.other.App") == .activate(safari),
          "frontmost outside group, forward -> first running")
    check(AppGroupCycle.next(group: trio, installed: allInstalled, running: [safari, notes], frontmost: "com.other.App", direction: .backward) == .activate(notes),
          "frontmost outside group, backward -> last running")

    // Non-running members are skipped: Safari and Notes up (Mail down), forward from Safari -> Notes.
    check(AppGroupCycle.next(group: trio, installed: allInstalled, running: [safari, notes], frontmost: safari) == .activate(notes),
          "multiple running skips the non-running member")
    // Frontmost is an installed-but-not-running group member: treated as outside the running set.
    check(AppGroupCycle.next(group: trio, installed: allInstalled, running: [safari, notes], frontmost: mail) == .activate(safari),
          "frontmost is a non-running group member -> enter at first running")

    let display = AppGroupCycle.display(
        group: trio,
        running: [safari, notes],
        action: .activate(notes))
    check(display.selectedIndex == 2, "group display selects the action target in full group order")
    check(display.rows.map(\.bundleIdentifier) == trio, "group display preserves every configured app")
    check(display.rows.map(\.isRunning) == [true, false, true],
          "group display marks non-running apps without dropping them")
    check(display.rows.map(\.isSelected) == [false, false, true],
          "group display highlights only the selected target")
    let launchDisplay = AppGroupCycle.display(group: trio, running: [], action: .launch(safari))
    check(launchDisplay.selectedIndex == 0, "group display selects the launch target")
    check(launchDisplay.rows.map(\.isRunning) == [false, false, false],
          "group display marks all apps not running before launch")
    check(launchDisplay.rows.map(\.isSelected) == [true, false, false],
          "group display highlights the launch target even before it is running")
    let quietDisplay = AppGroupCycle.display(group: trio, running: [mail], action: .hide(mail))
    check(quietDisplay.selectedIndex == nil, "group display has no selected target for hide")
    check(!quietDisplay.rows.contains(where: \.isSelected), "group display does not highlight hide actions")

    // ---- WindowContext: best-effort trailing-context enrichment for the HUD ----
    do {
        let chrome = "Google Chrome"

        let a = WindowContext.trailingContext(
            title: "GAMES.GG Guides Overlay - Google Chrome - Henrique (GAMES.GG)", appName: chrome)
        check(a == WindowContext.Parsed(title: "GAMES.GG Guides Overlay", context: "GAMES.GG"),
              "chromium: parenthetical profile -> GAMES.GG")

        let b = WindowContext.trailingContext(
            title: "Sign in ・ Cloudflare Access - Google Chrome - Henrique (Pessoal)", appName: chrome)
        check(b == WindowContext.Parsed(title: "Sign in ・ Cloudflare Access", context: "Pessoal"),
              "chromium: parenthetical profile -> Pessoal")

        let c = WindowContext.trailingContext(title: "Some Window - Google Chrome - Work", appName: chrome)
        check(c == WindowContext.Parsed(title: "Some Window", context: "Work"),
              "chromium: bare profile -> Work verbatim")

        // A page whose own title contains ' - Google Chrome - ' must anchor on the LAST occurrence.
        let d = WindowContext.trailingContext(
            title: "Recap - Google Chrome - tips - Google Chrome - Work", appName: chrome)
        check(d == WindowContext.Parsed(title: "Recap - Google Chrome - tips", context: "Work"),
              "chromium: anchors on the last browser segment")

        // No profile suffix (single-profile Chrome): returned untouched, no regression.
        let e = WindowContext.trailingContext(title: "Some Window - Google Chrome", appName: chrome)
        check(e == WindowContext.Parsed(title: "Some Window - Google Chrome", context: nil),
              "chromium: no profile suffix -> unchanged")

        // No anchor at all: untouched.
        let f = WindowContext.trailingContext(title: "Just A Plain Title", appName: chrome)
        check(f == WindowContext.Parsed(title: "Just A Plain Title", context: nil),
              "chromium: no anchor -> unchanged")

        // Empty parenthetical falls back conservatively to the verbatim suffix.
        let g = WindowContext.trailingContext(title: "Page - Google Chrome - Henrique ()", appName: chrome)
        check(g == WindowContext.Parsed(title: "Page", context: "Henrique ()"),
              "chromium: empty parenthetical -> verbatim suffix")

        // A bare browser anchor that is actually part of a longer word never matches.
        let h = WindowContext.trailingContext(title: "Buy a Google Chromecast - Google Chrome", appName: chrome)
        check(h == WindowContext.Parsed(title: "Buy a Google Chromecast - Google Chrome", context: nil),
              "chromium: substring-like browser name without profile -> unchanged")

        // Empty app name can never anchor.
        let i = WindowContext.trailingContext(title: "Page - Google Chrome - Work", appName: "")
        check(i == WindowContext.Parsed(title: "Page - Google Chrome - Work", context: nil),
              "trailingContext: empty appName -> unchanged")

        // The parser is app-agnostic: the same grammar extracts for any anchoring app name.
        let brave = WindowContext.trailingContext(title: "Docs - Brave - Personal", appName: "Brave")
        check(brave == WindowContext.Parsed(title: "Docs", context: "Personal"),
              "trailingContext: generic appName (Brave) extracts context")
        let chromium = WindowContext.trailingContext(
            title: "Inbox - Chromium - Henrique (Work)", appName: "Chromium")
        check(chromium == WindowContext.Parsed(title: "Inbox", context: "Work"),
              "trailingContext: generic appName (Chromium) extracts parenthetical context")

        // Slack-style title: the app name is LAST, so there is no trailing context to take. The useful
        // workspace lives mid-title, which this grammar deliberately does not reach -> untouched.
        let slack = WindowContext.trailingContext(
            title: "* Igor (DM) - GAMES.GG - 5 new items - Slack", appName: "Slack")
        check(slack == WindowContext.Parsed(title: "* Igor (DM) - GAMES.GG - 5 new items - Slack", context: nil),
              "trailingContext: app-name-last (Slack) -> unchanged")

        // VS Code-style title: em-dash separators, no ` - <appName> - ` anchor -> untouched.
        let code = WindowContext.trailingContext(
            title: "WindowContext.swift — cycler", appName: "Code")
        check(code == WindowContext.Parsed(title: "WindowContext.swift — cycler", context: nil),
              "trailingContext: em-dash title (VS Code) -> unchanged")
    }

    // ---- WindowContext.supportsTrailingContext: the Chromium-family allowlist ----
    do {
        check(WindowContext.supportsTrailingContext(bundleIdentifier: "com.google.Chrome"),
              "allowlist: Chrome stable is supported")
        check(WindowContext.supportsTrailingContext(bundleIdentifier: "com.google.Chrome.beta"),
              "allowlist: Chrome channel is supported")
        check(WindowContext.supportsTrailingContext(bundleIdentifier: "org.chromium.Chromium"),
              "allowlist: Chromium is supported")
        check(WindowContext.supportsTrailingContext(bundleIdentifier: "com.microsoft.edgemac"),
              "allowlist: Edge is supported")
        check(WindowContext.supportsTrailingContext(bundleIdentifier: "com.brave.Browser"),
              "allowlist: Brave is supported")

        check(!WindowContext.supportsTrailingContext(bundleIdentifier: "com.apple.Safari"),
              "allowlist: Safari is not supported")
        check(!WindowContext.supportsTrailingContext(bundleIdentifier: "org.mozilla.firefox"),
              "allowlist: Firefox is not supported")
        check(!WindowContext.supportsTrailingContext(bundleIdentifier: "com.tinyspeck.slackmacgap"),
              "allowlist: Slack is not supported")
        check(!WindowContext.supportsTrailingContext(bundleIdentifier: "com.microsoft.VSCode"),
              "allowlist: VS Code is not supported")
        check(!WindowContext.supportsTrailingContext(bundleIdentifier: nil),
              "allowlist: nil bundle id is not supported")
    }

    try runCyclerToolChecks()
}

// MARK: - Phase 5: the Cycler tool

/// Checks for `Sources/lineup/Tools/Cycler/`. The tool itself lives in the app target, which this
/// dependency-free runner deliberately does not link (no AppKit, no Carbon, no Sparkle), so the
/// lifecycle invariants are asserted as source scans — the same technique `AppSuite` uses for the
/// shell. They are cheap and they fail loudly if a later refactor drops one of the teardown steps.
private func runCyclerToolChecks() throws {
    let files = cyclerToolSources()

    for name in ["CyclerTool", "CyclerSettingsPane", "AppPicker", "AppActivator", "CycleHUD"] {
        check(files.contains { $0.path == "Sources/lineup/Tools/Cycler/\(name).swift" },
              "Cycler tool file \(name).swift exists")
    }

    guard let tool = files.first(where: { $0.path.hasSuffix("CyclerTool.swift") })?.text else {
        check(false, "CyclerTool.swift is readable")
        return
    }

    // ---- The Hyperkey split (plan §2.2): NOTHING hyper-key belongs to Cycler ----
    // Bindings hold raw Carbon masks, so they fire whatever produces ⌃⌥⇧⌘. If any of these names
    // reappears here, the two tools have been re-coupled and Phase 6 owns the same lines twice.
    for banned in ["hyperKey", "HyperKey", "TriggerKey", "systemDidWake", "capsLock", "hidutil"] {
        let offenders = files.filter { $0.text.contains(banned) }.map(\.path)
        check(offenders.isEmpty, "no Cycler source mentions \(banned) (got \(offenders))")
    }

    // The copied files were retargeted onto Lineup's log subsystem; none may still name Cycler's
    // old bundle id (the standalone app's subsystem, and now a different process entirely).
    let staleSubsystem = files.filter { $0.text.contains("com.caiano.cycler") }.map(\.path)
    check(staleSubsystem.isEmpty, "no Cycler source keeps the standalone bundle id (got \(staleSubsystem))")
    for name in ["AppActivator", "CycleHUD"] {
        guard let text = files.first(where: { $0.path.hasSuffix("\(name).swift") })?.text else { continue }
        check(!text.contains("Logger(subsystem:") || text.contains("Product.logSubsystem"),
              "\(name).swift logs under Product.logSubsystem")
    }

    // ---- stop() gives every resource back (plan §3 Phase 5) ----
    // A tool the user switched off must leave nothing behind: no live Carbon registration, no retry
    // timer, no floating HUD panel, no cached per-app window positions, no notification observer.
    guard let stopBody = swiftFunctionBody(named: "func stop() {", in: tool) else {
        check(false, "CyclerTool has a stop()")
        return
    }
    for (fragment, what) in [
        ("hotkeys.unregisterAll()", "releases its Carbon hotkeys"),
        ("failedHotkeyRetryTimer?.invalidate()", "invalidates the failed-hotkey retry timer"),
        ("failedHotkeyRetryTimer = nil", "drops the retry timer reference"),
        ("CycleHUD.shared.dismiss()", "dismisses the cycle HUD"),
        ("AppActivator.shared.reset()", "resets the activator's remembered windows"),
        ("removeObserver", "removes its notification observers"),
        ("observers.removeAll()", "empties the observer list"),
        ("isRunning = false", "reports itself stopped"),
    ] {
        check(stopBody.contains(fragment), "CyclerTool.stop() \(what)")
    }
    // The singletons stop() reaches for must actually expose those entry points.
    check(files.first(where: { $0.path.hasSuffix("CycleHUD.swift") })?.text.contains("func dismiss()") == true,
          "CycleHUD exposes dismiss()")
    check(files.first(where: { $0.path.hasSuffix("AppActivator.swift") })?.text.contains("func reset()") == true,
          "AppActivator exposes reset()")

    // ---- Accessibility calls are budgeted (never the 6s system default) ----
    // Every AX call here is synchronous on the main thread, from a hotkey handler. A beachballing
    // target app would otherwise freeze the menu bar, the HUD and Zones for six seconds per call —
    // long enough for the system to kill Hyperkey's event tap for being slow.
    let activator = files.first(where: { $0.path.hasSuffix("AppActivator.swift") })?.text ?? ""
    check(activator.contains("AXUIElementSetMessagingTimeout(element, 0.25)"),
          "AppActivator budgets its AX messaging at 0.25s")
    let untamedCreates = activator.components(separatedBy: "AXUIElementCreateApplication(").count - 1
    check(untamedCreates == 1,
          "every AX application element comes from the one tamed factory (got \(untamedCreates) call sites)")
    check(activator.contains("private static func axApplication(_ pid: pid_t) -> AXUIElement"),
          "AppActivator creates application elements through axApplication(_:)")
    // The timeout is per-element, so the windows read out of the app element are tamed too.
    check(activator.contains(".map { tame($0) }") && activator.contains(".lazy.map({ tame($0) })"),
          "window elements are tamed as well, not just the application element")

    // ---- Tiles stays behind an injected, app-target-only routing seam ----
    check(activator.contains("enum CyclerWindowContext: Equatable")
            && activator.contains("case currentContext")
            && activator.contains("case unmanaged")
            && activator.contains("case inactiveWorkspace(workspace: Int, focusEpoch: UInt64)")
            && activator.contains("case unavailable(message: String)"),
          "Cycler exposes the routed window contexts, including unavailable Tiles windows")
    check(activator.contains("struct CyclerWindowRoute")
            && activator.contains("let context: CyclerWindowContext")
            && activator.contains("let requestInactiveActivation: (@MainActor () -> Void)?")
            && activator.contains("struct CyclerWindowRouting")
            && activator.contains("let route: @MainActor (AXUIElement) -> CyclerWindowRoute")
            && activator.contains("typealias CyclerWindowRoutingProvider = @MainActor () -> CyclerWindowRouting?"),
          "Cycler routing captures context and an optional actor-isolated inactive action")
    check(!activator.contains("import TilesCore") && !tool.contains("import TilesCore"),
          "Cycler does not import the Tiles model")
    check(tool.contains("private let windowRoutingProvider: CyclerWindowRoutingProvider")
            && tool.contains("init(windowRouting: @escaping CyclerWindowRoutingProvider = { nil })")
            && tool.contains("let windowRouting = windowRoutingProvider()")
            && tool.contains("windowRouting: windowRouting)"),
          "Cycler resolves one optional routed-window seam per engagement")

    // A context switch changes the candidate array. Remembering an index would then select a
    // different window; the stable CGWindowID remains meaningful across filtering and reordering.
    check(activator.contains("private var lastWindowID: [String: CGWindowID] = [:]")
            && activator.components(separatedBy: "firstIndex { $0.windowID == rememberedID }").count - 1 == 2
            && !activator.contains("lastIndex"),
          "Cycler remembers the last real window ID instead of a filtered-array index")
    check(activator.contains("var route: CyclerWindowRoute?")
            && activator.components(separatedBy: "windowRouting?.route(window)").count - 1 == 1
            && activator.contains("switch window.route?.context {")
            && !activator.contains("route(window.element)"),
          "routed window context and action are captured once and reused for selection")
    let standardFilter = activator.range(of: "guard standard || (minimized && hasWindowRole(window)) else { return nil }")
    let routeCapture = activator.range(of: "let route = windowRouting?.route(window)")
    check(activator.contains("let standard = isStandardWindow(window)")
            && standardFilter != nil
            && routeCapture != nil
            && standardFilter!.lowerBound < routeCapture!.lowerBound
            && activator.contains("if !standard {")
            && activator.contains("guard let route, route.context != .unmanaged else { return nil }")
            && activator.contains("AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString")
            && activator.contains("return role == kAXWindowRole as String")
            && !activator.contains("kAXDialogSubrole")
            && !activator.contains("com.apple.finder"),
          "only a minimized Tiles-managed AXWindow may bypass the standard-window filter")
    let routingSelector = (try? String(
        contentsOfFile: "Sources/CyclerCore/WindowRoutingSelection.swift", encoding: .utf8)) ?? ""
    check(activator.contains("private struct CandidateSelection")
            && activator.contains("var hasCurrentCandidates: Bool")
            && activator.contains("var unavailableMessage: String?")
            && activator.contains("var isMinimized: Bool")
            && activator.contains("private static func candidateSelection(from windows: [WindowRecord],")
            && activator.contains("WindowRoutingSelector.select")
            && activator.contains("selection.indices.map { windows[$0] }")
            && routingSelector.contains("var currentVisible: [Int] = []")
            && routingSelector.contains("var currentMinimized: [Int] = []")
            && routingSelector.contains("lhs.focusEpoch > rhs.focusEpoch"),
          "AppKit delegates deterministic current, minimized, and inactive ranking to CyclerCore")
    let cycleHUD = files.first(where: { $0.path.hasSuffix("CycleHUD.swift") })?.text ?? ""
    check(activator.contains("case .unavailable(let message): disposition = .unavailable(message: message)")
            && routingSelector.contains("if unavailableMessage == nil { unavailableMessage = message }")
            && cycleHUD.contains("func showBlocked(_ message: String)")
            && cycleHUD.contains("exclamationmark.triangle.fill")
            && cycleHUD.contains("rowViews[0].update(title: message"),
          "Cycler carries unavailable feedback through CandidateSelection to an explicit warning HUD")
    check(activator.contains("if windowRouting != nil, windows.isEmpty, !allWindows.isEmpty {")
            && activator.contains("if let message = selection.unavailableMessage")
            && activator.contains("CycleHUD.shared.showBlocked(message)"),
          "Cycler skips unavailable Tiles windows and does not hide during a runtime pause")
    check(activator.contains("if windows.count == 1, windows[0].isMinimized")
            && activator.contains("let minimized = isMinimized(window)")
            && activator.contains("isMinimized: minimized")
            && activator.contains("Self.allWindows(of: apps, using:"),
          "an explicit Cycler press can restore a routed minimized window without a second AX read")
    check(activator.contains("Self.showGroupHUD(display)")
            && activator.contains("if !selection.windows.isEmpty {")
            && activator.contains("if allWindows.isEmpty, app.isHidden {")
            && activator.contains("allWindows = Self.allWindows(of: apps, using: windowRouting)")
            && activator.contains("let targetIndex = Self.indexOfMain(in: selection.windows) ?? 0")
            && activator.contains("let targetWindow = selection.windows[targetIndex]")
            && !activator.contains("selection.windows.first")
            && activator.contains("Self.activateRoutedWindow(targetWindow)")
            && activator.contains("} else if let message = selection.unavailableMessage {")
            && activator.contains("CycleHUD.shared.showBlocked(message)\n                    return"),
          "a group prefers its current main window and reports unavailable routing before a false-success HUD")
    check(activator.contains("case .hide(let bundleIdentifier):")
            && activator.contains("if !selection.windows.isEmpty, !selection.hasCurrentCandidates {")
            && activator.contains("Self.activateRoutedWindow(selection.windows[targetIndex])")
            && activator.contains("selection.windows.isEmpty, !allWindows.isEmpty,"),
          "a frontmost group returns to its staged Tiles window instead of hiding its process")
    check(activator.contains("guard windowRouting != nil else {")
            && activator.contains("hasCurrentCandidates: !windows.isEmpty")
            && activator.contains("unavailableMessage: nil")
            && activator.contains("windowRouting.map { Self.allWindows(of: apps, using: $0) }")
            && activator.contains("?? Self.windows(of: apps)")
            && activator.contains("windows(of: apps, includeMinimized: false, windowRouting: nil)")
            && activator.contains("direction: direction)"),
          "nil routing keeps the visible-window cycle and forward/reverse direction")
    check(activator.contains("guard case .inactiveWorkspace = context")
            && activator.contains("if window.route?.activateIfInactive() == true { return true }")
            && activator.contains("raise(window.element)")
            && activator.contains("window.app.activate(options: [])")
            && activator.contains("return false"),
          "only an inactive route delegates activation; current and unmanaged routes raise directly")
    check(activator.contains("let tilesOwnsFeedback = Self.activateRoutedWindow")
            && activator.contains("if !tilesOwnsFeedback")
            && activator.contains("if !tilesOwnsFeedback { Self.showGroupHUD(display) }"),
          "Cycler suppresses its own HUD when Tiles owns inactive-workspace feedback")

    // ---- First press enumerates the window list ONCE ----
    // Activating and then re-reading every window of every process doubled the AX round trips on
    // the commonest path; `indexOfMain` reads each window's live AXMain anyway, so only an EMPTY
    // first pass (a hidden app whose windows appear once it is unhidden) is worth a second sweep.
    check(activator.contains("if windows.isEmpty, allWindows.isEmpty {")
            && activator.contains("if windowRouting != nil, app.isHidden { app.unhide() }")
            && activator.contains("let refreshed = windowRouting.map { Self.allWindows(of: apps, using: $0) }"),
          "the first press unhides without activating every window and re-enumerates only when no routed windows were found")
    check(activator.contains("if allWindows.isEmpty, app.isHidden {")
            && activator.contains("app.unhide()\n                    allWindows = Self.allWindows(of: apps, using: windowRouting)"),
          "a hidden group publishes AX windows before Tiles chooses which routed window to activate")
    let sweeps = activator.components(separatedBy: "Self.windows(of: apps)").count - 1
    check(sweeps == 2, "engage() has exactly two window sweeps in its source, one of them conditional (got \(sweeps))")

    // ---- The forward/reverse registration pair, kept verbatim from standalone Cycler ----
    check(tool.contains("guard b.modifiers & UInt32(shiftKey) == 0 else { continue }"),
          "a binding that already includes Shift gets no generated reverse")
    check(tool.contains("guard !explicitCombos.contains(combo) else { continue }"),
          "a generated reverse is skipped when another binding claims that combo explicitly")
    check(tool.contains("generatedReverse: true") && tool.contains("generatedReverse: false"),
          "failures record whether they were the generated reverse")
    check(tool.contains("HotkeyFailure") && tool.contains("displayReason"),
          "blocked-shortcut wording comes from HotkeyFailure.displayReason")

    // ---- Shell contracts ----
    check(tool.contains("let defaultEnabled = false"),
          "Cycler is off by default (a silent auto-update must not grab an existing user's keys)")
    check(tool.contains("services.hotkeys.register("),
          "hotkeys are registered through the tool's HotkeyScope")
    let directRegistry = files.filter {
        $0.text.contains("HotkeyManager.shared.register") || $0.text.contains("HotkeyManager.shared.unregister")
    }.map(\.path)
    check(directRegistry.isEmpty, "no Cycler source registers on HotkeyManager directly (got \(directRegistry))")
    check(tool.contains("ToolMenu.item(") && tool.contains("ToolMenu.info("),
          "menu rows are built with the shared ToolMenu helpers")
    check(tool.contains("services.config.load(CyclerToolSettings.self)") && tool.contains("services.config.save("),
          "persistence goes through the tool's ToolConfigScope")

    guard let pane = files.first(where: { $0.path.hasSuffix("CyclerSettingsPane.swift") })?.text else {
        check(false, "CyclerSettingsPane.swift is readable")
        return
    }
    check(pane.contains("ShortcutField(") && pane.contains("Brand.cyclerAccent"),
          "the pane records with ShortcutField tinted to the Cycler accent")
    check(pane.contains("ShortcutRecorder(store:"),
          "capture runs through ShortcutRecorder, so SettingsStore suspends every tool's hotkeys")
    check(!pane.contains("addLocalMonitorForEvents"),
          "the pane owns no NSEvent monitor of its own (the legacy SettingsModel one is gone)")
    check(pane.contains("func merge(") && pane.contains("reverseShortcutCollision"),
          "merge-on-duplicate-combo and the reverse-collision warning survive the port")

    // The tool has to be registered, or none of the above is reachable.
    let shell = (try? String(contentsOfFile: "Sources/lineup/App/AppShell.swift", encoding: .utf8)) ?? ""
    check(shell.contains("registry.register(CyclerTool(windowRouting: {")
            && shell.contains("guard let self, self.tilesCoordinator.isCyclerRoutingActive else { return nil }")
            && shell.contains("return CyclerWindowRouting(route: { [weak self] element in")
            && shell.contains("cyclerWindowRoute(for: element)"),
          "AppShell registers Cycler with an optional actionable Tiles routing seam")

    // ---- CyclerToolSettings: the section Cycler actually writes ----
    do {
        // The persisted section carries bindings and NOTHING else — no hyperKey key may leak back
        // into it, or a rollback to standalone Cycler would read two sources of truth.
        let settings = CyclerToolSettings(bindings: [
            AppBinding(keyCode: 18, modifiers: 0x1F00, bundleIdentifier: "com.google.Chrome"),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = String(decoding: try encoder.encode(settings), as: UTF8.self)
        check(!json.contains("hyperKey"), "the cycler section encodes no hyperKey")
        check(!json.contains("showMenuBarIcon"), "the cycler section encodes no menu-bar preference")
        let back = try JSONDecoder().decode(CyclerToolSettings.self, from: Data(json.utf8))
        check(back == settings, "CyclerToolSettings round-trips")
    }
    do {
        // What `CyclerTool.save` leans on: two apps recorded onto the same combo become one group,
        // in the order they were bound. This is the merge path the pane's recorder produces.
        let merged = CyclerToolSettings(bindings: [
            AppBinding(keyCode: 18, modifiers: 0x1F00, bundleIdentifier: "com.google.Chrome"),
            AppBinding(keyCode: 18, modifiers: 0x1F00, bundleIdentifier: "com.apple.Safari"),
            AppBinding(keyCode: 19, modifiers: 0x1F00, bundleIdentifier: "com.apple.Terminal"),
        ]).coalescingDuplicateShortcuts()
        check(merged.bindings.count == 2, "duplicate combos coalesce into one binding")
        check(merged.bindings.first?.bundleIdentifiers == ["com.google.Chrome", "com.apple.Safari"],
              "the coalesced group keeps the order the apps were bound in")
        check(merged.bindings.first?.isGroup == true, "the coalesced binding is a group")
    }
}

/// Every Swift file under `Sources/lineup/Tools/Cycler/`.
private func cyclerToolSources() -> [(path: String, text: String)] {
    let root = "Sources/lineup/Tools/Cycler"
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
    return names.filter { $0.hasSuffix(".swift") }.sorted().compactMap { name in
        let path = "\(root)/\(name)"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return (path, text)
    }
}

/// The body of a top-level-indented Swift function, matched by its opening line and closed by the
/// first `\n    }`. Good enough for the 4-space-indented members these scans look at.
private func swiftFunctionBody(named opening: String, in text: String) -> String? {
    guard let start = text.range(of: opening) else { return nil }
    let rest = text[start.upperBound...]
    guard let end = rest.range(of: "\n    }") else { return nil }
    return String(rest[..<end.lowerBound])
}
