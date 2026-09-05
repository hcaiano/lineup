import ApplicationServices
import HintsCore

// Deterministic candidate conversion: the frozen candidate/action matrix as implemented by
// the AX adapter. HintsCore's `HintEligibility` remains the final owner of eligibility,
// ranking, dedupe, and rank-before-cap retention. No text value is read here: only
// candidate-search metadata (title/description), and never from secure fields.
//
// Phase 2A official-header rules (macOS 10.13 public AXAttributeConstants.h):
//   * No raw AXVisible/AXIsOnScreen EXISTS publicly. Visibility and on-screen admission
//     for windows AND candidates is proven from public non-minimized state plus finite
//     positive `AXPosition`/`AXSize` geometry intersecting the captured NSScreen-derived
//     rectangles (`HintAXGeometry.admitsOnScreen`); candidate booleans are set true ONLY
//     after that proof.
//   * Secure/menu/tab surfaces use public constants: `kAXSecureTextFieldSubrole`,
//     `kAXMenuButtonRole`, and parent-role provenance from `kAXTabGroupRole` for tab
//     classification. No private-looking raw subrole strings exist in this file.
//
// Phase 2A remediation 2 (B):
//   * Press/ShowMenu advertisement depends ONLY on a fresh `AXUIElementCopyActionNames`
//     read; forced-attribute (kAXFocusedAttribute) settability is consulted exclusively
//     for focus-based editable behavior.
//   * Every eligibility-relevant flag is EXPLICIT only: an unknown enabled read fails
//     (false), and geometry that fails the public proof marks the candidate hidden.
//
// Phase 2A remediation 2 (C): scroll advertisement happens ONLY when fresh public
//   capability inspection found at least one provable command; no raw action names are
//   ever fabricated and no speculative operation is claimed.

/// The public semantic scroll operations this release supports, mapped from public AX
/// capability surfaces (scrollbar increment/decrement actions, page steppers with press,
/// and settable numeric scrollbar values). This is the AX lane's own adapter enum; Phase 3
/// binds `HintScrollCommand` (up/down/pageUp/pageDown/home/end) onto these.
public enum HintScrollOperation: Hashable, Sendable, CaseIterable {
    case up
    case down
    case left
    case right
    case pageUp
    case pageDown
    case home
    case end

    /// Whether the operation targets the vertical axis (up/down/pageUp/pageDown/home/end)
    /// or the horizontal axis (left/right).
    public var isVertical: Bool {
        switch self {
        case .left, .right: return false
        case .up, .down, .pageUp, .pageDown, .home, .end: return true
        }
    }
}

/// Maps public role/subrole strings to `HintRoleClass`, and computes the frozen advertised
/// action set exactly per the matrix. Pure with respect to the injected backend.
enum HintAXCandidateFactory {

    /// Per-element classification input gathered by the traversal.
    struct Probe {
        let role: String?
        let subrole: String?
        let parentRole: String?
        let frame: HintAXRead<CGRect>
        let enabled: HintAXRead<Bool>
        let actionNames: HintAXRead<[String]>
        let focusedSettable: HintAXRead<Bool>
        let scrollCapabilities: HintAXRead<Set<HintScrollOperation>>
        /// PID of the owning application; always the captured target PID (traversal
        /// rejects unknown/foreign pids before any candidate is minted).
        let pid: Int32
        /// The proven sponsoring session root ID this element descends from.
        let rootID: HintAXRootID
        let ancestorTokens: [HintTargetToken]
        /// The captured NSScreen-derived rectangles the visibility/on-screen proof uses.
        let screens: [HintRect]
    }

    // MARK: Role classification (matrix row mapping)

    /// Classification per the frozen candidate/action matrix. Tab items classify as `.tab`
    /// when PROVEN inside a public tab-group parent (radio buttons) — public
    /// `kAXTabGroupRole` parentage, never an undocumented subrole. Secure fields classify
    /// `.other` and are flagged secure so eligibility rejects them.
    static func classify(role: String?, subrole: String?, parentRole: String?) -> HintRoleClass {
        switch subrole {
        case kAXSecureTextFieldSubrole as String?:
            return .other
        default:
            break
        }
        switch role {
        case kAXButtonRole as String?:
            return .button
        case kAXLinkRole as String?:
            return .link
        case kAXCheckBoxRole as String?:
            return .checkbox
        case kAXRadioButtonRole as String?:
            // Tab items are commonly radio buttons inside a tab group; classify by proven
            // parent role so they match the matrix's tab class.
            return parentRole == (kAXTabGroupRole as String) ? .tab : .radio
        case kAXMenuItemRole as String?:
            return .menuItem
        case kAXPopUpButtonRole as String?:
            return .popup
        case kAXMenuButtonRole as String?:
            return .menuTrigger
        case kAXComboBoxRole as String?:
            // Combo boxes advertise both a text area and a popup; the popup action row
            // applies, and the editable surface stays focusable only if settable.
            return .popup
        case kAXTextFieldRole as String?, kAXTextAreaRole as String?:
            return .editable
        case kAXScrollAreaRole as String?:
            return .scrollRegion
        default:
            return .other
        }
    }

    /// True when the element's role or subrole identifies a secure field (public
    /// `kAXSecureTextFieldSubrole` only). Secure fields are never read for value and are
    /// always rejected from the candidate set.
    static func isSecure(role: String?, subrole: String?) -> Bool {
        let secureMarker = kAXSecureTextFieldSubrole as String
        return role == secureMarker || subrole == secureMarker
    }

    // MARK: Advertised actions (matrix action mapping)

    /// The advertised `HintActionKind` set for one element, exactly per the matrix:
    /// - button/link/checkbox/radio/tab/menu item advertise `.press` ONLY when a fresh
    ///   `AXUIElementCopyActionNames` read returned `AXPress`.
    /// - popup/menu trigger advertise `.showMenu` ONLY when a fresh read returned
    ///   `AXShowMenu`. Focus settability is deliberately NOT consulted for these rows.
    /// - editable NONSECURE controls advertise `.focus` ONLY when the focused attribute is
    ///   explicitly settable — this is the ONLY row that consults it. Unknown settability
    ///   does not advertise focus (and does not suppress a press/showMenu row).
    /// - scroll regions advertise `.scroll` ONLY when fresh public capability inspection
    ///   found at least one provable command. No raw action names exist here.
    /// Unknown action reads suppress the advertisement: unknown is never treated as
    /// advertised.
    static func advertisedActions(
        roleClass: HintRoleClass,
        actionNames: HintAXRead<[String]>,
        isSecure: Bool,
        focusedSettable: HintAXRead<Bool>,
        scrollCapabilities: HintAXRead<Set<HintScrollOperation>>
    ) -> Set<HintActionKind> {
        var advertised = Set<HintActionKind>()
        switch roleClass {
        case .button, .link, .checkbox, .radio, .tab, .menuItem:
            guard case .value(let names) = actionNames else { return advertised }
            if names.contains(kAXPressAction as String) { advertised.insert(.press) }
        case .popup, .menuTrigger:
            guard case .value(let names) = actionNames else { return advertised }
            if names.contains(kAXShowMenuAction as String) { advertised.insert(.showMenu) }
        case .editable:
            if !isSecure, focusedSettable == HintAXRead<Bool>.value(true) {
                advertised.insert(.focus)
            }
        case .scrollRegion:
            if case .value(let capabilities) = scrollCapabilities, !capabilities.isEmpty {
                advertised.insert(.scroll)
            }
        case .other:
            break
        }
        return advertised
    }

    // MARK: Conversion

    /// Converts one probed element into a `HintCandidate`, or nil when there is no
    /// advertised capability. `isEnabled` is explicit only (unknown fails closed).
    /// `isVisible`/`isOnScreen` are TRUE only after the pure geometry proof
    /// (`HintAXGeometry.admitsOnScreen`): finite positive frame intersecting the captured
    /// NSScreen-derived rectangles. Accessible label stays nil end-to-end (no public
    /// label attribute is read); search metadata is never read for secure elements and is
    /// never used for continuity identity (always nil).
    static func candidate(
        from probe: Probe,
        searchMetadata: (title: String?, description: String?)?,
        token: HintTargetToken
    ) -> HintCandidate? {
        let roleClass = classify(role: probe.role, subrole: probe.subrole, parentRole: probe.parentRole)
        let secure = isSecure(role: probe.role, subrole: probe.subrole)
        var actions = advertisedActions(
            roleClass: roleClass,
            actionNames: probe.actionNames,
            isSecure: secure,
            focusedSettable: probe.focusedSettable,
            scrollCapabilities: probe.scrollCapabilities
        )
        if secure { actions.remove(.focus) }
        guard !actions.isEmpty else { return nil }

        // Geometry: without a typed finite positive-area frame read, nothing is retained.
        guard case .value(let frame) = probe.frame,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.size.width.isFinite, frame.size.height.isFinite,
              frame.width > 0, frame.height > 0 else {
            return nil
        }
        // The ONE geometry fact both window/candidate admission and the pure booleans use.
        let admitsScreen = HintAXGeometry.admitsOnScreen(frame: frame, screens: probe.screens)

        return HintCandidate(
            token: token,
            pid: probe.pid,
            // Participating window provenance is carried by the sponsoring session root.
            windowToken: probe.rootID.raw,
            role: roleClass,
            subrole: probe.subrole,
            advertisedActions: actions,
            title: searchMetadata?.title,
            label: nil, // no public AXLabel read exists; label stays nil end-to-end
            descriptiveText: searchMetadata?.description,
            frame: HintRect(x: Double(frame.origin.x), y: Double(frame.origin.y),
                            width: Double(frame.size.width), height: Double(frame.size.height)),
            // Explicit-only enabled; visibility/on-screen ONLY after geometry proof.
            isEnabled: probe.enabled == HintAXRead<Bool>.value(true),
            isVisible: admitsScreen,
            isOnScreen: admitsScreen,
            isSecure: secure,
            ancestorTokens: probe.ancestorTokens,
            continuity: nil
        )
    }
}
