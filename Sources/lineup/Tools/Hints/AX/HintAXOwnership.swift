import ApplicationServices
import Foundation
import HintsCore

// ============================================================================
// AX lane ownership types: honest read results, root kinds, pending captures, and
// opaque stable root identities. Nothing here exposes an AXUIElement outside the lane.
// ============================================================================

/// Distinguishes a successful typed read from a failed/unknown one. Safety-critical
/// decisions (capture rejection, invocation revalidation) treat `unknown` as failure
/// instead of collapsing it into `false`/`nil`/empty.
public enum HintAXRead<Value>: Sendable {
    /// The attribute answered with a decoded value of the expected type (`nil` Included
    /// when the property is a known, genuine absence — callers choose which they need).
    case value(Value)
    /// Transport/timeout/undecodable failure. Fail-closed callers MUST treat as rejection.
    case unknown

    public var value: Value? {
        if case .value(let v) = self { return v }
        return nil
    }

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    /// `true` ONLY when the read answered with an affirmative value equal to `wanted`.
    /// Unknown and any other value both roll up as false for gating (fail closed).
    public func isAffirmed(equalTo wanted: Value) -> Bool where Value: Equatable {
        self == .value(wanted)
    }
}

public extension HintAXRead where Value == Bool {
    /// `true` ONLY when the attribute answered with an affirmative boolean. Unknown and
    /// false both roll up as false for gating decisions (fail closed).
    var isAffirmed: Bool { self == .value(true) }
}

extension HintAXRead: Equatable where Value: Equatable {}
extension HintAXRead: Hashable where Value: Hashable {}

/// Opaque, unguessable identity for one pending capture. Pure value; carries no pid, no
/// context, and no AX reference. Minted by the injected token factory at capture time.
public struct HintPendingCaptureID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String

    public init(_ raw: String) { self.raw = raw }

    public static func == (lhs: HintPendingCaptureID, rhs: HintPendingCaptureID) -> Bool {
        lhs.raw == rhs.raw
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(raw) }

    public var description: String { "HintPendingCaptureID(\(raw.count) bytes)" }
}

/// Opaque stable identity of one adopted session root. Stable for the whole session
/// lifetime (NOT per generation): every generation's targets record the proven root they
/// descend from. Never derived from element identity, metadata, or geometry; minted by the
/// injected token factory.
public struct HintAXRootID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String

    public init(_ raw: String) { self.raw = raw }

    public var description: String { "HintAXRootID(\(raw.count) bytes)" }
}

/// Provenance kind of a retained session root. Determines WHICH attributes are checked in
/// history/revalidation — a kind-appropriate check set, so window-only minimized checks are
/// never run against menu bars. Kinds are fixed at capture/adoption; nothing is re-derived.
public enum HintAXRootKind: Hashable, Codable, Sendable {
    /// An original captured application window (the sponsor class for transient probes).
    case window
    /// A captured sheet/popover-type surface.
    case sheet
    /// The application menu bar surface.
    case menuBar
}

/// One pending capture: the AX references owned between a successful capture and reducer
/// adoption. Owned ONLY by `HintAXService` on its serial executor; carries the application
/// element, participating root elements with their minted opaque root IDs and provenance
/// kind, and the exact pure context captured. A second pending capture is rejected until
/// this one is adopted or discarded.
struct HintPendingCapture {
    let id: HintPendingCaptureID
    let targetPid: Int32
    let context: HintTargetContext
    let application: AXUIElement
    /// Baseline roots in capture order. All elements stamped.
    let roots: [(element: AXUIElement, rootID: HintAXRootID, kind: HintAXRootKind)]
}
