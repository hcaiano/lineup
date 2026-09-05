import Foundation
import HintsCore
import AppCore

// HintsCore coverage. Deterministic, dependency-free (Foundation + AppCore for the bridge
// tests only), driven through the shared `check` harness. The core lane owns this file;
// `main.swift` wiring belongs to the shared integration owner — `runHintsTests()` is the
// only required entry point.

func runHintsTests() throws {
    try hintsSettingsTests()
    try hintsBridgeTests()
    hintsLabelMakerTests()
    hintsFilterSearchTests()
    hintsEligibilityTests()
    hintsGeometryTests()
    hintsReducerSessionTests()
    hintsReducerModesTests()
    hintsReducerScrollTests()
    hintsReducerCancellationTests()
    hintsReducerReleaseRoutingTests()
    hintsLimitsTests()
    hintsTruncationSummaryTests()
}

// MARK: - Builders

private let hintsScreensDefault: [HintRect] = [
    HintRect(x: 0, y: 0, width: 1920, height: 1080),     // display 0 (main)
    HintRect(x: -1920, y: 0, width: 1920, height: 1080), // display 1 (negative origin)
]

private func hintsContext(pid: Int32 = 100, screens: [HintRect] = hintsScreensDefault,
                          windowTokens: Set<String> = ["win-1"]) -> HintTargetContext {
    HintTargetContext(pid: pid, windowTokens: windowTokens, screens: screens)
}

private func hintCandidate(_ token: String, pid: Int32 = 100, role: HintRoleClass = .button, actions: Set<HintActionKind> = [.press], x: Double, y: Double, width: Double = 80, height: Double = 24, enabled: Bool = true, visible: Bool = true, onScreen: Bool = true, secure: Bool = false, lineup: Bool = false, title: String? = nil, label: String? = nil, description: String? = nil, windowToken: String? = "win-1", ancestors: [HintTargetToken] = [], continuity: HintContinuityID? = nil) -> HintCandidate {
    HintCandidate(
        token: HintTargetToken(token),
        pid: pid,
        windowToken: windowToken,
        role: role,
        advertisedActions: actions,
        title: title,
        label: label,
        descriptiveText: description,
        frame: HintRect(x: x, y: y, width: width, height: height),
        isEnabled: enabled,
        isVisible: visible,
        isOnScreen: onScreen,
        isSecure: secure,
        isOwnedByLineup: lineup,
        ancestorTokens: ancestors,
        continuity: continuity
    )
}

private func hintsNormalReducer() -> HintSessionReducer {
    HintSessionReducer(limits: .standard, alphabet: HintLabelMaker.defaultAlphabet)
}

/// Activate and present three plain buttons titled Save/Cancel/Open.
/// Returns the presenting session key.
@discardableResult
private func hintsPresentThree(
    _ reducer: inout HintSessionReducer,
    context: HintTargetContext = hintsContext()
) -> HintSessionKey {
    let effects = reducer.send(.activateRequested(context))
    precondition(effects.count == 1, "activation emits exactly one effect")
    guard case .startScan(let plan) = effects.first, case .scanning = reducer.state else {
        preconditionFailure("activation starts one scan")
    }
    let candidates = (0..<3).map { offset in
        hintCandidate("tok-\(offset)", x: Double(offset) * 100, y: 200, title: ["Save", "Cancel", "Open"][offset])
    }
    let presentingEffects = reducer.send(.scanCompleted(plan.key, HintScanResult(candidates: candidates)))
    precondition(presentingEffects.count == 2, "scan completes into show + barrier")
    guard case .presenting = reducer.state else { preconditionFailure("expecting presenting") }
    return plan.key
}

private func hintsAsPresenting(_ reducer: HintSessionReducer) -> HintPresentingState {
    if case .presenting(let state) = reducer.state { return state }
    preconditionFailure("expecting presenting state, got \(reducer.state)")
}

private func hintsAsScanning(_ reducer: HintSessionReducer) -> HintScanPlan {
    if case .scanning(let plan, _) = reducer.state { return plan }
    preconditionFailure("expecting scanning state, got \(reducer.state)")
}

private func hintsAsScrolling(_ reducer: HintSessionReducer) -> HintScrollingState {
    if case .scrolling(let state) = reducer.state { return state }
    preconditionFailure("expecting scrolling state, got \(reducer.state)")
}

private func hintsAsInvoking(_ reducer: HintSessionReducer) -> HintInvocationState {
    if case .invoking(let state) = reducer.state { return state }
    preconditionFailure("expecting invoking state, got \(reducer.state)")
}

private func hintsJSONDecode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(text.utf8))
}

private func hintsJSONEncode<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

// MARK: - Settings

private func hintsSettingsTests() throws {
    // Fresh (missing) section: owned keys default leniently; shortcut unassigned.
    let fresh = try hintsJSONDecode(HintsSettings.self, "{}")
    check(fresh.activationShortcut == nil, "settings: fresh shortcut unassigned")
    check(fresh.alphabet == "ASDFGHJKL", "settings: fresh alphabet default")
    check(fresh.version == 1, "settings: missing version decodes as current schema")
    check(fresh.extra.isEmpty, "settings: fresh has no unknown keys")

    let defaults = HintsSettings()
    check(defaults.activationShortcut == nil, "settings: init shortcut unassigned")
    check(defaults.alphabet == "ASDFGHJKL", "settings: init alphabet default")

    // Current values round-trip; primitives stay semantic (keyCode Int, modifiers UInt32).
    let current = HintsSettings(
        activationShortcut: HintShortcut(keyCode: 105, modifiers: 0xC),
        alphabet: "QWERASDF"
    )
    let roundTrip = try hintsJSONDecode(HintsSettings.self, try hintsJSONEncode(current))
    check(roundTrip == current, "settings: current values round-trip")
    check(roundTrip.activationShortcut?.keyCode == 105, "settings: keyCode round-trips as Int")
    check(roundTrip.activationShortcut?.modifiers == 0xC, "settings: modifiers round-trip as UInt32")
    check(roundTrip.version == 1, "settings: encode writes the current version")

    // Explicit null activation shortcut stays unassigned and is not re-encoded.
    check(try hintsJSONDecode(HintsSettings.self, #"{"version":1,"activationShortcut":null,"alphabet":"ASDFGHJKL"}"#)
        == fresh, "settings: explicit null shortcut equals unassigned")

    // Unknown top-level fields (a newer schema's data) are preserved across round-trips.
    let unknowns = try hintsJSONDecode(HintsSettings.self,
        #"{"futureField":{"nested":[1,2,{"x":3}]},"alphabet":"ASDFGHJKL"}"#)
    check(unknowns.extra["futureField"] == .object(["nested": .array([.int(1), .int(2), .object(["x": .int(3)])])]),
        "settings: unknown top-level fields preserved")
    let reEncoded = try hintsJSONDecode(HintsSettings.self, try hintsJSONEncode(unknowns))
    check(reEncoded.extra["futureField"] == unknowns.extra["futureField"], "settings: unknowns survive round-trip")

    // Unknown NESTED shortcut members are preserved and never overwrite known fields.
    let nestedUnknown = try hintsJSONDecode(HintsSettings.self,
        #"{"activationShortcut":{"keyCode":105,"modifiers":8,"futureMod":7}}"#)
    check(nestedUnknown.activationShortcut?.keyCode == 105, "settings: nested unknown decode keeps keyCode")
    check(nestedUnknown.activationShortcut?.extra == ["futureMod": .int(7)], "settings: nested unknown member kept")
    let nestedBack = try hintsJSONDecode(HintsSettings.self, try hintsJSONEncode(nestedUnknown))
    check(nestedBack.activationShortcut?.extra == ["futureMod": .int(7)],
        "settings: nested unknown member survives round-trip")

    // The unassigned shortcut is never encoded at all.
    let freshlyEncoded = try hintsJSONEncode(fresh)
    check(!freshlyEncoded.contains("activationShortcut"), "settings: unassigned shortcut not encoded")

    // Version fail-closed: newer schema throws explicitly.
    var threwNewer = false
    do { _ = try hintsJSONDecode(HintsSettings.self, #"{"version":2,"alphabet":"ASDFGHJKL"}"#) }
    catch let error as HintsSettings.SettingsError {
        if case .unsupportedVersion(2) = error { threwNewer = true }
    } catch {}
    check(threwNewer, "settings: version 2 throws unsupportedVersion")

    var threwMalformed = false
    do { _ = try hintsJSONDecode(HintsSettings.self, #"{"version":"one"}"#) } catch { threwMalformed = true }
    check(threwMalformed, "settings: malformed version type throws")

    // Malformed known values in general throw.
    var threwAlphabet = false
    do { _ = try hintsJSONDecode(HintsSettings.self, #"{"alphabet":7}"#) } catch { threwAlphabet = true }
    check(threwAlphabet, "settings: wrong alphabet type throws")

    // Wrong nested MEMBER types throw. Invalid assignment keeps the carrier so any nested
    // unknown members survive independently of the effective assignment.
    var threwNested = false
    do { _ = try hintsJSONDecode(HintsSettings.self, #"{"activationShortcut":{"keyCode":"x"}}"#) }
    catch { threwNested = true }
    check(threwNested, "settings: wrong nested keyCode type throws")

    // Invalid assignment: the carrier stays unassigned (never equal to an assigned one).
    func hintsAssertUnassigned(_ settings: HintsSettings, _ name: String) throws {
        check(settings.activationShortcut?.isAssigned == false, name)
        check(!(try hintsJSONEncode(settings).contains("keyCode")), name + " (no keyCode emitted)")
    }

    try hintsAssertUnassigned(try hintsJSONDecode(HintsSettings.self,
        #"{"activationShortcut":{"keyCode":-5,"modifiers":4}}"#),
        "settings: negative keyCode stays unassigned")
    try hintsAssertUnassigned(try hintsJSONDecode(HintsSettings.self,
        #"{"activationShortcut":{"keyCode":3,"modifiers":99999999999999}}"#),
        "settings: oversized modifiers stay unassigned")
    try hintsAssertUnassigned(try hintsJSONDecode(HintsSettings.self,
        #"{"activationShortcut":{"keyCode":4294967297,"modifiers":0}}"#),
        "settings: keyCode beyond UInt32.max stays unassigned")
    try hintsAssertUnassigned(try hintsJSONDecode(HintsSettings.self,
        #"{"activationShortcut":{"keyCode":-1,"modifiers":8}}"#),
        "settings: negative keyCode with modifiers stays unassigned")
    try hintsAssertUnassigned(try hintsJSONDecode(HintsSettings.self,
        #"{"activationShortcut":{"keyCode":10,"modifiers":0}}"#),
        "settings: zero modifiers make the whole shortcut unassigned")
    try hintsAssertUnassigned(try hintsJSONDecode(HintsSettings.self,
        #"{"activationShortcut":{"keyCode":10}}"#),
        "settings: missing modifiers make the whole shortcut unassigned")

    // True post-init mutation must also behave: assigned never lies, encode never leaks
    // the invalid known fields.
    var mutated = HintsSettings(activationShortcut: HintShortcut(keyCode: 10, modifiers: 8))
    check(mutated.activationShortcut?.isAssigned == true, "settings: assigned precondition")
    mutated.activationShortcut = HintShortcut(keyCode: 4294967296, modifiers: 8)
    check(mutated.activationShortcut?.isAssigned == false, "settings: post-init oversized key code is unassigned")
    check(!(try hintsJSONEncode(mutated).contains("keyCode")),
          "settings: post-init oversized mutation never encodes known fields")
    mutated.activationShortcut = HintShortcut(keyCode: 10, modifiers: 0)
    check(mutated.activationShortcut?.isAssigned == false, "settings: post-init zero-modifier mutation is unassigned")
    check(try hintsJSONEncode(mutated).contains("keyCode") == false,
          "settings: post-init bare mutation never encodes known fields")

    // HintShortcut.isAssigned boundary tests (same complete predicate as normalization).
    check(HintShortcut(keyCode: 0, modifiers: 1).isAssigned, "shortcut: zero key code with modifiers is assigned")
    check(HintShortcut(keyCode: 4294967295, modifiers: 1).isAssigned, "shortcut: UInt32-boundary key code is assigned")
    check(!HintShortcut(keyCode: -1, modifiers: 1).isAssigned, "shortcut: negative key code is unassigned")
    check(!HintShortcut(keyCode: 4294967296, modifiers: 1).isAssigned, "shortcut: oversized key code is unassigned")
    check(!HintShortcut(keyCode: 10, modifiers: 0).isAssigned, "shortcut: zero modifiers are unassigned")

    // Nested unknown members survive effective-unassigned carriers across full round-trips:
    // zero, missing, oversized, and out-of-range key codes all behave the same.
    for raw in [
        #"{"activationShortcut":{"keyCode":10,"modifiers":0,"futureMod":7}}"#,
        #"{"activationShortcut":{"keyCode":10,"futureMod":7}}"#,
        #"{"activationShortcut":{"keyCode":3,"modifiers":99999999999999,"futureMod":7}}"#,
        #"{"activationShortcut":{"keyCode":-6,"modifiers":8,"futureMod":7}}"#,
    ] {
        let carrier = try hintsJSONDecode(HintsSettings.self, raw)
        check(carrier.activationShortcut?.isAssigned == false, "settings: unknown-carrier variant stays unassigned")
        check(carrier.activationShortcut?.extra == ["futureMod": .int(7)],
              "settings: unknown-carrier variant keeps its nested member")
        let reEncoded = try hintsJSONEncode(carrier)
        check(reEncoded.contains("futureMod") && !reEncoded.contains("keyCode"),
              "settings: unknown-carrier re-encodes as unknown-only data")
        let reread = try hintsJSONDecode(HintsSettings.self, reEncoded)
        check(reread.activationShortcut?.isAssigned == false, "settings: unknown-only object stays unassigned on decode")
        check(reread.activationShortcut?.extra == ["futureMod": .int(7)],
              "settings: unknown-only members survive the second round-trip")
    }

    // Direct invalid post-init carrier with extras survives as unknown-only data.
    var directInvalid = HintsSettings()
    var poisoned = HintShortcut(keyCode: -1, modifiers: 8)
    poisoned.extra["futureMod"] = .int(7)
    directInvalid.activationShortcut = poisoned
    let directEncoded = try hintsJSONEncode(directInvalid)
    check(directEncoded.contains("futureMod") && !directEncoded.contains("keyCode"),
          "settings: direct invalid post-init carrier emits unknown-only nested data")

    // A later valid assignment merges the preserved nested members without letting
    // unknown values replace known fields; the assigned shortcut's own extras win ties.
    var reborn = try hintsJSONDecode(HintsSettings.self,
        #"{"activationShortcut":{"keyCode":10,"modifiers":0,"futureMod":7}}"#)
    var freshLive = HintShortcut(keyCode: 78, modifiers: 8)
    freshLive.extra["futureMod"] = .int(9)
    reborn.assignShortcut(freshLive)
    check(reborn.activationShortcut?.isAssigned == true, "settings: merged assignment becomes assigned")
    check(reborn.activationShortcut?.extra["futureMod"] == .int(9),
          "settings: merged unknowns prefer the assigned shortcut's own value")
    let rebornEncoded = try hintsJSONEncode(reborn)
    check(rebornEncoded.contains(#""keyCode":78"#) && rebornEncoded.contains("futureMod"),
          "settings: merged carrier emits known fields when and only when assigned")
    var reborn2 = try hintsJSONDecode(HintsSettings.self,
        #"{"activationShortcut":{"keyCode":10,"modifiers":0,"futureMod":7}}"#)
    reborn2.assignShortcut(HintShortcut(keyCode: 78, modifiers: 8))
    check(reborn2.activationShortcut?.extra == ["futureMod": .int(7)],
          "settings: preserved members fill gaps when the assigned shortcut has none")

    // In-range assigned values keep decoding/encoding.
    let inRangeBoundary = try hintsJSONDecode(HintsSettings.self,
        #"{"activationShortcut":{"keyCode":4294967295,"modifiers":8}}"#)
    check(inRangeBoundary.activationShortcut == HintShortcut(keyCode: 4294967295, modifiers: 8),
          "settings: key code at the UInt32 boundary with modifiers is kept")
    check(HintsSettings(activationShortcut: HintShortcut(keyCode: 105, modifiers: 8)).activationShortcut
          == HintShortcut(keyCode: 105, modifiers: 8),
          "settings: direct in-range shortcut with modifiers is stored verbatim")

    // Lenient alphabet: decode accepts only what HintLabelMaker validates.
    check(try hintsJSONDecode(HintsSettings.self, #"{"alphabet":"QWERASDF"}"#).alphabet == "QWERASDF",
          "settings: valid custom alphabet kept as typed")
    check(try hintsJSONDecode(HintsSettings.self, #"{"alphabet":"AA"}"#).alphabet == "ASDFGHJKL",
          "settings: duplicate alphabet decodes to the frozen default")
    check(try hintsJSONDecode(HintsSettings.self, #"{"alphabet":"A1"}"#).alphabet == "ASDFGHJKL",
          "settings: non-letter alphabet decodes to the frozen default")
    check(try hintsJSONDecode(HintsSettings.self, #"{"alphabet":""}"#).alphabet == "ASDFGHJKL",
          "settings: empty alphabet decodes to the frozen default")
    // The same lenience applies in the initializer.
    check(HintsSettings(alphabet: "AA").alphabet == "ASDFGHJKL", "settings: init duplicate alphabet falls back")
    check(HintsSettings(alphabet: "").alphabet == "ASDFGHJKL", "settings: init empty alphabet falls back")
    check(HintsSettings(alphabet: "QWERASDF").alphabet == "QWERASDF", "settings: init valid alphabet kept")
}

// MARK: - AppCore bridge

private func hintsBridgeTests() throws {
    let hintsID = ToolID.hints

    // Identity: no ad hoc raw-value constructions anywhere; the shared constant is the anchor.
    check(hintsID.rawValue == "hints", "bridge: ToolID.hints has the raw value hints")

    // Seeded-empty section: the registry's first-launch seeding writes `{"enabled": ...}`,
    // which must read as "no settings yet" (defaults), never as a corrupt blob.
    var seeded = LineupAppConfig()
    seeded.setEnabled(true, for: hintsID)
    check(try seeded.settings(HintsSettings.self, for: hintsID) == nil,
          "bridge: a seeded-empty hints section reads as no-settings-yet (defaults, no throw)")

    // Defaults: the activation shortcut starts UNASSIGNED (nil, so nothing ever registers).
    check(HintsSettings().activationShortcut == nil,
          "bridge: the default activation shortcut is unassigned (nil)")

    var cfg = LineupAppConfig()
    cfg.setEnabled(true, for: hintsID)
    let settings = HintsSettings(activationShortcut: HintShortcut(keyCode: 55, modifiers: 8), alphabet: "ASDFGHJKL")
    try cfg.setSettings(settings, for: hintsID)
    check(cfg.isEnabled(hintsID) == true, "bridge: setSettings preserves the enabled flag")
    check(try cfg.settings(HintsSettings.self, for: hintsID) == settings, "bridge: settings round-trip through AppCore")

    // setEnabled after setSettings keeps the blob.
    cfg.setEnabled(false, for: hintsID)
    check(try cfg.settings(HintsSettings.self, for: hintsID) == settings, "bridge: setEnabled preserves settings")

    // Unknown top-level fields survive the whole envelope round-trip.
    var withExtra = HintsSettings()
    withExtra.extra["language"] = .string("future")
    var cfg2 = LineupAppConfig()
    try cfg2.setSettings(withExtra, for: hintsID)
    cfg2 = try JSONDecoder().decode(LineupAppConfig.self, from: cfg2.encoded())
    let back = try cfg2.settings(HintsSettings.self, for: hintsID)
    check(back?.extra["language"] == .string("future"), "bridge: unknown settings fields survive the envelope")

    // A newer schema blob fails closed but stays an opaque section.
    let v2Section = #"{"enabled":true,"settings":{"version":99,"alphabet":"ASDFGHJKL"}}"#
    let hostileConfig = #"{"tools":{"hints":\#(v2Section)}}"#
    let blobConfig = try JSONDecoder().decode(LineupAppConfig.self, from: Data(hostileConfig.utf8))
    var threw = false
    do { _ = try blobConfig.settings(HintsSettings.self, for: hintsID) }
    catch let error as HintsSettings.SettingsError {
        if case .unsupportedVersion(99) = error { threw = true }
    } catch {}
    check(threw, "bridge: newer blob version throws unsupportedVersion")
    check(blobConfig.tools["hints"]?.settings == .object([
        "version": .int(99),
        "alphabet": .string("ASDFGHJKL"),
    ]), "bridge: opaque newer blob is preserved untouched after decode")
    let reEncoded = try JSONEncoder().encode(blobConfig)
    let reDecoded = try JSONDecoder().decode(LineupAppConfig.self, from: reEncoded)
    check(reDecoded.tools["hints"]?.settings == blobConfig.tools["hints"]?.settings,
          "bridge: opaque blob re-encodes verbatim")
}

// MARK: - Label maker

private func hintsLabelMakerTests() {
    do {
        // The frozen alphabet: order a, s, d — NOT s/d first.
        let maker = try HintLabelMaker(alphabet: HintLabelMaker.defaultAlphabet)
        check(maker.normalizedAlphabet == Array("asdfghjkl"), "labels: alphabet maps in order")
        check(try maker.labels(candidateCount: 1) == ["a"], "labels: first label is a")
        check(try maker.labels(candidateCount: 9)
            == Array("asdfghjkl").map { String($0) }, "labels: nine single-char labels in alphabet order")
        // Two-char enumeration: aa, as, ..., al, sa.
        let two = try maker.labels(candidateCount: 10)
        check(two[8] == "al", "labels: last first-generation label is al")
        check(two[9] == "sa", "labels: second generation begins sa")
        check(two[0] == "aa" && two[1] == "as", "labels: aa then as")
        // Prefix safety via uniform length.
        check(two.count == 10, "labels: two-char set has the right size")
        let fifty = try maker.labels(candidateCount: 50)
        check(Set(fifty.map(\.count)) == [2], "labels: labels stay uniform in length")
        check(Set(fifty.map { String($0) }).count == 50, "labels: no duplicated labels")
        check(try maker.labels(candidateCount: 82).count == 82, "labels: 82 candidates all labelled (81 two-char cap not hit)")
        // Overflow truncates to the capacity prefix, it never throws.
        let overflow = try maker.allocate(candidateCount: maker.maximumCapacity + 1)
        check(overflow.labels.count == maker.maximumCapacity, "labels: overflow truncates to capacity")
        check(overflow.overflowed == 1, "labels: overflow count reported")

        // Custom alphabet: labels are UNIFORM per generation — 3 candidates with base 2
        // require length 2, so the result is jj, jf, fj (not a variable-length set).
        let custom = try HintLabelMaker(alphabet: "JF", maxLength: 2)
        check(try custom.labels(candidateCount: 3) == ["jj", "jf", "fj"],
              "labels: custom alphabet keeps uniform length across the generation")
        check(try custom.labels(candidateCount: 2) == ["j", "f"],
              "labels: custom alphabet uses length 1 while it fits")
        // Invalid alphabets.
        do { _ = try HintLabelMaker(alphabet: "AA"); check(false, "labels: duplicate alphabet throws") }
        catch { check(true, "labels: duplicate alphabet throws") }
        let defaultMaker = try HintLabelMaker(alphabet: HintLabelMaker.defaultAlphabet)
        check(HintLabelMaker.lenient(alphabet: "A1A").normalizedAlphabet
            == defaultMaker.normalizedAlphabet,
            "labels: lenient falls back to the default alphabet")
    } catch {
        check(false, "labels: suite threw \(error)")
    }
}

// MARK: - Filter and search

private func hintsFilterSearchTests() {
    let labels = ["a", "s", "d", "f"]
    check(HintFilter.visibleIndices(labels: labels, query: "") == [0, 1, 2, 3], "filter: empty query shows all")
    check(HintFilter.visibleIndices(labels: labels, query: "A") == [0], "filter: case-insensitive prefix")
    check(HintFilter.visibleIndices(labels: labels, query: "z").isEmpty, "filter: no match yields nothing")
    check(HintFilter.visibleIndices(labels: ["ss", "sa"], query: "s") == [0, 1], "filter: prefix over two-char labels")

    check(HintFilter.fullLabelSelection(labels: labels, query: "s") == 1, "filter: full label selects")
    check(HintFilter.fullLabelSelection(labels: labels, query: "ss") == nil, "filter: no partial as full match")
    check(HintFilter.fullLabelSelection(labels: labels, query: "") == nil, "filter: empty query never selects")
    check(HintFilter.fullLabelSelection(labels: ["s", "s"], query: "s") == nil,
        "filter: duplicate full labels select nothing")

    let candidates = [
        hintCandidate("0", x: 0, y: 0, title: "Save Document"),
        hintCandidate("1", x: 0, y: 0, label: "save menu"),
        hintCandidate("2", x: 0, y: 0, description: "Saves a copy"),
        hintCandidate("3", x: 0, y: 0, label: "unrelated"),
    ]
    check(HintSearch.orderedIndices(candidates: candidates, query: "save") == [0, 1, 2],
        "search: title wins over label over description")
    check(HintSearch.orderedIndices(candidates: candidates, query: "unrelated") == [3],
        "search: label-only match found")
    check(HintSearch.orderedIndices(candidates: candidates, query: "").count == candidates.count,
        "search: empty query is a full-pass filter")
    check(HintSearch.orderedIndices(candidates: candidates, query: "nothing-matches").isEmpty,
        "search: no matches is empty")
}

// MARK: - Eligibility

private func hintsEligibilityTests() {
    let context = hintsContext()

    // Mode independence: a button and a scroll region are both accepted by the matrix;
    // the keyboard mode decides visibility downstream.
    check(HintEligibility.assess(hintCandidate("b", x: 10, y: 10), context: context) == .accept(.press),
        "eligibility: press-advertised button accepted")
    let region = hintCandidate("r", role: .scrollRegion, actions: [.scroll], x: 10, y: 10)
    check(HintEligibility.assess(region, context: context) == .accept(.scroll),
        "eligibility: scroll region accepted (mode-independent)")

    // Window membership: candidates must carry one of the captured tokens.
    check(HintEligibility.assess(
        hintCandidate("r", role: .scrollRegion, actions: [.scroll], x: 10, y: 10, windowToken: "win-2"),
        context: hintsContext(windowTokens: ["win-1", "win-2"])) == .accept(.scroll),
        "eligibility: secondary captured window token accepted")
    check(HintEligibility.assess(
        hintCandidate("r", role: .scrollRegion, actions: [.scroll], x: 10, y: 10, windowToken: "win-2"),
        context: hintsContext(windowTokens: ["win-1"])) == .reject(.wrongWindow),
        "eligibility: unknown candidate token rejected under a captured window set")
    check(HintEligibility.assess(
        hintCandidate("r", role: .scrollRegion, actions: [.scroll], x: 10, y: 10, windowToken: nil),
        context: hintsContext(windowTokens: ["win-1"])) == .reject(.wrongWindow),
        "eligibility: missing candidate token rejected under a captured window set")

    // PID-level context: with an empty capture set, tokens impose no constraint.
    let pidOnly = hintsContext(windowTokens: [])
    check(HintEligibility.assess(
        hintCandidate("r", role: .scrollRegion, actions: [.scroll], x: 10, y: 10, windowToken: nil),
        context: pidOnly) == .accept(.scroll),
        "eligibility: PID-level context accepts a nil candidate token")
    check(HintEligibility.assess(
        hintCandidate("r", role: .scrollRegion, actions: [.scroll], x: 10, y: 10, windowToken: "anywhere"),
        context: pidOnly) == .accept(.scroll),
        "eligibility: PID-level context accepts any candidate token")

    // Basic rejections.
    check(HintEligibility.assess(hintCandidate("x", pid: 7, x: 10, y: 10), context: context) == .reject(.wrongPID),
        "eligibility: wrong pid rejected")
    check(HintEligibility.assess(hintCandidate("x", x: 10, y: 10, enabled: false), context: context)
        == .reject(.disabled), "eligibility: disabled rejected")
    check(HintEligibility.assess(hintCandidate("x", x: 10, y: 10, visible: false), context: context)
        == .reject(.notVisible), "eligibility: hidden rejected")
    check(HintEligibility.assess(hintCandidate("x", role: .editable, actions: [.focus], x: 10, y: 10, secure: true),
        context: context) == .reject(.secure), "eligibility: secure rejected")
    check(HintEligibility.assess(hintCandidate("x", x: 10, y: 10, onScreen: false), context: context)
        == .reject(.offScreen), "eligibility: off-screen flagged rejected")
    check(HintEligibility.assess(hintCandidate("x", x: 10, y: 10, lineup: true), context: context)
        == .reject(.lineupOwned), "eligibility: Lineup-owned rejected")
    check(HintEligibility.assess(hintCandidate("x", role: .other, actions: [], x: 10, y: 10),
        context: context) == .reject(.noAdvertisedAction),
        "eligibility: unactionable role rejected")
    let overEager = hintCandidate("x", actions: [], x: 10, y: 10)
    check(HintEligibility.assess(overEager, context: context) == .reject(.noAdvertisedAction),
        "eligibility: missing advertised action rejected")
    let focusWithoutFocus = hintCandidate("x", role: .editable, actions: [], x: 10, y: 10)
    check(HintEligibility.assess(focusWithoutFocus, context: context) == .reject(.noAdvertisedAction),
        "eligibility: editable without .focus advertised is rejected")

    // Geometry is validated before eligibility.
    check(HintEligibility.assess(hintCandidate("x", x: 10, y: 10), context: hintsContext(
        screens: [HintRect(x: -1920, y: 0, width: 1000, height: 500)])) == .reject(.offScreen),
        "eligibility: straddling off-screen reject (no display overlap)")
    let nanFrame = HintRect(x: .nan, y: 0, width: 80, height: 24)
    check(HintEligibility.assess(hintCandidate("x", x: 10, y: 10), context: hintsContext())
        == .accept(.press), "eligibility: sanity baseline")
    let nanCandidate = HintCandidate(
        token: HintTargetToken("nan"), pid: 100, windowToken: "win-1", role: .button,
        advertisedActions: [.press], frame: nanFrame)
    check(HintEligibility.assess(nanCandidate, context: context) == .reject(.offScreen),
        "eligibility: non-finite frame maps to offScreen")
    let zeroCandidate = HintCandidate(
        token: HintTargetToken("zero"), pid: 100, windowToken: "win-1", role: .button,
        advertisedActions: [.press], frame: HintRect(x: 0, y: 0, width: 0, height: 24))
    check(HintEligibility.assess(zeroCandidate, context: context) == .reject(.zeroSize),
        "eligibility: non-positive frame maps to zeroSize")

    // Dedupe: only PROVEN ancestry removes a candidate; geometry never does.
    let geometryParent = hintCandidate("p", x: 0, y: 0, width: 200, height: 200)
    let geometryChild = hintCandidate("c", x: 10, y: 10, width: 50, height: 50)
    let geometryKept = HintEligibility.dedupeProvenAncestry([geometryParent, geometryChild])
    check(geometryKept.kept.count == 2, "eligibility: geometry-only nesting is never deduped")

    let ancestryParent = hintCandidate("p", x: 0, y: 0, width: 200, height: 200)
    let ancestryChild = hintCandidate("c", x: 10, y: 10, width: 50, height: 50, ancestors: [HintTargetToken("p")])
    let ancestryKept = HintEligibility.dedupeProvenAncestry([ancestryParent, ancestryChild])
    check(ancestryKept.kept.count == 1 && ancestryKept.kept[0].token.raw == "c",
        "eligibility: proven ancestry keeps the descendant")
    check(ancestryKept.removed == 1, "eligibility: one ancestor removed")

    // Ancestor supplied AFTER the descendant still dedupes (traversal-direction safe).
    let lateKept = HintEligibility.dedupeProvenAncestry([ancestryChild, ancestryParent])
    check(lateKept.kept.count == 1 && lateKept.kept[0].token.raw == "c",
        "eligibility: reverse-order ancestry keeps the descendant")

    // Pools never cross: any scroll region on either side of a proven-ancestry pair keeps
    // both candidates, in both discovery orders.
    let scrollRegionAncestor = hintCandidate("s", role: .scrollRegion, actions: [.scroll], x: 0, y: 0, width: 400, height: 400)
    let innerButton = hintCandidate("b", x: 10, y: 10, width: 50, height: 50, ancestors: [HintTargetToken("s")])
    let scrollAncestorDedupe = HintEligibility.dedupeProvenAncestry([scrollRegionAncestor, innerButton])
    check(scrollAncestorDedupe.kept.count == 2,
        "eligibility: scroll ancestor + normal descendant keeps both")

    let normalAncestor = hintCandidate("b", x: 0, y: 0, width: 400, height: 400)
    let scrollDescendant = hintCandidate("s", role: .scrollRegion, actions: [.scroll], x: 10, y: 10, width: 50, height: 50, ancestors: [HintTargetToken("b")])
    let scrollDescendantDedupe = HintEligibility.dedupeProvenAncestry([normalAncestor, scrollDescendant])
    check(scrollDescendantDedupe.kept.count == 2,
        "eligibility: normal ancestor + scroll descendant keeps both")

    let innerScroll = hintCandidate("s2", role: .scrollRegion, actions: [.scroll], x: 10, y: 10, width: 50, height: 50, ancestors: [HintTargetToken("s")])
    check(HintEligibility.dedupeProvenAncestry([scrollRegionAncestor, innerScroll]).kept.count == 2,
        "eligibility: nested scroll regions retained (ancestor first)")
    check(HintEligibility.dedupeProvenAncestry([innerScroll, scrollRegionAncestor]).kept.count == 2,
        "eligibility: nested scroll regions retained (descendant first)")
    check(HintEligibility.dedupeProvenAncestry([innerButton, scrollRegionAncestor]).kept.count == 2,
        "eligibility: scroll ancestor + normal descendant keeps both (reverse order)")

    // Rank order (display, then y, then x, then token) and candidate cap.
    let rankedInput = [
        hintCandidate("late", x: 500, y: 10),
        hintCandidate("west", x: 100, y: 10),
        hintCandidate("east", x: 300, y: 10),
        hintCandidate("north", x: 0, y: 0),
    ]
    let ranked = HintEligibility.prepare(rankedInput, context: context,
                                         limits: HintScanLimits(maxCandidates: 2))
    check(ranked.ranked.map { $0.candidate.token.raw } == ["north", "west"],
        "eligibility: ranked order is top-left first, capped from the tail")
    check(ranked.candidateCapReached, "eligibility: candidate cap reported")
    check(ranked.acceptedCandidates == 4, "eligibility: accepted count reflects the pre-cap pool")

    let uncapped = HintEligibility.prepare(rankedInput, context: context, limits: .standard)
    check(uncapped.ranked.map { $0.candidate.token.raw } == ["north", "west", "east", "late"],
        "eligibility: uncapped rank keeps reading order")
    check(!uncapped.candidateCapReached, "eligibility: no cap reason without a cap")

    // Count contract: accepted = after eligibility AND ancestry dedupe, before cap.
    let dedupePrepared = HintEligibility.prepare(
        [normalAncestor, ancestryParent, ancestryChild], context: context, limits: .standard)
    check(dedupePrepared.acceptedCandidates == 2,
        "eligibility: accepted count is post-dedupe (descendant + unrelated control)")
    check(dedupePrepared.ranked.count == 2, "eligibility: no cap, ranked keeps both survivors")
}

// MARK: - Geometry

private func hintsGeometryTests() {
    let screens = hintsScreensDefault
    check(HintOverlayGeometry.displayIndex(for: HintRect(x: 100, y: 100, width: 50, height: 50), screens: screens) == 0,
        "geometry: main display wins")
    check(HintOverlayGeometry.displayIndex(for: HintRect(x: -1000, y: 100, width: 50, height: 50), screens: screens) == 1,
        "geometry: negative-origin display wins there")
    check(HintOverlayGeometry.displayIndex(for: HintRect(x: 1900, y: 0, width: 40, height: 40), screens: screens) == 0,
        "geometry: partial overlap keeps its best display")
    check(HintOverlayGeometry.displayIndex(for: HintRect(x: 5000, y: 5000, width: 40, height: 40), screens: screens) == nil,
        "geometry: disjoint frame has no display")
    check(HintOverlayGeometry.displayIndex(for: HintRect.zero, screens: screens) == nil,
        "geometry: empty frame has no display")
    // Tie on equal area keeps the lowest display index.
    let tieScreens = [HintRect(x: 0, y: 0, width: 100, height: 100), HintRect(x: 10, y: 0, width: 100, height: 100)]
    check(HintOverlayGeometry.displayIndex(for: HintRect(x: 10, y: 0, width: 90, height: 100), screens: tieScreens) == 0,
        "geometry: tie keeps the lowest display index")

    // Validity classification.
    check(HintOverlayGeometry.validity(of: HintRect(x: 1, y: 2, width: 3, height: 4)) == .valid,
        "geometry: valid frame classified valid")
    check(HintOverlayGeometry.validity(of: HintRect(x: 1, y: 2, width: 0, height: 3)) == .nonPositiveSize,
        "geometry: zero-size classified nonpositive")
    check(HintOverlayGeometry.validity(of: HintRect(x: .infinity, y: 2, width: 3, height: 4)) == .nonFinite,
        "geometry: infinite origin classified nonfinite")

    let clamps = HintOverlayGeometry.clampedInside(HintRect(x: -5, y: -5, width: 40, height: 30),
                                                   in: HintRect(x: 0, y: 0, width: 100, height: 100))
    check(clamps == HintRect(x: 0, y: 0, width: 40, height: 30), "geometry: clamped inside keeps size")
    let shrunk = HintOverlayGeometry.clampedInside(HintRect(x: 0, y: 0, width: 500, height: 50),
                                                   in: HintRect(x: 0, y: 0, width: 100, height: 100))
    check(shrunk.width == 100, "geometry: oversized frame shrinks to bounds")
    let anchor = HintOverlayGeometry.labelAnchor(for: HintRect(x: 5, y: 5, width: 40, height: 20),
                                                 in: HintRect(x: 0, y: 0, width: 100, height: 100))
    check(anchor == HintPoint(x: 7, y: 7), "geometry: anchor at inset")
    let anchored = HintOverlayGeometry.labelAnchor(for: HintRect(x: -50, y: -50, width: 40, height: 20),
                                                   in: HintRect(x: 0, y: 0, width: 100, height: 100))
    check(anchored == HintPoint(x: 2, y: 2), "geometry: anchor clamps to display inset")
}

// MARK: - Reducer session lifecycle

private func hintsReducerSessionTests() {
    // Activation → scanning → presenting (show + modifier barrier).
    var reducer = hintsNormalReducer()
    let activateEffects = reducer.send(.activateRequested(hintsContext()))
    check(activateEffects.count == 1, "lifecycle: activation emits one effect")
    guard case .startScan(let plan)? = activateEffects.first,
          case .scanning(let scanningPlan, _) = reducer.state else {
        check(false, "lifecycle: activation starts a scan")
        return
    }
    check(scanningPlan.context == hintsContext(), "lifecycle: scanning carries the context")
    check(plan.key == scanningPlan.key, "lifecycle: plan key matches the state")
    check(plan.key.generation == 0, "lifecycle: first generation starts at zero")

    let candidates = (0..<3).map { offset in
        hintCandidate("tok-\(offset)", x: Double(offset) * 100, y: 200, title: ["Save", "Cancel", "Open"][offset])
    }
    let presentingEffects = reducer.send(.scanCompleted(plan.key, HintScanResult(candidates: candidates)))
    check(presentingEffects.count == 2, "lifecycle: presenting emits show + barrier")
    guard case .showOverlays(let shownKey, let snapshot)? = presentingEffects.first else {
        check(false, "lifecycle: first presenting effect is showOverlays")
        return
    }
    check(shownKey == plan.key, "lifecycle: showOverlays carries the session key")
    check(snapshot.visible.count == 3, "lifecycle: all three candidates visible")
    check(snapshot.selectedToken == nil, "lifecycle: nothing selected on entry")
    check(snapshot.query.isEmpty, "lifecycle: entry query empty")
    check(snapshot.truncated == false, "lifecycle: fresh scan not truncated")

    let barrierEffects = reducer.send(.key(.modifierBarrierReleased))
    check(barrierEffects == [.beginInput(plan.key)], "lifecycle: barrier releases into beginInput")

    // Keys before the barrier are dropped except Escape.
    var preBarrier = hintsNormalReducer()
    _ = hintsPresentThree(&preBarrier)
    check(preBarrier.send(.key(.character("a"))).isEmpty, "lifecycle: typing during the barrier is dropped")
    check(preBarrier.send(.key(.escape)).count == 2, "lifecycle: escape works during the barrier")
    check(preBarrier.state == .idle, "lifecycle: escape during the barrier cancels")
}

// MARK: - Release routing (generation vs session)

private func hintsReducerReleaseRoutingTests() {
    // Repeated activation: terminal teardown of the whole session (never a generation
    // release), so the replacement cannot reuse stale target payloads or roots.
    var reducer = hintsNormalReducer()
    let key = hintsPresentThree(&reducer)
    _ = reducer.send(.key(.modifierBarrierReleased))
    let repeated = reducer.send(.activateRequested(hintsContext(pid: 300)))
    check(repeated == [.hideOverlays(key), .releaseSession(key)],
          "release: repeated activation releases the whole old session")
    check(reducer.state == .idle, "release: repeated activation goes idle first")

    // Terminal cancellation via a cancel reason also releases the whole session.
    let secondKey = hintsPresentThree(&reducer)
    let cancel = reducer.send(.cancel(.toolDisabled))
    check(cancel == [.hideOverlays(secondKey), .releaseSession(secondKey)],
          "release: terminal cancellation releases the whole session")
    check(reducer.state == .idle, "release: terminal cancellation ends idle")

    // A stale keyed async event (foreign key, session long gone) drains only that payload
    // as a generation release — never resurrects or releases any live session.
    var scanning = hintsNormalReducer()
    _ = scanning.send(.activateRequested(hintsContext(pid: 400)))
    let liveScanKey = hintsAsScanning(scanning).key
    let foreignKey = HintSessionKey(id: liveScanKey.id - 1, generation: 3)
    let staleEvent = scanning.send(.scanCompleted(foreignKey, HintScanResult(candidates: [])))
    check(staleEvent == [.releaseGeneration(foreignKey)],
          "release: stale foreign payload cleaned up as a generation release")
    if case .scanning = scanning.state {} else {
        check(false, "release: live scan untouched by a stale result")
        return
    }

    // Generation rollover from a scroll rescan: only the PRIOR generation is released;
    // no session-root release rides the rollover.
    var rolling = hintsNormalReducer()
    let regionFixture: (String) -> HintCandidate = {
        hintCandidate($0, pid: 500, role: .scrollRegion, actions: [.scroll], x: 0, y: 0, width: 800, height: 600,
                      continuity: HintContinuityID("cont-roll"))
    }
    _ = rolling.send(.activateRequested(hintsContext(pid: 500)))
    let rollKey = hintsAsScanning(rolling).key
    _ = rolling.send(.scanCompleted(rollKey, HintScanResult(
        candidates: [regionFixture("region-r"), hintCandidate("button-b", pid: 500, x: 0, y: 700, title: "Save")],
        summary: HintScanSummary(discoveredCandidates: 2))))
    _ = rolling.send(.key(.modifierBarrierReleased))
    _ = rolling.send(.key(.space))
    _ = rolling.send(.key(.character("a")))
    _ = rolling.send(.key(.scroll(.down)))
    let unknownOutcome = rolling.send(.scrollFinished(rollKey, .unknownOutcome))
    guard case .releaseGeneration(let releasedGen)? = unknownOutcome.first,
          case .startScan(let rolloverPlan)? = unknownOutcome.last else {
        check(false, "release: rollover emits generation release then scan")
        return
    }
    check(releasedGen == rollKey, "release: rollover releases only the prior generation")
    check(rolloverPlan.key.id == rollKey.id && rolloverPlan.key.generation == 1,
          "release: rollover continues the same session under a new generation")
    check(!unknownOutcome.contains { if case .releaseSession = $0 { return true }; return false },
          "release: rollover never releases the immutable session roots")
    // A stale scroll landing for the replaced generation drains only that generation's
    // payload; the live rescan keeps waiting.
    let staleScroll = rolling.send(.scrollFinished(rollKey, .applied))
    check(staleScroll == [.releaseGeneration(rollKey)],
          "release: stale scroll payload drains as a generation release")
    if case .scanning = rolling.state {} else { check(false, "release: rescan survives stale scroll") }

    // At-most-once invocation: after success, a duplicate finished event for the same key
    // is stale and drains idempotently as a generation release (nothing else re-fires).
    var invoking = hintsNormalReducer()
    let invokeKey = hintsPresentThree(&invoking)
    _ = invoking.send(.key(.modifierBarrierReleased))
    _ = invoking.send(.key(.character("a")))
    _ = invoking.send(.key(.return))
    if case .invoking = invoking.state {} else { check(false, "release: invoking precondition failed"); return }
    let succeeded = invoking.send(.invocationFinished(invokeKey, .succeeded))
    check(succeeded == [.releaseSession(invokeKey)], "release: success releases the whole session")
    check(invoking.state == .idle, "release: success ends idle")
    let duplicateFinish = invoking.send(.invocationFinished(invokeKey, .succeeded))
    check(duplicateFinish == [.releaseGeneration(invokeKey)],
          "release: duplicate invocationFinished drains exactly once as a stale generation")
    check(invoking.state == .idle, "release: duplicate finished does not resurrect")

    // Left/right scroll commands: routed verbatim to scrollRegion like up/down; an
    // additional command while one scroll is in flight is still dropped.
    var scroller = hintsNormalReducer()
    _ = scroller.send(.activateRequested(hintsContext(pid: 500)))
    let scrollKey = hintsAsScanning(scroller).key
    _ = scroller.send(.scanCompleted(scrollKey, HintScanResult(
        candidates: [regionFixture("region-lr")],
        summary: HintScanSummary(discoveredCandidates: 1))))
    _ = scroller.send(.key(.modifierBarrierReleased))
    _ = scroller.send(.key(.space))
    _ = scroller.send(.key(.character("a")))
    let left = scroller.send(.key(.scroll(.left)))
    check(left == [.scrollRegion(scrollKey, HintTargetToken("region-lr"), .left)],
          "commands: left routes to the selected scroll region")
    check(scroller.send(.key(.scroll(.right))).isEmpty, "commands: in-flight right is dropped")
    check(scroller.send(.key(.character("a"))).isEmpty, "commands: typing stays dropped during flight")
    // Applied lands the left scroll; the rescan re-enters scroll mode with the selection,
    // then a right command routes under the SAME session with an advanced generation.
    _ = scroller.send(.scrollFinished(scrollKey, .applied))
    _ = scroller.send(.scanCompleted(HintSessionKey(id: scrollKey.id, generation: 1), HintScanResult(
        candidates: [regionFixture("region-lr-rebuilt")],
        summary: HintScanSummary(discoveredCandidates: 1))))
    let presentingAfter = hintsAsPresenting(scroller)
    check(presentingAfter.mode == .scroll && presentingAfter.selectedIndex != nil,
          "commands: left scroll restores its selection by continuity")
    let right = scroller.send(.key(.scroll(.right)))
    check(right == [.scrollRegion(HintSessionKey(id: scrollKey.id, generation: 1),
                                  HintTargetToken("region-lr-rebuilt"), .right)],
          "commands: right routes to the restored selection under the new generation")

    // Left/right serialize through JSON like every other command member.
    for command in HintScrollCommand.allCases {
        let raw = try? hintsJSONDecode(HintScrollCommand.self, "\"\(command.rawValue)\"")
        check(raw == command, "commands: \(command.rawValue) round-trips through JSON")
    }
    check(HintScrollCommand.allCases.contains(.left) && HintScrollCommand.allCases.contains(.right),
          "commands: allCases covers left and right")
}

private func hintsReducerModesTests() {
    var reducer = hintsNormalReducer()
    let key = hintsPresentThree(&reducer)
    _ = reducer.send(.key(.modifierBarrierReleased))

    // Labels mode: typing an alphabet key filters and full labels select.
    let typedA = reducer.send(.key(.character("a")))
    if case .refreshOverlays(_, let snap) = typedA.first {
        check(snap.visible.count == 1, "modes: a filters down to the a-labelled candidate")
        check(snap.selectedToken?.raw == "tok-0", "modes: full label 'a' selects its candidate")
        check(snap.mode == .labels, "modes: still in labels mode")
        check(snap.selectedToken == snap.visible.first?.candidate.token,
              "modes: snapshot selection equals the Return target")
    } else {
        check(false, "modes: typing emits a refresh")
    }

    // Return invokes the selection exactly once.
    let returnEffects = reducer.send(.key(.return))
    check(returnEffects.count == 2, "modes: return hides overlays and invokes")
    guard case .invoke(let invokeKey, let token, let action)? = returnEffects.last else {
        check(false, "modes: return invokes")
        return
    }
    check(invokeKey == key, "modes: invoke carries the session key")
    check(token.raw == "tok-0", "modes: the selected token is invoked")
    check(action == .press, "modes: press is the dispatched action")
    if case .invoking = reducer.state {} else { check(false, "modes: invoking state entered") }

    // Successful invocation ends the session cleanly.
    let succeedEffects = reducer.send(.invocationFinished(key, .succeeded))
    check(succeedEffects == [.releaseSession(key)], "modes: success releases the whole session")
    check(reducer.state == .idle, "modes: success ends the session idle")

    // Multi-char queries: typing continues filtering; non-alphabet keys are ignored.
    var reducer2 = hintsNormalReducer()
    _ = hintsPresentThree(&reducer2)
    _ = reducer2.send(.key(.modifierBarrierReleased))
    _ = reducer2.send(.key(.character("s")))
    check(reducer2.send(.key(.character("z"))).isEmpty, "modes: non-alphabet characters do not extend the query")

    let back = reducer2.send(.key(.backspace))
    if case .refreshOverlays(_, let snapBack) = back.first {
        check(snapBack.query.isEmpty, "modes: backspace clears the last typed character")
        check(snapBack.selectedToken == nil && snapBack.visible.count == 3, "modes: empty query shows all unselected")
    } else {
        check(false, "modes: backspace refreshes")
    }
    check(reducer2.send(.key(.return)).isEmpty, "modes: return with an empty query is inert")

    // Slash enters search; empty search query selects nothing and Return stays inert.
    let toSearch = reducer2.send(.key(.slash))
    if case .refreshOverlays(_, let searchSnap) = toSearch.first {
        check(searchSnap.mode == .search, "modes: slash enters search")
        check(searchSnap.selectedToken == nil, "modes: empty search query selects nothing")
        check(searchSnap.visible.count == 3, "modes: empty search shows the whole normal pool")
    } else {
        check(false, "modes: slash refreshes into search")
    }
    check(reducer2.send(.key(.return)).isEmpty, "modes: search Return with an empty query is inert")

    // Search with text binds the FIRST visible result; snapshot selection equals it.
    _ = reducer2.send(.key(.character("s")))
    let typed = reducer2.send(.key(.character("a")))
    if case .refreshOverlays(_, let searched) = typed.first {
        check(searched.query == "sa", "modes: search accumulates text")
        check(searched.visible.map { $0.candidate.token.raw } == ["tok-0"],
              "modes: search matches the Save title first")
        check(searched.selectedToken == searched.visible.first?.candidate.token,
              "modes: search selection equals its first result")
    } else {
        check(false, "modes: search typing refreshes")
    }
    let searchReturn = reducer2.send(.key(.return))
    guard case .invoke(_, let searchToken, .press)? = searchReturn.last else {
        check(false, "modes: search Return invokes the first result")
        return
    }
    check(searchToken.raw == "tok-0", "modes: search Return targets the bound selection")
    _ = reducer2.send(.invocationFinished(hintsAsInvoking(reducer2).key, .succeeded))

    // Backspace to empty exits search back to labels; both edges are safe.
    var reducer3 = hintsNormalReducer()
    _ = hintsPresentThree(&reducer3)
    _ = reducer3.send(.key(.modifierBarrierReleased))
    _ = reducer3.send(.key(.slash))
    // Edge 1: backspace on an ALREADY-EMPTY search query exits without trapping.
    let emptySearchBackspace = reducer3.send(.key(.backspace))
    if case .refreshOverlays(_, let emptyExit) = emptySearchBackspace.first {
        check(emptyExit.mode == .labels && emptyExit.query.isEmpty,
              "modes: backspace on an empty search query exits to labels with an empty query")
        check(emptyExit.selectedToken == nil, "modes: empty-search backspace clears any selection")
        check(emptyExit.visible.count == 3, "modes: labels pool restored after the safe exit")
    } else {
        check(false, "modes: empty-search backspace refreshes")
    }
    // Re-enter search and trim the final character.
    _ = reducer3.send(.key(.slash))
    _ = reducer3.send(.key(.character("s")))
    let exited = reducer3.send(.key(.backspace))
    if case .refreshOverlays(_, let labelsSnap) = exited.first {
        check(labelsSnap.mode == .labels && labelsSnap.query.isEmpty,
              "modes: removing the final search character exits to labels cleanly")
        check(labelsSnap.selectedToken == nil && labelsSnap.visible.count == 3,
              "modes: final-character backspace ends with the empty label pool, no selection")
    } else {
        check(false, "modes: exiting search refreshes")
    }

    // Space enters scroll mode; with no regions the pool is empty and Return stays inert.
    let toScroll = reducer3.send(.key(.space))
    if case .refreshOverlays(_, let scrollSnap) = toScroll.first {
        check(scrollSnap.mode == .scroll, "modes: space enters scroll mode")
        check(scrollSnap.visible.isEmpty, "modes: scroll pool with no regions is empty and safe")
    } else {
        check(false, "modes: space refreshes into scroll")
    }
    check(reducer3.send(.key(.return)).isEmpty, "modes: no sole-result auto-invoke anywhere")
}

private func hintsReducerScrollTests() {
    var reducer = hintsNormalReducer()
    let continuityRegion = HintContinuityID("cont-region")
    let button = hintCandidate("button-1", x: 10, y: 700, title: "Save")
    func regionFixture(_ token: String, continuity: HintContinuityID?, y: Double = 0) -> HintCandidate {
        hintCandidate(token, role: .scrollRegion, actions: [.scroll], x: 0, y: y, width: 800, height: 600,
                      continuity: continuity)
    }

    // Rank: region (y=0) precedes the button (y=700) → region label 'a', button label 's'.
    _ = reducer.send(.activateRequested(hintsContext()))
    let key = hintsAsScanning(reducer).key
    _ = reducer.send(.scanCompleted(key, HintScanResult(
        candidates: [regionFixture("region-1", continuity: continuityRegion), button],
        summary: HintScanSummary(discoveredCandidates: 2))))
    _ = reducer.send(.key(.modifierBarrierReleased))

    // Space enters scroll mode; only regions are visible.
    let toScroll = reducer.send(.key(.space))
    if case .refreshOverlays(_, let snap) = toScroll.first {
        check(snap.mode == .scroll, "scroll: space enters scroll mode")
        check(snap.visible.count == 1 && snap.visible[0].candidate.role == .scrollRegion,
              "scroll: only the region is visible")
    } else {
        check(false, "scroll: space refreshes")
        return
    }

    // Select the region by its label (single region → 'a') and scroll.
    _ = reducer.send(.key(.character("a")))
    let scrollDown = reducer.send(.key(.scroll(.down)))
    check(scrollDown.count == 1, "scroll: entering flight emits exactly one scrollRegion effect")
    guard case .scrollRegion(let scrollKey, let token, let command)? = scrollDown.first else {
        check(false, "scroll: scrollRegion effect emitted")
        return
    }
    check(scrollKey == key, "scroll: scroll carries the session key")
    check(token.raw == "region-1", "scroll: the selected region scrolls")
    check(command == .down, "scroll: the semantic command carries")
    if case .scrolling = reducer.state {} else { check(false, "scroll: scrolling state entered") }
    let scrolling = hintsAsScrolling(reducer)
    check(scrolling.selectedIndex != nil, "scroll: selection carried into flight")

    // An additional command while in flight is ignored (never queued).
    check(reducer.send(.key(.scroll(.up))).isEmpty, "scroll: in-flight command dropped")
    check(reducer.send(.key(.character("a"))).isEmpty, "scroll: typing during flight dropped")

    // Applied → release old BEFORE start new, rescan re-enters scroll mode.
    let applied = reducer.send(.scrollFinished(key, .applied))
    check(applied.count == 2, "scroll: applied emits release + scan")
    if case .releaseGeneration(let released) = applied.first {
        check(released == key, "scroll: old generation released first")
    } else {
        check(false, "scroll: release precedes the rescan")
    }
    guard case .startScan(let rescanPlan)? = applied.last else {
        check(false, "scroll: rescan follows the release")
        return
    }
    check(rescanPlan.key.id == key.id && rescanPlan.key.generation == 1,
          "scroll: rescan advances the generation")
    if case .scanning(let planAfter, let resumeAfter) = reducer.state, let resume = resumeAfter {
        check(planAfter.key == rescanPlan.key, "scroll: state waits on the new generation")
        check(resume.mode == .scroll, "scroll: rescan resumes scroll mode")
        check(resume.selectedContinuity == continuityRegion,
              "scroll: the flight carries the selected candidate's continuity identity")
    } else {
        check(false, "scroll: rescan carries a scroll resume")
    }

    // Completing the rescan restores the selection by CONTINUITY, not by the generation-
    // bound target token: the rebuilt region has a NEW token and the same proven continuity.
    _ = reducer.send(.scanCompleted(HintSessionKey(id: key.id, generation: 1), HintScanResult(
        candidates: [regionFixture("region-1-rebuilt", continuity: continuityRegion), button],
        summary: HintScanSummary(discoveredCandidates: 2))))
    let presentingAgain = hintsAsPresenting(reducer)
    check(presentingAgain.mode == .scroll, "scroll: resumed into scroll mode after rescan")
    check(presentingAgain.selectedIndex != nil, "scroll: same continuity with a NEW token restores")
    check(presentingAgain.candidates[presentingAgain.selectedIndex!].candidate.token.raw == "region-1-rebuilt",
          "scroll: the restored selection binds the freshly minted token")
    check(!presentingAgain.awaitingModifierRelease, "scroll: no second modifier barrier")

    // Reused target token with DIFFERENT continuity must NOT restore: scroll again,
    // rescan, and present a re-badged candidate holding the same token string.
    let secondFlight = reducer.send(.key(.scroll(.pageDown)))
    if case .scrollRegion? = secondFlight.first {} else { check(false, "scroll: second flight launches") }
    let unknown = reducer.send(.scrollFinished(HintSessionKey(id: key.id, generation: 1), .unknownOutcome))
    if case .releaseGeneration? = unknown.first, case .startScan(let thirdPlan)? = unknown.last {
        check(thirdPlan.key.generation == 2, "scroll: unknown outcome still rescans")
    } else {
        check(false, "scroll: unknown outcome release+rescan shape")
    }
    _ = reducer.send(.scanCompleted(HintSessionKey(id: key.id, generation: 2), HintScanResult(
        candidates: [regionFixture("region-1-rebuilt", continuity: HintContinuityID("cont-zombie")), button],
        summary: HintScanSummary(discoveredCandidates: 2))))
    let zombie = hintsAsPresenting(reducer)
    check(zombie.selectedIndex == nil, "scroll: reused target token with different continuity does not restore")

    // A stale scrollFinished (an old generation) releases only the stale payload.
    let stale = reducer.send(.scrollFinished(key, .applied))
    check(stale == [.releaseGeneration(key)], "scroll: stale generation payload released idempotently")

    // Absent continuity never restores (independent mini session).
    var absent = hintsNormalReducer()
    _ = absent.send(.activateRequested(hintsContext()))
    let absentKey = hintsAsScanning(absent).key
    _ = absent.send(.scanCompleted(absentKey, HintScanResult(
        candidates: [regionFixture("region-1", continuity: nil), button],
        summary: HintScanSummary(discoveredCandidates: 2))))
    _ = absent.send(.key(.modifierBarrierReleased))
    _ = absent.send(.key(.space))
    _ = absent.send(.key(.character("a")))
    _ = absent.send(.key(.scroll(.down)))
    let absentApplied = absent.send(.scrollFinished(absentKey, .applied))
    if case .startScan(let absentPlan)? = absentApplied.last {
        check(absentPlan.key.generation == 1, "scroll: absent-continuity rescan runs")
    }
    _ = absent.send(.scanCompleted(HintSessionKey(id: absentKey.id, generation: 1), HintScanResult(
        candidates: [regionFixture("region-2", continuity: nil), button],
        summary: HintScanSummary(discoveredCandidates: 2))))
    check(hintsAsPresenting(absent).selectedIndex == nil,
          "scroll: absent continuity does not restore across generations")

    // A failed scroll cancels the session.
    var failing = hintsNormalReducer()
    _ = failing.send(.activateRequested(hintsContext()))
    let failingKey = hintsAsScanning(failing).key
    _ = failing.send(.scanCompleted(failingKey, HintScanResult(
        candidates: [regionFixture("region-1", continuity: continuityRegion), button],
        summary: HintScanSummary(discoveredCandidates: 2))))
    _ = failing.send(.key(.modifierBarrierReleased))
    _ = failing.send(.key(.space))
    _ = failing.send(.key(.character("a")))
    _ = failing.send(.key(.scroll(.home)))
    if case .scrolling = failing.state {} else { check(false, "scroll: in flight again") }
    let failed = failing.send(.scrollFinished(failingKey, .failed))
    check(failed.count == 2, "scroll: failed scroll cleans up")
    guard case .hideOverlays? = failed.first, case .releaseSession? = failed.last else {
        check(false, "scroll: failed scroll hides and releases")
        return
    }
    check(failing.state == .idle, "scroll: failed scroll ends the session")

    // Scroll exit regression: Space leaving scroll mode leaks nothing into labels mode.
    var exiting = hintsNormalReducer()
    _ = exiting.send(.activateRequested(hintsContext()))
    let exitKey = hintsAsScanning(exiting).key
    _ = exiting.send(.scanCompleted(exitKey, HintScanResult(
        candidates: [regionFixture("region-1", continuity: continuityRegion), button],
        summary: HintScanSummary(discoveredCandidates: 2))))
    _ = exiting.send(.key(.modifierBarrierReleased))
    _ = exiting.send(.key(.space))
    _ = exiting.send(.key(.character("a")))
    check(hintsAsPresenting(exiting).query == "a", "scroll: the scroll query is nonempty before the exit")
    let exit = exiting.send(.key(.space))
    if case .refreshOverlays(_, let labels) = exit.first {
        check(labels.mode == .labels, "scroll exit: lands in labels mode")
        check(labels.query.isEmpty, "scroll exit: the scroll query does not leak into labels mode")
        check(labels.selectedToken == nil, "scroll exit: no selection leaks out of scroll mode")
        check(labels.visible.count == 1,
              "scroll exit: normal controls show unfiltered (region hidden in labels mode)")
    } else {
        check(false, "scroll exit: space refreshes into labels")
    }

    // Scroll-mode prefix filtering: the region pool narrows exactly like the labels pool,
    // and the selection is always part of the filtered visible set.
    var filtering = hintsNormalReducer()
    _ = filtering.send(.activateRequested(hintsContext()))
    let filterKey = hintsAsScanning(filtering).key
    let topRegion = regionFixture("region-a", continuity: nil)
    let lowerRegion = regionFixture("region-s", continuity: nil, y: 200)
    _ = filtering.send(.scanCompleted(filterKey, HintScanResult(
        candidates: [topRegion, lowerRegion, button],
        summary: HintScanSummary(discoveredCandidates: 3))))
    _ = filtering.send(.key(.modifierBarrierReleased))
    let enterScroll = filtering.send(.key(.space))
    if case .refreshOverlays(_, let emptyQuerySnap) = enterScroll.first {
        check(emptyQuerySnap.visible.count == 2, "scroll filter: both regions visible with an empty query")
    } else {
        check(false, "scroll filter: space refreshes")
    }
    _ = filtering.send(.key(.character("a")))
    let narrowed = hintsAsPresenting(filtering)
    check(narrowed.query == "a", "scroll filter: query carried")
    check(narrowed.selectedIndex != nil, "scroll filter: the exact label selects its region")
    let filteredSnap = filtering.snapshot(hintsAsPresenting(filtering))
    check(filteredSnap.visible.count == 1 && filteredSnap.visible[0].candidate.token.raw == "region-a",
          "scroll filter: only the region whose label has the query prefix stays visible")
    check(filteredSnap.selectedToken?.raw == "region-a",
          "scroll filter: the selection is inside the filtered visible pool")

    // Same continuity but a CHANGED LABEL must not restore: the selection binds to the
    // exact current full-label match, with no fallback.
    var relabeled = hintsNormalReducer()
    _ = relabeled.send(.activateRequested(hintsContext()))
    let relabelKey = hintsAsScanning(relabeled).key
    let secondButton = hintCandidate("button-1", x: 10, y: 0, title: "Save")
    let midRegion = regionFixture("region-1", continuity: continuityRegion, y: 100)
    _ = relabeled.send(.scanCompleted(relabelKey, HintScanResult(
        candidates: [secondButton, midRegion],
        summary: HintScanSummary(discoveredCandidates: 2))))
    _ = relabeled.send(.key(.modifierBarrierReleased))
    _ = relabeled.send(.key(.space))
    _ = relabeled.send(.key(.character("s")))
    check(hintsAsPresenting(relabeled).selectedIndex != nil, "scroll relabel: the region 's' is selected")
    _ = relabeled.send(.key(.scroll(.down)))
    let relabelApplied = relabeled.send(.scrollFinished(relabelKey, .applied))
    check(relabelApplied.contains { if case .startScan = $0 { return true }; return false },
          "scroll relabel: the rescan launches")
    // The rebuilt generation ranks the region FIRST, so its label becomes 'a'; the resumed
    // query is still "s", and nothing may restore that continuity identity.
    _ = relabeled.send(.scanCompleted(HintSessionKey(id: relabelKey.id, generation: 1), HintScanResult(
        candidates: [regionFixture("region-1-rebuilt", continuity: continuityRegion), secondButton],
        summary: HintScanSummary(discoveredCandidates: 2))))
    let relabeledPresenting = hintsAsPresenting(relabeled)
    check(relabeledPresenting.mode == .scroll, "scroll relabel: still presenting scroll")
    check(relabeledPresenting.selectedIndex == nil,
          "scroll relabel: same continuity with a changed label never restores")
    let relabeledSnap = relabeled.snapshot(hintsAsPresenting(relabeled))
    check(relabeledSnap.selectedToken == nil,
          "scroll relabel: no selection leaks into the snapshot")
}

private func hintsReducerCancellationTests() {
    var reducer = hintsNormalReducer()
    let key = hintsPresentThree(&reducer)
    check(key.generation == 0, "cancellation: precondition generation")
    _ = reducer.send(.key(.modifierBarrierReleased))

    // Escape cancels cleanly.
    let escape = reducer.send(.key(.escape))
    check(escape == [.hideOverlays(key), .releaseSession(key)], "cancellation: escape hides and releases")
    check(reducer.state == .idle, "cancellation: escape goes idle")

    // Stale keyed events after the session released release nothing extra aside from drains.
    let staleScan = reducer.send(.scanCompleted(key, HintScanResult(candidates: [])))
    check(staleScan == [.releaseGeneration(key)], "cancellation: stale generation payload released idempotently")
    check(reducer.state == .idle, "cancellation: stale events do not resurrect a session")

    // A stale event from a DIFFERENT key also just drains.
    let otherKey = HintSessionKey(id: key.id + 1, generation: 0)
    check(reducer.send(.invocationFinished(otherKey, .succeeded)) == [.releaseGeneration(otherKey)],
          "cancellation: foreign stale invocation drained")
    // A duplicate event for the LIVE key releases nothing.
    var liveReducer = hintsNormalReducer()
    let liveKey = hintsPresentThree(&liveReducer)
    // Presenting when a duplicate scan-completed arrives: live key, no release.
    let duplicate = liveReducer.send(.scanCompleted(liveKey, HintScanResult(candidates: [], summary: HintScanSummary())))
    check(duplicate.isEmpty, "cancellation: duplicate event for the live key releases nothing")

    // Repeated activation cancels the running session.
    let repeated = liveReducer.send(.activateRequested(hintsContext(pid: 200)))
    guard case .idle = liveReducer.state else { check(false, "cancellation: repeated activation cancels"); return }
    check(repeated == [.hideOverlays(liveKey), .releaseSession(liveKey)],
          "cancellation: repeated activation tears down the old session")

    // Unknown invocation outcomes never retry; they rescan observably.
    var unknownReducer = hintsNormalReducer()
    let unknownKey = hintsPresentThree(&unknownReducer)
    _ = unknownReducer.send(.key(.modifierBarrierReleased))
    _ = unknownReducer.send(.key(.character("a")))
    _ = unknownReducer.send(.key(.return))
    if case .invoking = unknownReducer.state {} else { check(false, "cancellation: invoking precondition") }
    let unknown = unknownReducer.send(.invocationFinished(unknownKey, .unknownOutcome))
    guard case .releaseGeneration? = unknown.first, case .startScan(let afterUnknown)? = unknown.last else {
        check(false, "cancellation: unknown outcome rescan shape")
        return
    }
    check(afterUnknown.key.generation == 1, "cancellation: unknown outcome rescan generation advanced")

    // Failed invocation ends the session without a retry.
    var failedReducer = hintsNormalReducer()
    let failedKey = hintsPresentThree(&failedReducer)
    _ = failedReducer.send(.key(.modifierBarrierReleased))
    _ = failedReducer.send(.key(.character("d")))
    _ = failedReducer.send(.key(.return))
    let failed = failedReducer.send(.invocationFinished(failedKey, .failed))
    check(failed == [.releaseSession(failedKey)], "cancellation: failed invocation releases the session")
    check(failedReducer.state == .idle, "cancellation: failed invocation ends idle")

    // A failed scan cancels with its reason.
    var scanFailReducer = hintsNormalReducer()
    _ = scanFailReducer.send(.activateRequested(hintsContext()))
    let scanFailKey = hintsAsScanning(scanFailReducer).key
    check(scanFailReducer.send(.scanFailed(scanFailKey, .accessibilityRevoked)).count == 2,
          "cancellation: failed scan hides and releases")
    check(scanFailReducer.state == .idle, "cancellation: failed scan goes idle")

    // Identifier mismatch (stale generation while scanning) drains the stale payload.
    _ = scanFailReducer.send(.activateRequested(hintsContext()))
    let activeScan = hintsAsScanning(scanFailReducer)
    check(scanFailReducer.send(.scanCompleted(HintSessionKey(id: activeScan.key.id, generation: activeScan.key.generation + 5),
                                               HintScanResult(candidates: [])))
        == [.releaseGeneration(HintSessionKey(id: activeScan.key.id, generation: activeScan.key.generation + 5))],
        "cancellation: scan-key mismatch drains the stale payload")
    if case .scanning = scanFailReducer.state {} else { check(false, "cancellation: live scan untouched by stale result") }
}

private func hintsLimitsTests() {
    // Defaults are the frozen Phase 0 envelope.
    let standard = HintScanLimits.standard
    check(standard.perCallTimeoutMs == 50, "limits: per-call timeout frozen at 50ms")
    check(standard.maxDepth == 40, "limits: depth frozen at 40")
    check(standard.maxVisitedNodes == 4_000, "limits: visited nodes frozen at 4000")
    check(standard.maxCandidates == 1_500, "limits: candidate cap frozen at 1500")
    check(standard.wallClockMs == 750, "limits: wall clock frozen at 750ms")

    // Values clamp DOWN to the frozen ceilings, never widen it.
    check(HintScanLimits(perCallTimeoutMs: 1_000,
        maxDepth: 100,
        maxVisitedNodes: 99_999,
        maxCandidates: 99_999,
        wallClockMs: 9_999) == .standard,
        "limits: oversized budgets clamp to the frozen envelope")

    // Smaller positive budgets stay selectable.
    check(HintScanLimits(perCallTimeoutMs: 10,
        maxDepth: 4,
        maxVisitedNodes: 40,
        maxCandidates: 2,
        wallClockMs: 50)
        == HintScanLimits(perCallTimeoutMs: 10,
        maxDepth: 4,
        maxVisitedNodes: 40,
        maxCandidates: 2,
        wallClockMs: 50),
        "limits: smaller positive budgets are honored")

    // Non-positive budgets take the frozen maximum rather than zeroing the tool.
    check(HintScanLimits(perCallTimeoutMs: 0,
        maxDepth: -3,
        maxVisitedNodes: 0,
        maxCandidates: 0,
        wallClockMs: -5) == .standard,
        "limits: non-positive budgets fall back to the frozen envelope")

    // Round-trip through JSON re-clamps (corrupt config cannot loosen budgets).
    let json = #"{"maxDepth":99,"maxCandidates":9_999}"#
    if let decoded = try? hintsJSONDecode(HintScanLimits.self, json.replacingOccurrences(of: "_", with: "")) {
        check(decoded.maxDepth <= HintScanLimits.standard.maxDepth, "limits: JSON decode cannot exceed the depth ceiling")
        check(decoded.maxCandidates <= HintScanLimits.standard.maxCandidates, "limits: JSON decode cannot exceed the candidate cap")
    } else {
        check(false, "limits: JSON decode works")
    }

    // HintActionKind is Hashable and complete (no pointer/click kinds).
    check(Set([HintActionKind.press, .showMenu, .focus, .scroll]).count == 4,
          "limits: action kinds hash across the frozen matrix")
}

private func hintsTruncationSummaryTests() {
    // Candidate cap surfaces as a count-only reason via the reducer path.
    var cappedReducer = HintSessionReducer(limits: HintScanLimits(maxCandidates: 1))
    _ = cappedReducer.send(.activateRequested(hintsContext()))
    let cappedKey = hintsAsScanning(cappedReducer).key
    let cappedCandidates = (0..<2).map { offset in hintCandidate("tok-\(offset)", x: Double(offset) * 100, y: 5) }
    check(cappedReducer.send(.scanCompleted(cappedKey, HintScanResult(candidates: cappedCandidates,
        summary: HintScanSummary(discoveredCandidates: 2)))).count == 2,
        "truncation: capped scan still presents")
    let cappedState = hintsAsPresenting(cappedReducer)
    check(cappedState.summary.truncationReasons.contains(.candidateCapReached),
          "truncation: candidate cap reason surfaced")
    check(cappedState.summary.acceptedCandidates == 2 && cappedState.summary.retainedCandidates == 1,
          "truncation: summary counts the cap split")
    let cappedSnap = cappedReducer.snapshot(cappedState)
    check(cappedSnap.truncated && cappedSnap.visible.count == 1, "truncation: snapshot marks truncation")

    // Label capacity surfaces when the alphabet cannot cover the ranked pool.
    var smallAlphabet = HintSessionReducer(limits: .standard, alphabet: "as")
    _ = smallAlphabet.send(.activateRequested(hintsContext()))
    let smallKey = hintsAsScanning(smallAlphabet).key
        // 17 candidates exceed the labelled capacity (as: 2,4,8,16).
    let many = (0..<17).map { offset in
        hintCandidate("tok-\(offset)", x: Double(offset % 8) * 100, y: Double(offset / 8) * 40)
    }
    check(smallAlphabet.send(.scanCompleted(smallKey, HintScanResult(candidates: many,
        summary: HintScanSummary(discoveredCandidates: 17)))).count == 2,
        "truncation: over-capacity scan still presents a prefix")
    let smallState = hintsAsPresenting(smallAlphabet)
    check(smallState.summary.truncationReasons.contains(.labelCapacityReached),
          "truncation: label capacity reason surfaced")
    check(smallState.candidates.count == smallAlphabet.labelMaker.maximumCapacity,
          "truncation: labels truncate at capacity, never partial")
    check((0..<smallState.candidates.count).map { smallState.candidates[$0].label }
        == (try? smallAlphabet.labelMaker.labels(candidateCount: smallState.candidates.count)) ?? [],
        "truncation: surviving labels stay the deterministic prefix")

    // Diagnostics stay count-only: no candidate names, text, or labels ride the summary.
    let described = hintsJSONText(smallState.summary)
    check(!described.contains("tok-") && !described.contains("Save"),
          "truncation: summary carries no candidate names or title content")

    // Discovered-count floor: an omitted scanner summary is raised to the payload count.
    var floorReducer = hintsNormalReducer()
    _ = floorReducer.send(.activateRequested(hintsContext()))
    let floorKey = hintsAsScanning(floorReducer).key
    let floorPayload = (0..<3).map { offset in hintCandidate("tok-\(offset)", x: Double(offset) * 100, y: 5) }
    _ = floorReducer.send(.scanCompleted(floorKey, HintScanResult(candidates: floorPayload)))
    check(hintsAsPresenting(floorReducer).summary.discoveredCandidates == 3,
          "truncation: discovered count never under-reports the received payload")

    // Adapter pre-cap accepted count survives the Core's second preparation: the merge is
    // a max, not an overwrite. The adapter counted all three candidates accepted BEFORE
    // the cap; the shared re-preparation re-rejects one on eligibility (disabled) and
    // would report 2 without the merge — the higher pre-cap count must win.
    var mergeReducer = hintsNormalReducer()
    _ = mergeReducer.send(.activateRequested(hintsContext()))
    let mergeKey = hintsAsScanning(mergeReducer).key
    let mergePayload = [
        hintCandidate("tok-ok-1", x: 0, y: 5),
        hintCandidate("tok-ok-2", x: 100, y: 5),
        hintCandidate("tok-stale", x: 200, y: 5, enabled: false), // adapter counted; re-rejected
    ]
    let mergeResult = HintScanResult(
        candidates: mergePayload,
        summary: HintScanSummary(
            discoveredCandidates: 3,
            acceptedCandidates: 3 // adapter's pre-cap count (before Core re-runs prepare)
        )
    )
    _ = mergeReducer.send(.scanCompleted(mergeKey, mergeResult))
    let mergedState = hintsAsPresenting(mergeReducer)
    check(mergedState.summary.acceptedCandidates == 3,
          "summary merge: adapter pre-cap accepted count survives Core re-preparation")
    check(mergedState.summary.discoveredCandidates == 3,
          "summary merge: discovered floor still holds through the merged path")
    check(mergedState.summary.retainedCandidates == 2,
          "summary merge: retained count follows the presentable set (re-rejected candidate out)")
}

/// Render any Encodable value through JSON for content-naive audit assertions.
private func hintsJSONText(_ value: some Encodable) -> String {
    (try? String(decoding: JSONEncoder().encode(value), as: UTF8.self)) ?? ""
}
