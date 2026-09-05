import AppKit
import ApplicationServices
import XCTest
@testable import lineup
import HintsCore

// ============================================================================
// Deterministic stub seams for the Hints AX adapter tests (Gate 3 evidence).
//
// HARD SAFETY RULES:
//   * AXUIElement values are INERT IDENTITIES ONLY. The stub uses
//     `AXUIElementCreateApplication` purely to mint opaque CF objects it can map by
//     `HintAXElementKey`. NO Accessibility permission is required or assumed: the stub
//     NEVER calls AXUIElementCopyAttributeValue / GetPid / PerformAction / Set… on any
//     element, so no real AX query or mutation can occur.
//   * Every protocol answer comes from a preconfigured `Node` table; unknown elements
//     fail closed (nil pid / unknown reads).
//   * Nothing logged or asserted contains control text or raw token material; stub
//     tokens are synthetic counters and element identities are unminted CF objects.
//   * The stub store is only ever touched from the service's serial executor plus test
//     assertions that strictly happen-after an awaited `perform` step.
// ============================================================================

/// One inert element's complete deterministic behavior.
final class StubNode {
    var pid: Int32 = 0
    var role: HintAXRead<String> = .value("AXButton")
    var subrole: HintAXRead<String?> = .value(nil)
    var children: HintAXRead<[AXUIElement]> = .value([])
    var minimized: HintAXRead<Bool> = .value(false)
    var enabled: HintAXRead<Bool> = .value(true)
    var frame: HintAXRead<CGRect> = StubSeams.onscreenFrame
    var actionNames: HintAXRead<[String]> = .value([])
    var isFocusedSettable: HintAXRead<Bool> = .value(false)
    var title: HintAXRead<String?> = .value(nil)
    var accessibleDescription: HintAXRead<String?> = .value(nil)
    var owningWindow: HintAXRead<AXUIElement?> = .value(nil)
    var parent: HintAXRead<AXUIElement?> = .value(nil)
    var topLevelUIElement: HintAXRead<AXUIElement?> = .value(nil)
    var scrollbars: (vertical: AXUIElement?, horizontal: AXUIElement?) = (nil, nil)
    var pageSteppers: (decrement: AXUIElement?, increment: AXUIElement?) = (nil, nil)
    var scrollCapabilities: Set<HintScrollOperation> = []
    var numericRange: (minimum: Double, maximum: Double)?

    init(pid: Int32) {
        self.pid = pid
    }
}

/// The full `HintAXBackend` seam. All reads/writes are serial-executor-only.
final class StubAXBackend: HintAXBackend, @unchecked Sendable {
    // Element minting: unique creation pids guarantee distinct, CF-stable inert
    // identities. These pids are never derived from or compared to any logical pid.
    private var nextMintPid: Int32 = 1_000_001
    private let mintLock = NSLock()

    private var nodes: [HintAXElementKey: StubNode] = [:]
    private var appByPid: [Int32: AXUIElement] = [:]
    private var windowsByApp: [HintAXElementKey: [AXUIElement]] = [:]
    private var menuByApp: [HintAXElementKey: AXUIElement] = [:]

    private(set) var axMessageCount = 0
    private(set) var dispatchLog: [(name: String?, target: AXUIElement)] = []
    var nextDispatchError: AXError = .success

    // One-shot message hooks for deterministic interleaving: the FIRST matching message
    // (kind + target element) fires the closure and auto-removes. Closures may signal a
    // semaphore and sleep while holding the service's serial AX queue, so a test thread can
    // interleave a synchronous registry action (e.g. an authorized releaseGeneration) whose
    // serialization point is the queue itself. Fire happens on the AX queue thread only.
    private struct HookKey: Hashable { let kind: String; let element: HintAXElementKey? }
    private var hooks: [HookKey: () -> Void] = [:]

    func hook(kind: String, target: AXUIElement?, _ action: @escaping () -> Void) {
        hooks[HookKey(kind: kind, element: target.map { HintAXElementKey(element: $0) })] = action
    }

    /// Convenience: fires on the next `children(of:)` read of `element`, once.
    func hookChildren(of element: AXUIElement, signal: DispatchSemaphore, sleepMs: UInt32 = 200) {
        hook(kind: "children", target: element) {
            signal.signal()
            usleep(sleepMs * 1_000)
        }
    }

    private func fire(kind: String, target: AXUIElement?) {
        guard let action = hooks.removeValue(forKey: HookKey(kind: kind, element: target.map { HintAXElementKey(element: $0) })) else { return }
        action()
    }

    /// Returns (creating on demand) the behavior record for `element`.
    func node(_ element: AXUIElement) -> StubNode {
        if let existing = nodes[HintAXElementKey(element: element)] { return existing }
        let created = StubNode(pid: 0)
        nodes[HintAXElementKey(element: element)] = created
        return created
    }

    var dispatchCount: Int { dispatchLog.count }

    // MARK: Fixture builders

    /// Registers a logical application element for `pid`.
    @discardableResult
    func makeApplication(pid: Int32) -> AXUIElement {
        let element = mint()
        node(element).pid = pid
        appByPid[pid] = element
        return element
    }

    /// Registers a window/sheet/menu-bar root under `application` and returns it.
    @discardableResult
    func makeRoot(
        under application: AXUIElement,
        role: String,
        kind: HintAXRootKind,
        configure: (StubNode) -> Void = { _ in }
    ) -> AXUIElement {
        let element = mint()
        let record = node(element)
        record.pid = node(application).pid
        record.role = .value(role)
        configure(record)
        switch kind {
        case .window, .sheet:
            windowsByApp[HintAXElementKey(element: application), default: []].append(element)
            record.children = .value([]) // callers append via makeChild
        case .menuBar:
            menuByApp[HintAXElementKey(element: application)] = element
        }
        return element
    }

    /// Appends a child under `parent` with parent-link ancestry prewired so the public
    /// ancestry walks reach the root.
    @discardableResult
    func makeChild(
        under parent: AXUIElement,
        configure: (StubNode) -> Void = { _ in }
    ) -> AXUIElement {
        let element = mint()
        let record = node(element)
        record.pid = node(parent).pid
        record.parent = .value(parent)
        record.owningWindow = .value(nil)
        configure(record)
        let parentRecord = node(parent)
        if case .value(var kids) = parentRecord.children {
            kids.append(element)
            parentRecord.children = .value(kids)
        } else {
            parentRecord.children = .value([element])
        }
        return element
    }

    /// Registers an ADDITIONAL enumerated window under `application` after a capture.
    func addWindow(
        to application: AXUIElement,
        role: String = "AXGroup",
        minimized: Bool = false
    ) -> AXUIElement {
        let element = mint()
        let record = node(element)
        record.pid = node(application).pid
        record.role = .value(role)
        record.minimized = .value(minimized)
        record.children = .value([])
        windowsByApp[HintAXElementKey(element: application), default: []].append(element)
        return element
    }

    /// Removes `window` from the public enumeration (as if the surface closed or detached
    /// from the app's window list). The node's own behavior remains but is unenumerated.
    func removeWindow(_ window: AXUIElement) {
        let target = HintAXElementKey(element: window)
        for (appKey, list) in windowsByApp {
            windowsByApp[appKey] = list.filter { HintAXElementKey(element: $0) != target }
        }
    }

    private func mint() -> AXUIElement {
        mintLock.lock(); defer { mintLock.unlock() }
        let pid = nextMintPid
        nextMintPid += 1
        // INERT IDENTITY ONLY: no Accessibility grant is consulted and no AX query is
        // issued against this value; every behavior is answered from `nodes`.
        return AXUIElementCreateApplication(pid)
    }

    /// Clears the dispatch record without touching configured behavior.
    func resetDispatchLog() { dispatchLog = [] }

    // MARK: HintAXBackend (deterministic table answers)

    func applicationElement(pid: Int32) -> AXUIElement {
        if let registered = appByPid[pid] { return registered }
        // Unregistered pid: hand back an inert unknown element; `pid(of:)` will answer
        // nil and the caller fails closed — deterministic, no real AX involvement.
        let element = mint()
        node(element).pid = 0
        return element
    }

    func pid(of element: AXUIElement) -> Int32? {
        axMessageCount += 1
        return node(element).pid == 0 ? nil : node(element).pid
    }

    func windows(of application: AXUIElement) -> HintAXRead<[AXUIElement]> {
        axMessageCount += 1
        fire(kind: "windows", target: application)
        return .value(windowsByApp[HintAXElementKey(element: application)] ?? [])
    }

    func menuBar(of application: AXUIElement) -> HintAXRead<AXUIElement?> {
        axMessageCount += 1
        return .value(menuByApp[HintAXElementKey(element: application)])
    }

    func owningWindow(of element: AXUIElement) -> HintAXRead<AXUIElement?> {
        axMessageCount += 1
        return node(element).owningWindow
    }

    func parent(of element: AXUIElement) -> HintAXRead<AXUIElement?> {
        axMessageCount += 1
        return node(element).parent
    }

    func topLevelUIElement(of element: AXUIElement) -> HintAXRead<AXUIElement?> {
        axMessageCount += 1
        return node(element).topLevelUIElement
    }

    func scrollbars(
        of region: AXUIElement, boundary: HintAXBoundary
    ) -> HintAXRead<(vertical: AXUIElement?, horizontal: AXUIElement?)> {
        guard boundary() else { return .unknown }
        axMessageCount += 1
        return .value(node(region).scrollbars)
    }

    func pageStepper(
        of region: AXUIElement, increment: Bool, boundary: HintAXBoundary
    ) -> HintAXRead<AXUIElement?> {
        guard boundary() else { return .unknown }
        axMessageCount += 1
        let steppers = node(region).pageSteppers
        return .value(increment ? steppers.increment : steppers.decrement)
    }

    func children(of element: AXUIElement) -> HintAXRead<[AXUIElement]> {
        axMessageCount += 1
        fire(kind: "children", target: element)
        return node(element).children
    }

    func role(of element: AXUIElement) -> HintAXRead<String> {
        axMessageCount += 1
        return node(element).role
    }

    func subrole(of element: AXUIElement) -> HintAXRead<String?> {
        axMessageCount += 1
        return node(element).subrole
    }

    func frame(of element: AXUIElement, boundary: HintAXBoundary) -> HintAXRead<CGRect> {
        axMessageCount += 1
        return node(element).frame
    }

    func enabled(_ element: AXUIElement) -> HintAXRead<Bool> {
        axMessageCount += 1
        return node(element).enabled
    }

    func minimized(_ window: AXUIElement) -> HintAXRead<Bool> {
        axMessageCount += 1
        return node(window).minimized
    }

    func title(of element: AXUIElement) -> HintAXRead<String?> {
        axMessageCount += 1
        return node(element).title
    }

    func accessibleDescription(of element: AXUIElement) -> HintAXRead<String?> {
        axMessageCount += 1
        return node(element).accessibleDescription
    }

    func actionNames(of element: AXUIElement) -> HintAXRead<[String]> {
        axMessageCount += 1
        return node(element).actionNames
    }

    func isFocusedSettable(_ element: AXUIElement) -> HintAXRead<Bool> {
        axMessageCount += 1
        return node(element).isFocusedSettable
    }

    func scrollCapabilities(
        of region: AXUIElement, boundary: HintAXBoundary
    ) -> HintAXRead<Set<HintScrollOperation>> {
        guard boundary() else { return .unknown }
        axMessageCount += 1
        return .value(node(region).scrollCapabilities)
    }

    func numericRange(
        of element: AXUIElement, boundary: HintAXBoundary
    ) -> HintAXRead<(minimum: Double, maximum: Double)> {
        guard boundary() else { return .unknown }
        axMessageCount += 1
        guard let range = node(element).numericRange else { return .unknown }
        return .value(range)
    }

    func isValueSettable(_ element: AXUIElement) -> HintAXRead<Bool> {
        axMessageCount += 1
        // A configured non-nil numeric range implies a freshly settable value attribute;
        // anything else is a known "not settable" — both answers stay deterministic.
        return .value(node(element).numericRange != nil)
    }

    func setNumericValue(_ value: Double, on element: AXUIElement) -> AXError {
        axMessageCount += 1
        dispatchLog.append((name: nil, target: element))
        return nextDispatchError
    }

    func performAction(_ name: String, on element: AXUIElement) -> AXError {
        axMessageCount += 1
        dispatchLog.append((name: name, target: element))
        return nextDispatchError
    }

    func setFocused(_ value: Bool, on element: AXUIElement) -> AXError {
        axMessageCount += 1
        dispatchLog.append((name: nil, target: element))
        return nextDispatchError
    }
}

// MARK: - Deterministic cross-call seams

/// Fixed reading; deadlines computed from it can never expire.
final class FixedClock: HintScanClock {
    let value: Int64
    init(value: Int64 = 0) { self.value = value }
    func nowMs() -> Int64 { value }
}

/// A clock that deterministically "expires" once a trip condition over two counters
/// (its own nowMs call index and the backend's AX message counter) fires. This lets a
/// test cross the service deadline at an EXACT point of a fixed fixture — before or at
/// the final publication recheck — with no real waiting or threading.
final class TripClock: HintScanClock, @unchecked Sendable {
    private(set) var callCount = 0
    var trip: ((calls: Int, axMessages: Int)) -> Bool = { _ in false }
    private let backend: StubAXBackend
    private let expiredValue: Int64

    init(backend: StubAXBackend, expiredValue: Int64 = 1_000_000) {
        self.backend = backend
        self.expiredValue = expiredValue
    }

    func restartCounter() { callCount = 0 }

    /// Turns expiration off entirely (for follow-up calls on the same service).
    func disarm() { trip = { _ in false } }

    func nowMs() -> Int64 {
        callCount += 1
        return trip((calls: callCount, axMessages: backend.axMessageCount)) ? expiredValue : 0
    }
}

final class FixedFrontmost: HintFrontmostProvider {
    let pid: Int32?
    init(pid: Int32?) { self.pid = pid }
    func currentFrontmostPID() -> Int32? { pid }
}

/// Synthetic sequential tokens ("1", "2", …): countable in assertions, never
/// user-derived content, and never embedded as raw material in logs.
final class SequentialTokenFactory: HintTokenFactory, @unchecked Sendable {
    private(set) var minted = 0
    func mint() -> String { minted += 1; return String(minted) }
}

// MARK: - Shared fixture constants

enum StubSeams {
    static let screens = [HintRect(x: 0, y: 0, width: 2_000, height: 1_200)]
    /// Intersects the captured screen: the pure admission proof's happy geometry.
    static let onscreenFrame = CGRect(x: 10, y: 10, width: 100, height: 30)

    /// A target pid that is never the test runner's own pid (Lineup itself is never a
    /// target of an AX mutation).
    static func targetPid() -> Int32 {
        let base: Int32 = 4_242
        return ProcessInfo.processInfo.processIdentifier == base ? base + 1 : base
    }

    static func pressButtonConfig(pid: Int32) -> (StubNode) -> Void {
        return { node in
            node.pid = pid
            node.role = .value(kAXButtonRole as String)
            node.subrole = .value(nil)
            node.actionNames = .value([kAXPressAction as String])
            node.enabled = .value(true)
            node.frame = StubSeams.onscreenFrame
        }
    }
}
