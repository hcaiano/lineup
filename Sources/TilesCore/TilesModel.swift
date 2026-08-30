import Foundation
import ZonesCore

/// The four virtual workspaces owned by Tiles.  A workspace is a Tiles model
/// concept; it is deliberately not a native macOS Space.
public struct WorkspaceID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: Int

    /// `init(rawValue:)` is intentionally non-failing, as required by
    /// `RawRepresentable`.  Values outside 1...4 are retained so a decoder or
    /// a session validator can reject them without crashing the process.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: Int) {
        self.init(rawValue: rawValue)
    }

    public var isValid: Bool { (1...4).contains(rawValue) }

    public static let workspace1 = WorkspaceID(rawValue: 1)
    public static let workspace2 = WorkspaceID(rawValue: 2)
    public static let workspace3 = WorkspaceID(rawValue: 3)
    public static let workspace4 = WorkspaceID(rawValue: 4)
    public static let all: [WorkspaceID] = [.workspace1, .workspace2, .workspace3, .workspace4]

    // Readable aliases for clients that model workspaces as ordinal values.
    public static let first = workspace1
    public static let second = workspace2
    public static let third = workspace3
    public static let fourth = workspace4
    public static let one = workspace1
    public static let two = workspace2
    public static let three = workspace3
    public static let four = workspace4

    public static func from(_ rawValue: Int) -> WorkspaceID? {
        let value = WorkspaceID(rawValue: rawValue)
        return value.isValid ? value : nil
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(Int.self)
        guard let valid = Self.from(value) else {
            throw TilesModelError.invalidWorkspaceID(value)
        }
        self = valid
    }

    public func encode(to encoder: Encoder) throws {
        guard isValid else { throw TilesModelError.invalidWorkspaceID(rawValue) }
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// An ephemeral identity for one AX window.  A token is generated again after
/// every Lineup launch; it is never written to settings or recovery data.
public struct WindowToken: RawRepresentable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }
}

/// Stable identity of a leaf in a display's current Zones layout.
public struct TileID: Equatable, Hashable, Sendable {
    public let screenKey: String
    public let leafIndex: Int

    public init(screenKey: String, leafIndex: Int) {
        self.screenKey = screenKey
        self.leafIndex = leafIndex
    }

    public init(_ screenKey: String, _ leafIndex: Int) {
        self.init(screenKey: screenKey, leafIndex: leafIndex)
    }
}

/// A tile address carries identity plus normalized geometry used while a Zones
/// layout is rebased.  The center is not an identity and must not be persisted.
public struct TileAddress: Equatable, Sendable {
    public let id: TileID
    public let normalizedCenter: CGPoint

    public init(id: TileID, normalizedCenter: CGPoint) {
        self.id = id
        self.normalizedCenter = normalizedCenter
    }

    public init(_ id: TileID, normalizedCenter: CGPoint) {
        self.init(id: id, normalizedCenter: normalizedCenter)
    }

    public init(screenKey: String, leafIndex: Int, normalizedCenter: CGPoint) {
        self.init(id: TileID(screenKey: screenKey, leafIndex: leafIndex), normalizedCenter: normalizedCenter)
    }

    public var screenKey: String { id.screenKey }
    public var leafIndex: Int { id.leafIndex }
}

/// A leaf's normalized geometry.  `rect` uses a 0...1 coordinate space for
/// one display.  `screenKey` is optional in practice because callers may build
/// a per-display list; when omitted, the surrounding stack supplies it.
public struct NormalizedLeaf: Equatable, Sendable {
    public let screenKey: String
    public let index: Int
    public let rect: CGRect

    public init(index: Int, rect: CGRect, screenKey: String = "") {
        self.screenKey = screenKey
        self.index = index
        self.rect = rect
    }

    public init(_ index: Int, _ rect: CGRect, screenKey: String = "") {
        self.init(index: index, rect: rect, screenKey: screenKey)
    }

    public init(index: Int, center: CGPoint, screenKey: String = "") {
        self.init(screenKey: screenKey, index: index, normalizedCenter: center)
    }

    public init(screenKey: String, index: Int, rect: CGRect) {
        self.init(index: index, rect: rect, screenKey: screenKey)
    }

    public init(index: Int, normalizedRect: CGRect, screenKey: String = "") {
        self.init(index: index, rect: normalizedRect, screenKey: screenKey)
    }

    public init(screenKey: String = "", index: Int, normalizedCenter: CGPoint) {
        // A point-only leaf is useful for deterministic tests and for older
        // integrations that only expose centers.  A tiny non-zero rect makes
        // center containment and intersection deterministic.
        let epsilon: CGFloat = 0.000001
        self.init(index: index,
                  rect: CGRect(x: normalizedCenter.x - epsilon,
                               y: normalizedCenter.y - epsilon,
                               width: epsilon * 2,
                               height: epsilon * 2),
                  screenKey: screenKey)
    }

    public var normalizedRect: CGRect { rect }
    public var rectInNormalizedSpace: CGRect { rect }
    public var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    public var normalizedCenter: CGPoint { center }
    public var tileID: TileID { TileID(screenKey: screenKey, leafIndex: index) }
    public var id: TileID { tileID }
    public var leafIndex: Int { index }

    public func address(screenKey fallbackScreenKey: String? = nil) -> TileAddress {
        TileAddress(id: TileID(screenKey: screenKey.isEmpty ? (fallbackScreenKey ?? screenKey) : screenKey,
                               leafIndex: index),
                    normalizedCenter: center)
    }
}

/// The immutable view of Zones geometry consumed by the pure reducer.  The
/// normalized leaves are the identity/rebase data.  Optional resolved frames
/// let a shell provide actual Cocoa-space frames without putting AppKit types
/// in TilesCore; when absent, the normalized rect is used as a pure fallback.
public struct LayoutSnapshot: Equatable, Sendable {
    public var screens: [String: [NormalizedLeaf]]
    /// The unmodified rectangles produced by Zones.  `frames` deliberately
    /// remains the source geometry so callers that already consume it keep the
    /// same meaning; `frame(for:)` applies the optional Tiles spacing at the
    /// AX boundary.
    public var frames: [String: [CGRect]]
    public var primaryScreenKey: String?
    /// Spacing between adjacent tiles, in screen points.  Zero is the exact
    /// gapless Zones geometry.  The runtime may change this value between
    /// snapshots without rebuilding the layout source.
    public var gapPoints: CGFloat

    public init(screens: [String: [NormalizedLeaf]] = [:], frames: [String: [CGRect]] = [:],
                primaryScreenKey: String? = nil, gapPoints: CGFloat = 0) {
        self.screens = screens
        self.frames = frames
        self.primaryScreenKey = primaryScreenKey
        self.gapPoints = gapPoints.isFinite ? max(0, gapPoints) : 0
    }

    public init(_ screens: [String: [NormalizedLeaf]]) {
        self.init(screens: screens)
    }

    public init(leaves: [String: [NormalizedLeaf]], frames: [String: [CGRect]] = [:],
                gapPoints: CGFloat = 0) {
        self.init(screens: leaves, frames: frames,
                  primaryScreenKey: frames.keys.sorted().first, gapPoints: gapPoints)
    }

    /// Convenience for integrations that already have resolved frames.  The
    /// frames are normalized against their union so rebase remains usable.
    public init(frames: [String: [CGRect]], gapPoints: CGFloat = 0) {
        var leaves: [String: [NormalizedLeaf]] = [:]
        for (screen, rects) in frames {
            guard !rects.isEmpty else {
                leaves[screen] = []
                continue
            }
            let bounds = rects.reduce(CGRect.null) { partial, rect in
                partial.isNull ? rect : partial.union(rect)
            }
            let width = bounds.width > 0 ? bounds.width : 1
            let height = bounds.height > 0 ? bounds.height : 1
            leaves[screen] = rects.enumerated().map { index, rect in
                NormalizedLeaf(
                    index: index,
                    rect: CGRect(x: (rect.minX - bounds.minX) / width,
                                 y: (rect.minY - bounds.minY) / height,
                                 width: rect.width / width,
                                 height: rect.height / height),
                    screenKey: screen)
            }
        }
        self.init(screens: leaves, frames: frames, gapPoints: gapPoints)
    }

    public func leaves(for screenKey: String) -> [NormalizedLeaf] {
        screens[screenKey] ?? []
    }

    public var screenKeys: [String] {
        Set(screens.keys).union(frames.keys).sorted()
    }

    /// Return the exact raw rectangle from Zones, before Tiles spacing.
    /// Navigation uses this method so a visual gap never changes which tile is
    /// geometrically adjacent to another tile.
    public func rawFrame(for address: TileAddress) -> CGRect? {
        if let screenFrames = frames[address.screenKey],
           screenFrames.indices.contains(address.leafIndex) {
            return screenFrames[address.leafIndex]
        }
        if let leaf = leaves(for: address.screenKey).first(where: { $0.index == address.leafIndex }) {
            return leaf.rect
        }
        return nil
    }

    public func frame(for address: TileAddress) -> CGRect? {
        guard let raw = rawFrame(for: address) else { return nil }
        guard gapPoints.isFinite, gapPoints > 0, let screenFrames = frames[address.screenKey],
              screenFrames.indices.contains(address.leafIndex) else { return raw }
        return spacedFrame(at: address.leafIndex, in: screenFrames, gap: gapPoints)
    }

    public func address(for leaf: NormalizedLeaf, on screenKey: String? = nil) -> TileAddress {
        leaf.address(screenKey: screenKey)
    }

    public func allLeaves() -> [NormalizedLeaf] {
        screenKeys.flatMap { leaves(for: $0) }
    }

    // MARK: - Tile spacing

    /// Apply half the requested gap to each side that touches another leaf.
    /// This is deliberately based on raw Zones rectangles, not on a row/column
    /// assumption: a large leaf beside two smaller leaves (a T-junction) gets
    /// one inset on its shared side and each smaller leaf gets the matching
    /// inset.  Screen edges are never inset.
    private func spacedFrame(at index: Int, in rawFrames: [CGRect], gap: CGFloat) -> CGRect {
        guard rawFrames.indices.contains(index), gap > 0 else {
            return rawFrames.indices.contains(index) ? rawFrames[index] : .zero
        }

        let raw = rawFrames[index]
        guard !raw.isNull, raw.width > 0, raw.height > 0 else { return raw }
        let halfGap = gap / 2
        let tolerance: CGFloat = 0.01

        var insetLeft: CGFloat = 0
        var insetRight: CGFloat = 0
        var insetBottom: CGFloat = 0
        var insetTop: CGFloat = 0

        for (otherIndex, other) in rawFrames.enumerated() where otherIndex != index {
            guard !other.isNull, other.width > 0, other.height > 0 else { continue }
            if approximatelyEqual(raw.minX, other.maxX, tolerance: tolerance),
               overlapLength(raw.minY...raw.maxY, other.minY...other.maxY) > tolerance {
                insetLeft = halfGap
            }
            if approximatelyEqual(raw.maxX, other.minX, tolerance: tolerance),
               overlapLength(raw.minY...raw.maxY, other.minY...other.maxY) > tolerance {
                insetRight = halfGap
            }
            if approximatelyEqual(raw.minY, other.maxY, tolerance: tolerance),
               overlapLength(raw.minX...raw.maxX, other.minX...other.maxX) > tolerance {
                insetBottom = halfGap
            }
            if approximatelyEqual(raw.maxY, other.minY, tolerance: tolerance),
               overlapLength(raw.minX...raw.maxX, other.minX...other.maxX) > tolerance {
                insetTop = halfGap
            }
        }

        // A very small leaf must stay usable.  Scale the two insets on each
        // axis together when the requested gap would collapse that axis below
        // one point.  This preserves symmetry at a T-junction and keeps the
        // result deterministic for arbitrarily small templates.
        let horizontalScale = insetScale(length: raw.width,
                                         leading: insetLeft,
                                         trailing: insetRight)
        let verticalScale = insetScale(length: raw.height,
                                       leading: insetBottom,
                                       trailing: insetTop)
        insetLeft *= horizontalScale
        insetRight *= horizontalScale
        insetBottom *= verticalScale
        insetTop *= verticalScale

        let width = max(1, raw.width - insetLeft - insetRight)
        let height = max(1, raw.height - insetBottom - insetTop)
        return CGRect(x: raw.minX + insetLeft, y: raw.minY + insetBottom,
                      width: width, height: height)
    }

    private func insetScale(length: CGFloat, leading: CGFloat, trailing: CGFloat) -> CGFloat {
        let requested = leading + trailing
        guard requested > 0 else { return 1 }
        return min(1, max(0, (length - 1) / requested))
    }

    private func overlapLength(_ lhs: ClosedRange<CGFloat>, _ rhs: ClosedRange<CGFloat>) -> CGFloat {
        max(0, min(lhs.upperBound, rhs.upperBound) - max(lhs.lowerBound, rhs.lowerBound))
    }

    private func approximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat,
                                    tolerance: CGFloat) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}

/// Ordered windows sharing one tile.  Mutating operations reject duplicate
/// tokens and keep selection inside `order` at all times.
public struct TileStack: Equatable, Sendable {
    public var address: TileAddress
    public private(set) var order: [WindowToken]
    public private(set) var selected: WindowToken?

    /// Selection epoch is model metadata, not persisted identity.  It lets a
    /// layout merge choose the most recently focused member deterministically.
    public private(set) var selectionEpoch: UInt64

    public init(address: TileAddress,
                order: [WindowToken] = [],
                selected: WindowToken? = nil,
                selectionEpoch: UInt64 = 0) {
        self.address = address
        var unique: [WindowToken] = []
        for token in order where !unique.contains(token) { unique.append(token) }
        self.order = unique
        self.selected = selected.flatMap { unique.contains($0) ? $0 : nil }
        if self.selected == nil { self.selected = unique.first }
        self.selectionEpoch = self.selected == nil ? 0 : selectionEpoch
    }

    public var isEmpty: Bool { order.isEmpty }

    public func contains(_ token: WindowToken) -> Bool { order.contains(token) }

    @discardableResult
    public mutating func append(_ token: WindowToken, selecting: Bool = false, epoch: UInt64? = nil) -> Bool {
        guard !order.contains(token) else { return false }
        order.append(token)
        if selected == nil || selecting {
            selected = token
            selectionEpoch = epoch ?? selectionEpoch
        }
        return true
    }

    @discardableResult
    public mutating func insert(_ token: WindowToken, at index: Int, selecting: Bool = false, epoch: UInt64? = nil) -> Bool {
        guard !order.contains(token) else { return false }
        let position = min(max(index, 0), order.count)
        order.insert(token, at: position)
        if selected == nil || selecting {
            selected = token
            selectionEpoch = epoch ?? selectionEpoch
        }
        return true
    }

    @discardableResult
    public mutating func remove(_ token: WindowToken) -> Bool {
        guard let index = order.firstIndex(of: token) else { return false }
        let wasSelected = selected == token
        order.remove(at: index)
        guard !order.isEmpty else {
            selected = nil
            selectionEpoch = 0
            return true
        }
        if wasSelected {
            // Prefer the item that followed the closed member; if it was the
            // last item, wrap to the previous member.
            selected = order[min(index, order.count - 1)]
        } else if let current = selected, !order.contains(current) {
            selected = order[min(index, order.count - 1)]
        }
        return true
    }

    @discardableResult
    public mutating func select(_ token: WindowToken, epoch: UInt64? = nil) -> Bool {
        guard order.contains(token) else { return false }
        selected = token
        if let epoch { selectionEpoch = epoch }
        return true
    }

    public func appending(_ token: WindowToken, selecting: Bool = false, epoch: UInt64? = nil) -> TileStack {
        var copy = self
        _ = copy.append(token, selecting: selecting, epoch: epoch)
        return copy
    }

    public func inserting(_ token: WindowToken, at index: Int, selecting: Bool = false, epoch: UInt64? = nil) -> TileStack {
        var copy = self
        _ = copy.insert(token, at: index, selecting: selecting, epoch: epoch)
        return copy
    }

    public func removing(_ token: WindowToken) -> TileStack {
        var copy = self
        _ = copy.remove(token)
        return copy
    }

    public func selecting(_ token: WindowToken, epoch: UInt64? = nil) -> TileStack {
        var copy = self
        _ = copy.select(token, epoch: epoch)
        return copy
    }
}

public enum WindowVisibility: Equatable, Sendable {
    case visible
    case stagedByTiles
    case minimizedByUser
}

public struct ManagedWindow: Equatable, Sendable {
    public let token: WindowToken
    public var workspace: WorkspaceID
    public var tile: TileAddress
    public var visibility: WindowVisibility
    public var adoptionFrame: CGRect
    public var lastAppliedFrame: CGRect?
    public var focusEpoch: UInt64

    public init(token: WindowToken,
                workspace: WorkspaceID,
                tile: TileAddress,
                visibility: WindowVisibility = .visible,
                adoptionFrame: CGRect,
                lastAppliedFrame: CGRect? = nil,
                focusEpoch: UInt64 = 0) {
        self.token = token
        self.workspace = workspace
        self.tile = tile
        self.visibility = visibility
        self.adoptionFrame = adoptionFrame
        self.lastAppliedFrame = lastAppliedFrame
        self.focusEpoch = focusEpoch
    }
}

public struct Workspace: Equatable, Sendable {
    public let id: WorkspaceID
    public var screens: [String: [TileStack]]

    public init(id: WorkspaceID, screens: [String: [TileStack]] = [:]) {
        self.id = id
        self.screens = screens
    }

    public var allStacks: [TileStack] {
        screens.keys.sorted().flatMap { screens[$0] ?? [] }
    }

    public func stack(for address: TileAddress) -> TileStack? {
        screens[address.screenKey]?.first(where: { $0.address.id == address.id })
    }

    public func location(of token: WindowToken) -> (screenKey: String, index: Int)? {
        for screen in screens.keys.sorted() {
            if let index = screens[screen]?.firstIndex(where: { $0.contains(token) }) {
                return (screen, index)
            }
        }
        return nil
    }
}

public struct MutationID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UInt64) {
        self.init(rawValue: rawValue)
    }
}

public struct Transition: Equatable, Sendable {
    public let mutationID: MutationID
    public let from: WorkspaceID?
    public let to: WorkspaceID?

    public init(mutationID: MutationID,
                from: WorkspaceID? = nil,
                to: WorkspaceID? = nil) {
        self.mutationID = mutationID
        self.from = from
        self.to = to
    }
}

public struct TilesSession: Equatable, Sendable {
    public var activeWorkspace: WorkspaceID
    public var workspaces: [WorkspaceID: Workspace]
    public var windows: [WindowToken: ManagedWindow]
    public var nextFocusEpoch: UInt64
    public var transition: Transition?

    /// Monotonic pure-model generation.  It is separate from focus epochs so
    /// a late AX result can never commit an older mutation.
    public var mutationGeneration: UInt64

    public init(activeWorkspace: WorkspaceID = .workspace1,
                workspaces: [WorkspaceID: Workspace] = [:],
                windows: [WindowToken: ManagedWindow] = [:],
                nextFocusEpoch: UInt64 = 0,
                transition: Transition? = nil,
                mutationGeneration: UInt64 = 0) {
        self.activeWorkspace = activeWorkspace
        var complete = workspaces
        for id in WorkspaceID.all where complete[id] == nil {
            complete[id] = Workspace(id: id)
        }
        self.workspaces = complete
        self.windows = windows
        self.nextFocusEpoch = nextFocusEpoch
        self.transition = transition
        self.mutationGeneration = mutationGeneration
    }

    public static var empty: TilesSession { TilesSession() }

    public var active: Workspace? { workspaces[activeWorkspace] }

    public mutating func ensureFourWorkspaces() {
        for id in WorkspaceID.all where workspaces[id] == nil {
            workspaces[id] = Workspace(id: id)
        }
    }

    public func validate() throws {
        guard activeWorkspace.isValid else {
            throw TilesModelError.invalidWorkspaceID(activeWorkspace.rawValue)
        }
        guard Set(workspaces.keys) == Set(WorkspaceID.all) else {
            throw TilesModelError.workspaceCount(workspaces.count)
        }

        var owners: [WindowToken: (WorkspaceID, TileAddress)] = [:]
        for id in WorkspaceID.all {
            guard let workspace = workspaces[id], workspace.id == id else {
                throw TilesModelError.workspaceKeyMismatch(id)
            }
            for stacks in workspace.screens.values {
                for stack in stacks {
                    guard stack.selected == nil ? stack.order.isEmpty : stack.order.contains(stack.selected!) else {
                        throw TilesModelError.invalidSelection(stack.address.id)
                    }
                    var local = Set<WindowToken>()
                    for token in stack.order {
                        guard local.insert(token).inserted else {
                            throw TilesModelError.duplicateWindow(token)
                        }
                        guard owners[token] == nil else {
                            throw TilesModelError.duplicateWindow(token)
                        }
                        owners[token] = (id, stack.address)
                    }
                }
            }
        }

        guard owners.count == windows.count else {
            throw TilesModelError.membershipMismatch
        }
        for (token, managed) in windows {
            guard let owner = owners[token], owner.0 == managed.workspace,
                  owner.1 == managed.tile else {
                throw TilesModelError.membershipMismatch
            }
        }
    }

    public var isValid: Bool { (try? validate()) != nil }

    /// Validate membership against the current Zones leaves as well as the
    /// in-memory uniqueness rules.
    public func validate(layouts: LayoutSnapshot) throws {
        try validate()
        for managed in windows.values {
            guard layouts.screens[managed.tile.screenKey]?.contains(where: {
                $0.index == managed.tile.leafIndex
            }) == true else {
                throw TilesModelError.unresolvedTile(managed.tile.id)
            }
        }
    }
}

public enum TilesModelError: Error, Equatable, Sendable {
    case invalidWorkspaceID(Int)
    case workspaceCount(Int)
    case workspaceKeyMismatch(WorkspaceID)
    case invalidSelection(TileID)
    case duplicateWindow(WindowToken)
    case membershipMismatch
    case inactiveWindowVisible(WindowToken)
    case unresolvedTile(TileID)
}

/// A live, immutable observation of one candidate window.  The AX layer owns
/// discovery; this value is all that crosses into TilesCore.
public struct WindowSnapshotEntry: Equatable, Sendable {
    public let token: WindowToken
    public var frame: CGRect
    public var screenKey: String
    public var isVisible: Bool
    public var isMinimized: Bool
    public var isEligible: Bool
    public var isReachable: Bool

    public init(token: WindowToken,
                frame: CGRect,
                screenKey: String = "",
                isVisible: Bool = true,
                isMinimized: Bool = false,
                isEligible: Bool = true,
                isReachable: Bool = true) {
        self.token = token
        self.frame = frame
        self.screenKey = screenKey
        self.isVisible = isVisible
        self.isMinimized = isMinimized
        self.isEligible = isEligible
        self.isReachable = isReachable
    }

    public init(token: WindowToken,
                screenKey: String,
                isVisible: Bool = true,
                isMinimized: Bool = false,
                isEligible: Bool = true,
                isReachable: Bool = true) {
        self.init(token: token,
                  frame: CGRect(x: 0, y: 0, width: 0, height: 0),
                  screenKey: screenKey,
                  isVisible: isVisible,
                  isMinimized: isMinimized,
                  isEligible: isEligible,
                  isReachable: isReachable)
    }

    public var isAvailableForPlacement: Bool {
        isEligible && isReachable && isVisible && !isMinimized
    }

    public var visible: Bool {
        get { isVisible }
        set { isVisible = newValue }
    }

    public var minimized: Bool {
        get { isMinimized }
        set { isMinimized = newValue }
    }

    public var eligible: Bool {
        get { isEligible }
        set { isEligible = newValue }
    }

    public var reachable: Bool {
        get { isReachable }
        set { isReachable = newValue }
    }
}

public struct WindowSnapshot: Equatable, Sendable {
    public var windows: [WindowToken: WindowSnapshotEntry]
    public var focused: WindowToken?
    public var goneTokens: Set<WindowToken>

    public init(windows: [WindowToken: WindowSnapshotEntry] = [:], focused: WindowToken? = nil,
                goneTokens: Set<WindowToken> = []) {
        self.windows = windows
        self.focused = focused
        self.goneTokens = goneTokens
    }

    public init(_ entries: [WindowSnapshotEntry], focused: WindowToken? = nil,
                goneTokens: Set<WindowToken> = []) {
        self.init(windows: Dictionary(uniqueKeysWithValues: entries.map { ($0.token, $0) }),
                  focused: focused, goneTokens: goneTokens)
    }

    public var focusedEntry: WindowSnapshotEntry? {
        guard let focused else { return nil }
        return windows[focused]
    }

    public var focusedWindow: WindowToken? {
        get { focused }
        set { focused = newValue }
    }

    public var entries: [WindowToken: WindowSnapshotEntry] {
        get { windows }
        set { windows = newValue }
    }

    public func entry(for token: WindowToken) -> WindowSnapshotEntry? { windows[token] }

    public var eligible: [WindowSnapshotEntry] {
        windows.values.filter(\.isEligible).sorted { $0.token.rawValue.uuidString < $1.token.rawValue.uuidString }
    }
}

public typealias LiveWindow = WindowSnapshotEntry
public typealias SnapshotWindow = WindowSnapshotEntry

public enum TileCycleDirection: Equatable, Sendable {
    case forward
    case reverse
}

public typealias CycleDirection = TileCycleDirection

public enum TilesEvent: Equatable, Sendable {
    case reconcile
    case adoptVisible
    case adopt(WindowToken)
    case windowCreated(WindowToken)
    case windowClosed(WindowToken)
    case focus(WindowToken)
    case externalActivation(WindowToken)
    case cycleFocusedTile(TileCycleDirection)
    case focusTile(TileDirection)
    case switchWorkspace(WorkspaceID)
    case nextWorkspace
    case previousWorkspace
    case moveFocusedWindow(to: WorkspaceID)
    case moveFocusedWindowToTile(TileDirection)
    /// A shell-level request to edit the focused Zones parent split.  The
    /// actual write belongs to the Zones mutation seam; keeping the event in
    /// the shared vocabulary lets the coordinator route the request without
    /// teaching TilesCore about the Zones tree.
    case toggleFocusedSplitOrientation
    case minimize(WindowToken, byUser: Bool)
    case restore(WindowToken)
    case place(WindowToken, at: TileAddress)
    case detach(WindowToken)
    case layoutChanged
}

public enum WindowEffect: Equatable, Sendable {
    case setFrame(WindowToken, CGRect, MutationID)
    case setMinimized(WindowToken, Bool, MutationID)
    case raise(WindowToken, MutationID)
    case focus(WindowToken, MutationID)

    public var token: WindowToken {
        switch self {
        case let .setFrame(token, _, _), let .setMinimized(token, _, _),
             let .raise(token, _), let .focus(token, _): return token
        }
    }

    public var mutationID: MutationID {
        switch self {
        case let .setFrame(_, _, mutationID), let .setMinimized(_, _, mutationID),
             let .raise(_, mutationID), let .focus(_, mutationID): return mutationID
        }
    }
}

public enum WindowEffectFailure: Equatable, Sendable {
    case cannotComplete
    case invalidElement
    case unsupportedAttribute
    case rejectedFrame
    case goneWindow
    case timeout
    case staleMutation
    case cancelled
}

public enum WindowEffectStatus: Equatable, Sendable {
    case succeeded
    case failed(WindowEffectFailure)
}

public struct WindowEffectResult: Equatable, Sendable {
    public let effect: WindowEffect
    public let status: WindowEffectStatus

    public init(effect: WindowEffect, status: WindowEffectStatus) {
        self.effect = effect
        self.status = status
    }

    public init(effect: WindowEffect, success: Bool) {
        self.init(effect: effect, status: success ? .succeeded : .failed(.cannotComplete))
    }

    public init(effect: WindowEffect, succeeded: Bool) {
        self.init(effect: effect, success: succeeded)
    }

    public static func success(_ effect: WindowEffect) -> WindowEffectResult {
        WindowEffectResult(effect: effect, status: .succeeded)
    }

    public static func failure(_ effect: WindowEffect,
                                _ reason: WindowEffectFailure = .cannotComplete) -> WindowEffectResult {
        WindowEffectResult(effect: effect, status: .failed(reason))
    }

    public var succeeded: Bool {
        if case .succeeded = status { return true }
        return false
    }

    public var isSuccess: Bool { succeeded }

    public var isGone: Bool {
        if case .failed(.goneWindow) = status { return true }
        return false
    }
}

public struct TilesPlan: Equatable, Sendable {
    public let event: TilesEvent
    public let baseGeneration: UInt64
    public let mutationID: MutationID
    public let effects: [WindowEffect]
    public let compensation: [WindowEffect]
    public let nextState: TilesSession
    public let isNoOp: Bool

    public init(event: TilesEvent,
                baseGeneration: UInt64,
                mutationID: MutationID,
                effects: [WindowEffect],
                compensation: [WindowEffect] = [],
                nextState: TilesSession,
                isNoOp: Bool = false) {
        self.event = event
        self.baseGeneration = baseGeneration
        self.mutationID = mutationID
        self.effects = effects
        self.compensation = compensation
        self.nextState = nextState
        self.isNoOp = isNoOp
    }

    public var generation: UInt64 { mutationID.rawValue }
    public var requiredEffects: [WindowEffect] { effects }
    public var proposedState: TilesSession { nextState }
    public var windowEffects: [WindowEffect] { effects }
}
