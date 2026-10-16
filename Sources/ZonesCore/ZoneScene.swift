import CoreGraphics

public enum ZoneScene {
    public static func divider<Window>(records: SnapRecords<Window>, screen: AppZonePlacement.Display,
                                        old: Node, new: Node) -> [FrameEffect<Window>] {
        records.entries.compactMap { entry in
            guard entry.maximize == nil, let placement = entry.placement,
                  placement.screenKey == screen.key, placement.layout == old,
                  let expected = placement.rect(on: screen),
                  SnapRecords<Window>.matches(expected, entry.snappedTo, originTolerance: 1, sizeTolerance: 1),
                  let rebased = placement.rebased(to: new),
                  let destination = rebased.rect(on: screen),
                  !SnapRecords<Window>.matches(destination, entry.snappedTo,
                                               originTolerance: 0.000001, sizeTolerance: 0.000001)
            else { return nil }
            return FrameEffect(window: entry.window, before: entry.snappedTo,
                               after: destination, placement: rebased)
        }
    }
}
