import CoreGraphics
import Foundation

/// A destination belongs to an exact display and layout, never to a global shortcut number.
/// Layouts have no durable leaf IDs. Keeping the tree prevents a removed leaf's index from
/// silently referring to a different zone after an edit.
public struct AppZonePlacement: Codable, Equatable {
    public let screenKey: String
    public let layout: Node
    public let zoneIndex: Int?
    /// Relative to the leaf, or the root container for quick actions spanning several leaves.
    public let unitRect: CGRect

    public init(screenKey: String, layout: Node, target: CGRect,
                frame: CGRect, visibleFrame: CGRect, pixelsWide: Int) {
        self.screenKey = screenKey
        self.layout = layout
        let zones = Layout.zones(layout, frame: frame, visibleFrame: visibleFrame, pixelsWide: pixelsWide)
        zoneIndex = zones.firstIndex { $0.contains(target) }
        let container = zoneIndex.map { zones[$0] }
            ?? Layout.rootContainer(frame: frame, visibleFrame: visibleFrame)
        unitRect = CGRect(x: (target.minX - container.minX) / container.width,
                          y: (target.minY - container.minY) / container.height,
                          width: target.width / container.width, height: target.height / container.height)
    }

    public func rect(in config: LineupConfig, connectedKey: String,
                     frame: CGRect, visibleFrame: CGRect, pixelsWide: Int) -> CGRect? {
        guard connectedKey == screenKey, config.screens[screenKey]?.layout == layout,
              isValid else { return nil }
        let container: CGRect
        if let zoneIndex {
            guard let zone = Layout.zoneRect(index: zoneIndex, root: layout, frame: frame,
                                             visibleFrame: visibleFrame, pixelsWide: pixelsWide) else { return nil }
            container = zone
        } else {
            container = Layout.rootContainer(frame: frame, visibleFrame: visibleFrame)
        }
        return CGRect(x: container.minX + unitRect.minX * container.width,
                      y: container.minY + unitRect.minY * container.height,
                      width: unitRect.width * container.width, height: unitRect.height * container.height)
    }

    public var isValid: Bool {
        let values = [unitRect.origin.x, unitRect.origin.y, unitRect.width, unitRect.height]
        return values.allSatisfy { $0.isFinite } && unitRect.width > 0 && unitRect.height > 0
            && unitRect.minX >= 0 && unitRect.minY >= 0
            && unitRect.maxX <= 1.000001 && unitRect.maxY <= 1.000001
            && (zoneIndex.map { $0 >= 0 } ?? true)
    }
}

extension LineupConfig {
    /// Only successful explicit placements teach a destination. Free movement and automatic
    /// restoration never call this path; a failed move leaves the previous association intact.
    public mutating func rememberPlacement(_ placement: AppZonePlacement, for bundleID: String,
                                           succeeded: Bool) {
        guard succeeded, !bundleID.isEmpty, placement.isValid else { return }
        if appPlacements == nil { appPlacements = [:] }
        appPlacements?[bundleID] = placement
    }

    /// An editor proposal can predate a placement made while the editor was open. Carry the
    /// latest associations forward, invalidating edited layouts so deleted zones cannot return
    /// under a reused index, even if a later edit recreates the old tree.
    public mutating func preservePlacements(from current: LineupConfig) {
        appPlacements = current.appPlacements?.filter { _, placement in
            screens[placement.screenKey]?.layout == placement.layout
        }
    }
}

/// One pending restoration per newly launched process. Existing processes are seeded as seen
/// on start, so enabling Zones or restarting Lineup never rearranges an ongoing app session.
public struct ZoneLaunchRestoration {
    private var seen: Set<Int32>
    private var pending: [Int32: AppZonePlacement] = [:]

    public init(runningProcesses: Set<Int32> = []) { seen = runningProcesses }

    @discardableResult
    public mutating func launched(process: Int32, placement: AppZonePlacement?, accessibilityTrusted: Bool) -> Bool {
        guard seen.insert(process).inserted, accessibilityTrusted, let placement else { return false }
        pending[process] = placement
        return true
    }

    public mutating func firstWindow(process: Int32, isRegular: Bool,
                                     accessibilityTrusted: Bool) -> AppZonePlacement? {
        guard accessibilityTrusted else { pending[process] = nil; return nil }
        guard isRegular else { return nil }
        // Consume BEFORE target resolution or the AX write. Failure never selects a later window.
        return pending.removeValue(forKey: process)
    }

    public func isPending(_ process: Int32) -> Bool { pending[process] != nil }
    public mutating func cancel(_ process: Int32) { pending[process] = nil }
    public mutating func terminated(_ process: Int32) { pending[process] = nil; seen.remove(process) }
}
