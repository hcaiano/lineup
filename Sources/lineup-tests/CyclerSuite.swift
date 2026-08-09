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
}
