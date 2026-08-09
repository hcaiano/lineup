import Foundation

/// Optional, off-by-default built-in HyperKey. When `enabled`, Cycler itself makes the `triggerKey`
/// behave as Hyper system-wide, so users don't need Raycast/Karabiner. This is pure persisted
/// settings only; the actual key remapping lives in the AppKit target (Sources/cycler), never here.
public struct HyperKeySettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var triggerKey: TriggerKey
    /// `true` means Cycler's default Hyper (control+option+shift+command); `false` excludes Shift.
    public var includeShift: Bool

    public init(enabled: Bool = false, triggerKey: TriggerKey = .capsLock, includeShift: Bool = true) {
        self.enabled = enabled
        self.triggerKey = triggerKey
        self.includeShift = includeShift
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, triggerKey, includeShift
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        let decodedTrigger = try container.decodeIfPresent(TriggerKey.self, forKey: .triggerKey) ?? .capsLock
        triggerKey = TriggerKey.pickerCases.contains(decodedTrigger) ? decodedTrigger : .capsLock
        includeShift = try container.decodeIfPresent(Bool.self, forKey: .includeShift) ?? true
    }

    /// The default for a config that has never enabled HyperKey: off, Caps Lock, full Hyper.
    public static let disabled = HyperKeySettings()
}
