import ApplicationServices
import Foundation

enum PlacementTarget {
    case zone(screenKey: String, index: Int, frame: CGRect)
    case freeform(frame: CGRect)
}

struct WindowPlacementEvent {
    let window: AXUIElement
    let target: PlacementTarget
}

@MainActor
final class WindowPlacementObservation {
    private var cancelHandler: (() -> Void)?

    init(_ cancelHandler: @escaping () -> Void) {
        self.cancelHandler = cancelHandler
    }

    func cancel() {
        cancelHandler?()
        cancelHandler = nil
    }

    deinit { cancelHandler?() }
}

@MainActor
final class WindowPlacementCenter {
    private var observers: [UUID: (WindowPlacementEvent) -> Void] = [:]

    var normalizesPlacements: Bool { !observers.isEmpty }

    func observe(_ handler: @escaping (WindowPlacementEvent) -> Void) -> WindowPlacementObservation {
        let id = UUID()
        observers[id] = handler
        return WindowPlacementObservation { [weak self] in self?.observers[id] = nil }
    }

    func publish(_ event: WindowPlacementEvent) {
        for observer in observers.values { observer(event) }
    }
}
