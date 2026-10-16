import CoreGraphics

public struct ShareTarget: Equatable {
    public let axis: Axis
    public let rect: CGRect
    public let incomingUnitRect: CGRect
    public let incumbentUnitRect: CGRect

    public static func targets(in zone: CGRect) -> [ShareTarget] {
        let tiles = [CGRect(x: zone.midX - 44, y: zone.midY + 24, width: 40, height: 32),
                     CGRect(x: zone.midX + 4, y: zone.midY + 24, width: 40, height: 32)]
        guard tiles.allSatisfy({ tile in
            zone.contains(tile) && [CGPoint(x: tile.minX, y: tile.minY), CGPoint(x: tile.maxX, y: tile.maxY)]
                .allSatisfy { DragTarget.rect(zone: zone, cursor: $0) == zone }
        }) else { return [] }
        return [ShareTarget(axis: .vertical, rect: tiles[0],
                            incomingUnitRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
                            incumbentUnitRect: CGRect(x: 0, y: 0, width: 0.5, height: 1)),
                ShareTarget(axis: .horizontal, rect: tiles[1],
                            incomingUnitRect: CGRect(x: 0, y: 0, width: 1, height: 0.5),
                            incumbentUnitRect: CGRect(x: 0, y: 0.5, width: 1, height: 0.5))]
    }
}

public struct ShareEntry {
    private var targets: [ShareTarget] = []
    private var previous: CGPoint?
    private var active: Int?
    private var canEnter: Set<Int> = []
    public init() {}

    public mutating func update(targets newTargets: [ShareTarget], cursor: CGPoint) -> ShareTarget? {
        if targets != newTargets {
            targets = newTargets
            active = nil
            previous = cursor
            canEnter = Set(targets.indices.filter { !targets[$0].rect.contains(cursor) })
            return nil
        }
        defer { previous = cursor }
        for index in targets.indices {
            if !targets[index].rect.contains(cursor) {
                canEnter.insert(index)
                if active == index { active = nil }
            }
            if canEnter.contains(index), let previous, (previous != cursor || active == index),
               targets[index].rect.contains(cursor) {
                active = index
                return targets[index]
            }
        }
        return nil
    }
}

public extension ZoneScene {
    /// The one current occupant of a zone when it fills the whole leaf. Records that are not
    /// current (closed, minimized, on another desktop, or moved) never count; two current
    /// occupants, a partial placement or a maximized window make the zone ineligible.
    /// Preview and release use this same rule.
    static func shareIncumbent<Window>(_ entries: [SnapRecords<Window>.Entry], screen: AppZonePlacement.Display,
                                       layout: Node, zoneIndex: Int,
                                       isCurrent: (SnapRecords<Window>.Entry) -> Bool) -> SnapRecords<Window>.Entry? {
        let occupants = entries.filter {
            $0.placement?.screenKey == screen.key && $0.placement?.layout == layout
                && $0.placement?.zoneIndex == zoneIndex && isCurrent($0)
        }
        guard occupants.count == 1, let incumbent = occupants.first, isWholeLeaf(incumbent, on: screen)
        else { return nil }
        return incumbent
    }

    static func share<Window>(incoming: Window, before: CGRect, incumbent: SnapRecords<Window>.Entry,
                              target: ShareTarget, screen: AppZonePlacement.Display) -> [FrameEffect<Window>]? {
        guard isWholeLeaf(incumbent, on: screen), let whole = incumbent.placement else { return nil }
        let first = AppZonePlacement(screenKey: whole.screenKey, layout: whole.layout,
                                     zoneIndex: whole.zoneIndex, unitRect: target.incumbentUnitRect)
        let second = AppZonePlacement(screenKey: whole.screenKey, layout: whole.layout,
                                      zoneIndex: whole.zoneIndex, unitRect: target.incomingUnitRect)
        guard let firstRect = first.rect(on: screen), let secondRect = second.rect(on: screen) else { return nil }
        return [FrameEffect(window: incumbent.window, before: incumbent.snappedTo, after: firstRect, placement: first),
                FrameEffect(window: incoming, before: before, after: secondRect, placement: second)]
    }
}

private extension ZoneScene {
    static func isWholeLeaf<Window>(_ entry: SnapRecords<Window>.Entry, on screen: AppZonePlacement.Display) -> Bool {
        guard entry.maximize == nil, let placement = entry.placement, placement.zoneIndex != nil,
              placement.screenKey == screen.key, placement.unitRect == CGRect(x: 0, y: 0, width: 1, height: 1),
              let expected = placement.rect(on: screen) else { return false }
        return SnapRecords<Window>.matches(expected, entry.snappedTo, originTolerance: 1, sizeTolerance: 1)
    }
}
