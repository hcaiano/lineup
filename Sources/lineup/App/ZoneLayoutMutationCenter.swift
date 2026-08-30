import Foundation
import ZonesCore

/// The small shell-owned boundary through which Tiles asks Zones to edit a layout.
///
/// Tiles never receives a `Node`, a config store, or a screen object here. It sends only the
/// stable screen key and the live leaf index. Zones installs the handler while it is attached,
/// so the request remains available even when the Zones tool is switched off.
@MainActor
enum ZoneLayoutMutationResult: Equatable {
    case changed(Axis)
    case unavailable(String)

    /// Short feedback suitable for a Tiles HUD or menu confirmation.
    var userFacingText: String {
        switch self {
        case .changed(.vertical): return "Side by Side"
        case .changed(.horizontal): return "Stacked"
        case .unavailable(let message): return message
        }
    }
}

/// A single, weakly-owned request handler shared by Zones and Tiles.
///
/// The center itself owns no layout state. Replacing the handler is safe during a tool restart;
/// an old `ZonesTool` is not retained because its closure captures it weakly.
@MainActor
final class ZoneLayoutMutationCenter {
    typealias Handler = (String, Int) -> ZoneLayoutMutationResult

    private var handler: Handler?

    /// The center carries no actor-bound state until the handler is installed. Keeping creation
    /// nonisolated lets dependency-injected coordinator defaults remain usable from their
    /// synchronous initializers; all requests and handler installation still run on the main
    /// actor with the class.
    nonisolated init() {}

    func installHandler(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func toggleParentSplit(screenKey: String, leafIndex: Int) -> ZoneLayoutMutationResult {
        guard let handler else {
            return .unavailable("Zones is unavailable.")
        }
        return handler(screenKey, leafIndex)
    }
}
