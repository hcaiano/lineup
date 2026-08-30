import AppKit
import AppCore
import TilesCore
import ZonesCore

struct LiveScreen: Equatable, Sendable {
    let key: String
    let frame: CGRect
    let visibleFrame: CGRect
    let pixelsWide: Int

    @MainActor
    static func current() -> [LiveScreen] {
        NSScreen.screens.map { screen in
            let info = ScreenIdentity.info(for: screen)
            return LiveScreen(key: info.key, frame: screen.frame,
                              visibleFrame: screen.visibleFrame,
                              pixelsWide: max(info.pixelsWide, 1))
        }
    }
}

@MainActor
protocol ZoneLayoutSource: AnyObject {
    func snapshot(for screens: [LiveScreen]) throws -> LayoutSnapshot
    func observe(_ handler: @escaping () -> Void) -> ZoneLayoutObservation
}

@MainActor
final class ZoneLayoutObservation {
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

enum ZoneLayoutSourceError: LocalizedError {
    case invalidSettings(Error)

    var errorDescription: String? {
        switch self {
        case .invalidSettings(let error):
            return "The Zones layout is invalid: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class PersistedZoneLayoutSource: ZoneLayoutSource {
    private let store: LineupAppConfigStore

    init(store: LineupAppConfigStore) {
        self.store = store
    }

    func snapshot(for screens: [LiveScreen]) throws -> LayoutSnapshot {
        let config: LineupConfig
        do {
            config = try store.config.settings(LineupConfig.self, for: .zones) ?? LineupConfig()
            try config.validate()
        } catch {
            throw ZoneLayoutSourceError.invalidSettings(error)
        }

        var leavesByScreen: [String: [NormalizedLeaf]] = [:]
        var framesByScreen: [String: [CGRect]] = [:]
        for screen in screens {
            let root = config.layout(forKey: screen.key)
            let frames = Layout.zones(root, frame: screen.frame,
                                      visibleFrame: screen.visibleFrame,
                                      pixelsWide: screen.pixelsWide)
            let container = Layout.rootContainer(frame: screen.frame, visibleFrame: screen.visibleFrame)
            guard container.width > 0, container.height > 0, !frames.isEmpty else { continue }
            leavesByScreen[screen.key] = frames.enumerated().map { index, frame in
                NormalizedLeaf(
                    screenKey: screen.key,
                    index: index,
                    rect: CGRect(x: (frame.minX - container.minX) / container.width,
                                 y: (frame.minY - container.minY) / container.height,
                                 width: frame.width / container.width,
                                 height: frame.height / container.height))
            }
            framesByScreen[screen.key] = frames
        }
        return LayoutSnapshot(screens: leavesByScreen, frames: framesByScreen,
                              primaryScreenKey: screens.first?.key)
    }

    func observe(_ handler: @escaping () -> Void) -> ZoneLayoutObservation {
        let token = store.observeToolChanges { changed in
            guard changed.contains(.zones) else { return }
            DispatchQueue.main.async { handler() }
        }
        return ZoneLayoutObservation { token.cancel() }
    }
}
