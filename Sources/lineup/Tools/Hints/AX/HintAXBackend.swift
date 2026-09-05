import AppKit
import ApplicationServices
import Foundation
import HintsCore

// ============================================================================
// Operating-system seam for the Hints AX lane.
//
// Timeout discipline: the application-level timeout does NOT propagate to children or
// other elements; `AXUIElementSetMessagingTimeout` stamps ELEMENT-LOCAL 50 ms windows,
// and EVERY wrapper in this file stamps its target immediately before EVERY AX message —
// including the pid query and each separate attribute query (frame stamps before BOTH its
// position and size messages), and every element handed back so later calls are stamped
// from the start too. Stamping is FAIL-CLOSED: `stampTimeout` returns `false` when the
// stamp itself fails, and the wrapper then refuses to proceed — reads return `.unknown`
// (transport failure) and mutations return `.cannotComplete` WITHOUT dispatching. There
// is no retry path for the stamp or for `kAXErrorCannotComplete`.
//
// Honest reads: every read distinguishes a successful value from failure with
// `HintAXRead<T>`:
//   * Required reads (windows enumeration, role/subrole, children, enabled, minimized,
//     title/description): ANY error is `.unknown` — callers fail closed/cancel. A
//     malformed or undecodable value is `unknown`, never a silently empty result.
//   * Genuinely OPTIONAL attributes (menu bar, owning window, parent, top-level UI
//     element, scrollbar relationships, page steppers): public
//     `.attributeUnsupported`/`.noValue` errors return a KNOWN absence (`.value(nil)`),
//     while transport failures (`kAXErrorCannotComplete`, `.invalidUIElement`, timeouts,
//     failed stamps) stay `.unknown` and fail closed.
//
// Public attributes only (macOS 13 AXAttributeConstants.h/AXRoleConstants.h): no raw
// AXSheets/AXVisible/AXIsOnScreen/AXLabel strings. Sheets/popovers/menus are discovered
// via `kAXWindowsAttribute` roles plus public child/parent/kAXWindow (owningWindow)/
// kAXTopLevelUIElement ancestry in the service; visibility/on-screen admission is proven
// from public non-minimized state plus finite positive frame geometry intersecting the
// captured NSScreen-derived rectangles (see `HintAXGeometry.admitsOnScreen`), never from
// a raw visibility attribute. Secure/menu/tab surfaces use the public subrole/role
// constants (`kAXSecureTextFieldSubrole`, `kAXMenuButtonRole`, `kAXTabGroupRole`).
//
// Composite boundaries: helpers that issue MANY AX messages (`scrollCapabilities`,
// `pageStepper`, `frame`, `scrollbars`, `numericRange`) take a `boundary` closure and
// consult it between EVERY pair of AX messages. Returning `false` aborts the helper
// IMMEDIATELY with `.unknown`; the caller classifies the abort (its own cancelled/
// deadline state) afterwards. The boundary never mutates AX state and never dispatches
// anything.
//
// Action discovery uses `AXUIElementCopyActionNames` EXCLUSIVELY; an undecodable name
// array is `unknown`, not an empty known set. No private symbols, no bulk attribute
// reads, no pointer/event synthesis, no raw scroll action strings.
// ============================================================================

/// Frozen per-call ceiling in seconds (`HintScanLimits.standard.perCallTimeoutMs == 50`).
private let hintAXPerCallTimeoutSeconds: Float = 0.05

/// Per-message abort probe for composite backend helpers. `true` = continue; `false` =
/// cancel/deadline — the helper stops reading and returns `.unknown` without further AX
/// messages or mutations, and the caller classifies the abort from its own state.
public typealias HintAXBoundary = () -> Bool

public struct HintSystemClock: HintScanClock {
    public init() {}
    public func nowMs() -> Int64 {
        Int64((DispatchTime.now().uptimeNanoseconds + 500) / 1_000_000)
    }
}

public protocol HintScanClock: Sendable {
    /// Monotonic milliseconds.
    func nowMs() -> Int64
}

/// Mints opaque, unguessable, session-scoped tokens/identities. Production uses random
/// UUID v4 strings; tokens never encode pid, role, geometry, window identity, or text.
public protocol HintTokenFactory: Sendable {
    func mint() -> String
}

public struct HintRandomTokenFactory: HintTokenFactory {
    public init() {}
    public func mint() -> String { UUID().uuidString }
}

/// Injectable frontmost-PID source. Never a target of an AX mutation itself. Unknown is
/// uncertainty; Hints fails closed on it.
public protocol HintFrontmostProvider: AnyObject, Sendable {
    func currentFrontmostPID() -> Int32?
}

public final class HintNSWorkspaceFrontmostProvider: HintFrontmostProvider {
    public init() {}
    public func currentFrontmostPID() -> Int32? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}

/// Pure visibility/on-screen admission proof, shared by the service and the candidate
/// factory: `true` ONLY for a finite, positive-area frame that intersects at least one of
/// the captured NSScreen-derived rectangles. No AX message is issued here.
public enum HintAXGeometry {
    public static func admitsOnScreen(frame: CGRect, screens: [HintRect]) -> Bool {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.size.width.isFinite, frame.size.height.isFinite,
              frame.size.width > 0, frame.size.height > 0 else { return false }
        let rect = HintRect(
            x: Double(frame.origin.x), y: Double(frame.origin.y),
            width: Double(frame.size.width), height: Double(frame.size.height)
        )
        return screens.contains { rect.intersection($0) != nil }
    }
}

/// The one seam of raw `AXUIElement` manipulation for Hints; individual typed calls only.
public protocol HintAXBackend: AnyObject, Sendable {
    func applicationElement(pid: Int32) -> AXUIElement
    func pid(of element: AXUIElement) -> Int32?

    /// Required enumeration: any AX error is unknown (fail closed/cancel). Sheets,
    /// popovers, and menus are NOT enumerated separately: they are discovered through
    /// this public surface's roles plus public ancestry helpers.
    func windows(of application: AXUIElement) -> HintAXRead<[AXUIElement]>

    // Genuinely optional attributes (.attributeUnsupported/.noValue ⇒ known absence)
    func menuBar(of application: AXUIElement) -> HintAXRead<AXUIElement?>
    /// Public `kAXWindowAttribute` owning-window shortcut, used ONLY to prove parent/
    /// owning-window ancestry; also stamps whatever element it hands back.
    func owningWindow(of element: AXUIElement) -> HintAXRead<AXUIElement?>
    func parent(of element: AXUIElement) -> HintAXRead<AXUIElement?>
    /// Public `kAXTopLevelUIElementAttribute` chain helper, used by the same public
    /// ancestry proof when parent/owning-window links are absent; stamps its result.
    func topLevelUIElement(of element: AXUIElement) -> HintAXRead<AXUIElement?>
    /// Vertical/horizontal scrollbar of a scroll area; known absence allowed. Two AX
    /// messages: consults `boundary` before/between/after them and aborts with `.unknown`
    /// per the boundary contract.
    func scrollbars(of region: AXUIElement, boundary: HintAXBoundary) -> HintAXRead<(vertical: AXUIElement?, horizontal: AXUIElement?)>
    /// Bounded descendant search for a public page stepper (kAXDecrementPageSubrole /
    /// kAXIncrementPageSubrole) inside a scroll area; known absence allowed. Composite
    /// walk: consults `boundary` between every internal AX message and aborts with
    /// `.unknown` when told to stop.
    func pageStepper(of region: AXUIElement, increment: Bool, boundary: HintAXBoundary) -> HintAXRead<AXUIElement?>

    // Traversal (children/parents handed back stamped)
    func children(of element: AXUIElement) -> HintAXRead<[AXUIElement]>
    func role(of element: AXUIElement) -> HintAXRead<String>
    func subrole(of element: AXUIElement) -> HintAXRead<String?>
    /// Two AX messages (position, size): stamps before EACH, consults `boundary` between
    /// them, and aborts with `.unknown` per the boundary contract.
    func frame(of element: AXUIElement, boundary: HintAXBoundary) -> HintAXRead<CGRect>

    // Flags (unknown stays unknown; callers fail closed)
    func enabled(_ element: AXUIElement) -> HintAXRead<Bool>
    /// Honest minimized read; window/sheet kinds only (never called on menu bars). Public
    /// `kAXMinimizedAttribute`: the non-minimized state is a REQUIRED admission proof.
    func minimized(_ window: AXUIElement) -> HintAXRead<Bool>

    // Candidate search metadata ONLY (never a value read; never secure content). No raw
    // AXLabel read exists: accessible label stays nil end to end.
    func title(of element: AXUIElement) -> HintAXRead<String?>
    func accessibleDescription(of element: AXUIElement) -> HintAXRead<String?>

    // Action surface
    func actionNames(of element: AXUIElement) -> HintAXRead<[String]>
    func isFocusedSettable(_ element: AXUIElement) -> HintAXRead<Bool>

    // Scroll capability inspection and mutation primitives (public APIs only)
    /// Fresh public capability inspection for one scroll area: the semantic operations
    /// this element can provably perform right now. Composite walk: consults `boundary`
    /// between every internal AX message and aborts with `.unknown` when told to stop.
    /// Unknown reads yield `.unknown` for callers to classify.
    func scrollCapabilities(of region: AXUIElement, boundary: HintAXBoundary) -> HintAXRead<Set<HintScrollOperation>>
    /// Public kAXMinValue/kAXMaxValue of a scrollbar as public CFNumber/NSNumber scalars
    /// (the public `AXValueType` has no float/double cases). Two AX messages: consults
    /// `boundary` before/between/after them and aborts with `.unknown`.
    func numericRange(of element: AXUIElement, boundary: HintAXBoundary) -> HintAXRead<(minimum: Double, maximum: Double)>
    /// kAXValueAttribute freshly settable?
    func isValueSettable(_ element: AXUIElement) -> HintAXRead<Bool>
    /// Writes a public CFNumber/NSNumber payload to the element's `AXValue` attribute.
    /// `AXValueType` has no scalar float/double cases, so no AXValue is synthesized here.
    func setNumericValue(_ value: Double, on element: AXUIElement) -> AXError

    // Mutations (dispatched at most once by the service; NEVER retried)
    func performAction(_ name: String, on element: AXUIElement) -> AXError
    func setFocused(_ value: Bool, on element: AXUIElement) -> AXError
}

/// INTERNAL injection seam holder (deliberately NOT part of `HintAXBackend`; never
/// public): `@unchecked Sendable` because the adapter test lane sets the installer
/// deterministically on the backend BEFORE any AX work begins; the installer itself
/// issues only the one stamping call. Production behavior is always the real
/// `AXUIElementSetMessagingTimeout` stamp.
final class HintTimeoutInstaller: @unchecked Sendable {
    /// Installs the element-local 50 ms messaging timeout for ONE element and reports
    /// success. Any replacement must honor the contract: `false` means the FOLLOWING
    /// message must not be issued — no read, no action, no set call — and there is NO
    /// retry path.
    var install: (AXUIElement) -> Bool = { element in
        AXUIElementSetMessagingTimeout(element, hintAXPerCallTimeoutSeconds) == .success
    }
}

/// Production backend over public ApplicationServices APIs only.
public final class SystemHintAXBackend: HintAXBackend {
    public init() {}

    // MARK: Timeout stamping + internal injection seam

    /// The internal timeout-installer seam for the macOS adapter test lane. Set
    /// `timeoutInstaller.install = { _ in false }` to force a deterministic stamp
    /// failure without issuing any real AX message. Default: the real stamp.
    let timeoutInstaller = HintTimeoutInstaller()

    /// Stamps the ELEMENT-LOCAL 50 ms messaging window immediately before the next AX
    /// message through the internal `timeoutInstaller` seam. `false` = the stamp itself
    /// failed: the caller must NOT issue the following message — a read returns
    /// `.unknown` (transport failure) and a mutation returns `.cannotComplete` WITHOUT
    /// dispatching. No retry on any path: no stamp, no message.
    private func stampTimeout(_ element: AXUIElement) -> Bool {
        return timeoutInstaller.install(element)
    }

    // MARK: Honest read helpers

    /// Required read: any AX error (or undecodable value) is `unknown`.
    private func requiredRead<T>(_ element: AXUIElement, _ attribute: String, decode: (CFTypeRef) -> T?) -> HintAXRead<T> {
        guard stampTimeout(element) else { return .unknown } // unstampable: no message
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &value
        ) == .success else { return .unknown }
        guard let typed = decode(value) else { return .unknown }
        return .value(typed)
    }

    /// Optional read: `.attributeUnsupported`/`.noValue` are a KNOWN absence (`.value(nil)`);
    /// transport failures and undecodable values stay `.unknown`.
    private func optionalRead<T>(_ element: AXUIElement, _ attribute: String, decode: (CFTypeRef) -> T?) -> HintAXRead<T?> {
        guard stampTimeout(element) else { return .unknown } // unstampable: no message
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        switch error {
        case .success:
            // A mismatched decode is a value-shape failure, not absence: unknown.
            guard let typed = decode(value) else { return .unknown }
            return .value(typed)
        case .attributeUnsupported, .noValue:
            return .value(nil)
        default:
            return .unknown
        }
    }

    private static func decodeString(_ ref: CFTypeRef) -> String? { ref as? String }
    private static func decodeBool(_ ref: CFTypeRef) -> Bool? {
        if let bool = ref as? Bool { return bool }
        if let number = ref as? NSNumber { return number.boolValue }
        return nil
    }
    private static func decodeElement(_ ref: CFTypeRef) -> AXUIElement? { ref as? AXUIElement }
    private static func decodeChildArray(_ ref: CFTypeRef) -> [AXUIElement]? {
        (ref as? [AXUIElement]) ?? ((ref as? [AnyObject]) as? [AXUIElement])
    }

    /// Scalar decode for scrollbar `AXValue`/`AXMinValue`/`AXMaxValue` payloads: public
    /// CFNumber/NSNumber values ONLY. The public `AXValueType` has no `.float`/`.double`
    /// cases (it covers cgPoint/cgSize/cgRect/cfRange/axError), so scalar values bridge
    /// through NSNumber; non-finite numbers fail the decode. `AXValue` remains in use for
    /// CGPoint/CGSize frame reads only.
    static func decodeDouble(_ ref: CFTypeRef) -> Double? {
        guard let number = ref as? NSNumber else { return nil }
        let decoded = number.doubleValue
        return decoded.isFinite ? decoded : nil
    }

    // MARK: Element acquisition

    public func applicationElement(pid: Int32) -> AXUIElement {
        // Creation is not an AX message; the stamp is attempted eagerly so the very next
        // call is covered, and every later wrapper re-stamps its target per message — a
        // failed stamp here therefore surfaces on that next message (fail closed there).
        let element = AXUIElementCreateApplication(pid)
        _ = stampTimeout(element)
        return element
    }

    public func pid(of element: AXUIElement) -> Int32? {
        // The pid query is an AX message: it is issued ONLY behind a successful stamp.
        guard stampTimeout(element) else { return nil } // unstampable: no message
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    // MARK: Required enumeration

    public func windows(of application: AXUIElement) -> HintAXRead<[AXUIElement]> {
        requiredRead(application, kAXWindowsAttribute as String, decode: Self.decodeChildArray)
    }

    // MARK: Optional attributes

    public func menuBar(of application: AXUIElement) -> HintAXRead<AXUIElement?> {
        optionalRead(application, kAXMenuBarAttribute as String, decode: Self.decodeElement)
    }

    public func owningWindow(of element: AXUIElement) -> HintAXRead<AXUIElement?> {
        optionalRead(element, kAXWindowAttribute as String, decode: Self.decodeElement)
    }

    public func parent(of element: AXUIElement) -> HintAXRead<AXUIElement?> {
        optionalRead(element, kAXParentAttribute as String, decode: Self.decodeElement)
    }

    public func topLevelUIElement(of element: AXUIElement) -> HintAXRead<AXUIElement?> {
        optionalRead(element, kAXTopLevelUIElementAttribute as String, decode: Self.decodeElement)
    }

    public func scrollbars(of region: AXUIElement, boundary: HintAXBoundary) -> HintAXRead<(vertical: AXUIElement?, horizontal: AXUIElement?)> {
        guard boundary() else { return .unknown } // aborted between: callers classify
        let vertical = optionalRead(region, kAXVerticalScrollBarAttribute as String, decode: Self.decodeElement)
        guard boundary() else { return .unknown }
        let horizontal = optionalRead(region, kAXHorizontalScrollBarAttribute as String, decode: Self.decodeElement)
        guard boundary() else { return .unknown }
        if vertical.isUnknown || horizontal.isUnknown { return .unknown }
        return .value((vertical.value ?? nil, horizontal.value ?? nil))
    }

    /// Bounded descendant search for a page stepper; depth 16, node 512, identity cycle
    /// guard. Every child element is studied through stamped reads with a `boundary`
    /// check between EVERY internal AX message; telling the helper to stop aborts with
    /// `.unknown` (callers classify from their own state). Known absence when the
    /// subtree simply has none; unknown when a boundary abort or transport failure
    /// interrupts the walk.
    public func pageStepper(of region: AXUIElement, increment: Bool, boundary: HintAXBoundary) -> HintAXRead<AXUIElement?> {
        let wantedSubrole = increment
            ? (kAXIncrementPageSubrole as String)
            : (kAXDecrementPageSubrole as String)
        var queue: [(element: AXUIElement, depth: Int)] = [(region, 0)]
        var seen = Set<HintAXElementKey>([HintAXElementKey(element: region)])
        var visited = 0
        let maxDepth = 16
        let maxNodes = 512
        while let (element, depth) = queue.first {
            queue.removeFirst()
            guard boundary() else { return .unknown } // aborted: callers classify
            if visited >= maxNodes { return .value(nil) } // searched enough: known absence
            visited += 1
            if depth < maxDepth {
                let kidRead: HintAXRead<[AXUIElement]> = children(of: element)
                guard boundary() else { return .unknown }
                switch kidRead {
                case .value(let kids):
                    for kid in kids {
                        if seen.contains(HintAXElementKey(element: kid)) { continue }
                        seen.insert(HintAXElementKey(element: kid))
                        guard boundary() else { return .unknown }
                        let subrole = self.subrole(of: kid)
                        guard boundary() else { return .unknown }
                        switch subrole {
                        case .value(let found):
                            if found == wantedSubrole { return .value(kid) }
                        case .unknown:
                            continue // this child's subrole is individually unreadable
                        }
                        queue.append((kid, depth + 1))
                    }
                case .unknown:
                    // A transport failure inside the walk is uncertainty: fail closed.
                    return .unknown
                }
            }
        }
        return .value(nil)
    }

    // MARK: Traversal

    public func children(of element: AXUIElement) -> HintAXRead<[AXUIElement]> {
        requiredRead(element, kAXChildrenAttribute as String, decode: Self.decodeChildArray)
    }

    public func role(of element: AXUIElement) -> HintAXRead<String> {
        requiredRead(element, kAXRoleAttribute as String, decode: Self.decodeString)
    }

    public func subrole(of element: AXUIElement) -> HintAXRead<String?> {
        // HONEST OPTIONAL semantics: a public `.attributeUnsupported`/`.noValue` is a
        // KNOWN absence (`.value(nil)`); transport/decoding failures and a malformed
        // (non-string) payload stay `.unknown`. Callers treat unknown as a rejection and
        // nil as a real, known absence — unknown is never collapsed to nil.
        optionalRead(element, kAXSubroleAttribute as String, decode: Self.decodeString)
    }

    /// Two separate AX messages; each is stamped (failing closed) and bracketed.
    public func frame(of element: AXUIElement, boundary: HintAXBoundary) -> HintAXRead<CGRect> {
        guard stampTimeout(element) else { return .unknown } // unstampable: no message
        var positionRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &positionRef
        ) == .success, let positionValue = positionRef as? AXValue,
            AXValueGetType(positionValue) == .cgPoint else { return .unknown }
        var point = CGPoint.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point) else {
            return .unknown // malformed position payload is a failure, not a zero frame
        }
        guard boundary() else { return .unknown } // abort between the two messages

        // Fresh element-local stamp immediately before the size query.
        guard stampTimeout(element) else { return .unknown } // unstampable: no message
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSizeAttribute as CFString, &sizeRef
        ) == .success, let sizeValue = sizeRef as? AXValue,
            AXValueGetType(sizeValue) == .cgSize else { return .unknown }
        var size = CGSize.zero
        guard AXValueGetValue(sizeValue, .cgSize, &size) else {
            return .unknown // malformed size payload is a failure, not a zero frame
        }
        return .value(CGRect(origin: point, size: size))
    }

    // MARK: Flags

    public func enabled(_ element: AXUIElement) -> HintAXRead<Bool> {
        requiredRead(element, kAXEnabledAttribute as String, decode: Self.decodeBool)
    }

    public func minimized(_ window: AXUIElement) -> HintAXRead<Bool> {
        requiredRead(window, kAXMinimizedAttribute as String, decode: Self.decodeBool)
    }

    // MARK: Candidate search metadata

    public func title(of element: AXUIElement) -> HintAXRead<String?> {
        requiredRead(element, kAXTitleAttribute as String, decode: Self.decodeString)
    }

    public func accessibleDescription(of element: AXUIElement) -> HintAXRead<String?> {
        requiredRead(element, kAXDescriptionAttribute as String, decode: Self.decodeString)
    }

    // MARK: Action surface

    public func actionNames(of element: AXUIElement) -> HintAXRead<[String]> {
        guard stampTimeout(element) else { return .unknown } // unstampable: no message
        var namesRef: CFArray?
        guard AXUIElementCopyActionNames(element, &namesRef) == .success else { return .unknown }
        // A malformed/undecodable action-name array is a failure, NOT an empty known set.
        guard let names = namesRef as? [String] else { return .unknown }
        return .value(names)
    }

    public func isFocusedSettable(_ element: AXUIElement) -> HintAXRead<Bool> {
        guard stampTimeout(element) else { return .unknown } // unstampable: no message
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            element, kAXFocusedAttribute as CFString, &settable
        ) == .success else { return .unknown }
        return .value(settable.boolValue)
    }

    // MARK: Scroll capability and value primitives

    /// Fresh public capability inspection: scrollbar resolution, increment/decrement
    /// action advertisement, page steppers, and settable numeric ranges. Only provable
    /// operations are reported; with everything unknown, the result is unknown. The
    /// `boundary` is consulted between every internal AX message; a stop instruction
    /// aborts with `.unknown` so the caller can classify cancel/deadline.
    public func scrollCapabilities(of region: AXUIElement, boundary: HintAXBoundary) -> HintAXRead<Set<HintScrollOperation>> {
        guard boundary() else { return .unknown }
        var capabilities = Set<HintScrollOperation>()
        let bars = scrollbars(of: region, boundary: boundary)
        guard boundary() else { return .unknown }
        guard !bars.isUnknown else { return .unknown }
        let vertical = bars.value?.vertical
        let horizontal = bars.value?.horizontal

        // Increment/decrement advertisements decide up/down (vertical) and left/right
        // (horizontal) provability; on the vertical axis, home/end additionally require a
        // freshly settable kAXValue with a decodable numeric range. All abort with
        // `.unknown` per the boundary contract.
        func operations(possibleOn bar: AXUIElement, verticalAxis: Bool) -> Bool {
            let names = actionNames(of: bar)
            guard boundary(), case .value(let set) = names else { return false }
            if verticalAxis {
                if set.contains(kAXIncrementAction as String) { capabilities.insert(.down) }
                if set.contains(kAXDecrementAction as String) { capabilities.insert(.up) }
            } else {
                if set.contains(kAXIncrementAction as String) { capabilities.insert(.right) }
                if set.contains(kAXDecrementAction as String) { capabilities.insert(.left) }
            }
            if verticalAxis {
                guard boundary() else { return false }
                let settable = isValueSettable(bar)
                guard boundary() else { return false }
                let range = numericRange(of: bar, boundary: boundary)
                guard boundary() else { return false }
                if settable == HintAXRead<Bool>.value(true),
                   case .value(let limitsPair) = range {
                    if limitsPair.minimum.isFinite, limitsPair.maximum.isFinite,
                       limitsPair.minimum < limitsPair.maximum {
                        capabilities.insert(.home)
                        capabilities.insert(.end)
                    }
                }
            }
            return true
        }
        if let vertical, !operations(possibleOn: vertical, verticalAxis: true) {
            return .unknown
        }
        if let horizontal, !operations(possibleOn: horizontal, verticalAxis: false) {
            return .unknown
        }
        // Page steppers with freshly advertised press.
        if case .value(.some(let pageUp)) = pageStepper(of: region, increment: false, boundary: boundary) {
            guard boundary() else { return .unknown }
            if case .value(let names) = actionNames(of: pageUp),
               names.contains(kAXPressAction as String) {
                capabilities.insert(.pageUp)
            }
        }
        guard boundary() else { return .unknown }
        if case .value(.some(let pageDown)) = pageStepper(of: region, increment: true, boundary: boundary) {
            guard boundary() else { return .unknown }
            if case .value(let names) = actionNames(of: pageDown),
               names.contains(kAXPressAction as String) {
                capabilities.insert(.pageDown)
            }
        }
        return .value(capabilities)
    }

    public func numericRange(of element: AXUIElement, boundary: HintAXBoundary) -> HintAXRead<(minimum: Double, maximum: Double)> {
        guard boundary() else { return .unknown } // aborted between: callers classify
        let minimum = optionalRead(element, kAXMinValueAttribute as String, decode: Self.decodeDouble)
        guard boundary() else { return .unknown }
        let maximum = optionalRead(element, kAXMaxValueAttribute as String, decode: Self.decodeDouble)
        guard boundary() else { return .unknown }
        // Honest optionals ONLY: the concrete range requires BOTH attributes to answer
        // with a KNOWN present value (`.value(.some)`); `.value(nil)` absence and
        // transport `.unknown` both fail closed here. Never collapse unknown to nil.
        guard case .value(.some(let min)) = minimum,
              case .value(.some(let max)) = maximum else { return .unknown }
        return .value((min, max))
    }

    public func isValueSettable(_ element: AXUIElement) -> HintAXRead<Bool> {
        guard stampTimeout(element) else { return .unknown } // unstampable: no message
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            element, kAXValueAttribute as CFString, &settable
        ) == .success else { return .unknown }
        return .value(settable.boolValue)
    }

    public func setNumericValue(_ value: Double, on element: AXUIElement) -> AXError {
        guard stampTimeout(element) else { return .cannotComplete } // unstampable: no dispatch
        // Scalar AXValue payloads are public CFNumber/NSNumber values; the public
        // `AXValueType` has no float/double cases to synthesize.
        let payload: NSNumber = NSNumber(value: value)
        return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, payload)
    }

    // MARK: Mutations

    public func performAction(_ name: String, on element: AXUIElement) -> AXError {
        guard stampTimeout(element) else { return .cannotComplete } // unstampable: no dispatch
        return AXUIElementPerformAction(element, name as CFString)
    }

    public func setFocused(_ value: Bool, on element: AXUIElement) -> AXError {
        guard stampTimeout(element) else { return .cannotComplete } // unstampable: no dispatch
        let cfValue: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, cfValue)
    }
}
