import Foundation

/// Optional, off-by-default Hyperkey settings. When `enabled`, the Hyperkey tool makes the
/// `triggerKey` behave as Hyper system-wide, so users don't need Raycast/Karabiner. This is pure
/// persisted state; key remapping lives in Sources/lineup/Tools/Hyperkey, never here.
public struct HyperKeySettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var triggerKey: TriggerKey
    /// `true` includes Shift in the emitted Hyper modifiers; `false` leaves physical Shift
    /// available for Lineup's move and reverse shortcuts.
    public var includeShift: Bool

    public init(enabled: Bool = false, triggerKey: TriggerKey = .capsLock, includeShift: Bool = false) {
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
        // `includeShift` was added to the standalone Cycler config after its original Hyperkey
        // format. Preserve that format's full-Hyper behavior when an old object omits the field;
        // newly created settings use the compact default from `init` above.
        includeShift = try container.decodeIfPresent(Bool.self, forKey: .includeShift) ?? true
    }

    /// The default for a config that has never enabled Hyperkey: off, Caps Lock, no Shift.
    public static let disabled = HyperKeySettings()
}
