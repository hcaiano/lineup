import Foundation
import CyclerCore

/// The Cycler tool's persisted section.
///
/// Deliberately does NOT carry hyper-key state — that is the Hyperkey tool's section.
/// `CyclerConfig` (which still has `hyperKey`) remains the decoder for the legacy
/// `~/.config/cycler/bindings.json` file only; see `LegacyImport`.
public struct CyclerToolSettings: Codable, Equatable {
    public var bindings: [AppBinding]

    public init(bindings: [AppBinding] = []) {
        self.bindings = bindings
    }

    private enum CodingKeys: String, CodingKey { case bindings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bindings = try c.decodeIfPresent([AppBinding].self, forKey: .bindings) ?? []
    }

    /// Delegates to `CyclerConfig`'s tested coalescing logic so there is exactly one
    /// implementation of "duplicate combos become one app group".
    public func coalescingDuplicateShortcuts() -> CyclerToolSettings {
        CyclerToolSettings(bindings: CyclerConfig(bindings: bindings)
            .coalescingDuplicateShortcuts().bindings)
    }
}
