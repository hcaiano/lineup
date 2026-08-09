import Foundation

/// What a shortcut recorder must do with one raw key-down.
public enum ShortcutCaptureIntent: Equatable, Sendable {
    /// Abandon the capture, leaving the previous value untouched (1.x's Esc).
    case cancel
    /// Unbind the field (1.x's Delete).
    case clear
    /// Take this key (plus whatever modifiers are held) as the new value.
    case record
    /// Not a legal value here — beep and keep capturing.
    case reject
}

/// The modifier-less half of the recorder's key rules, kept pure so it can be tested.
///
/// The ordering is the load-bearing part. Esc and Delete are checked BEFORE the bare-key
/// allowance, so a recorder that accepts a plain key (Zones' drag bind, where `F5`-drag is a
/// legitimate 1.x bind) can still be cancelled with Esc and reset with Delete — those two keys
/// are never capturable, whatever `allowsBareKey` says.
public enum ShortcutCaptureRules {
    /// - Parameters:
    ///   - isEscape: the caller's `keyCode == kVK_Escape` test.
    ///   - isDelete: the caller's `keyCode == kVK_Delete` test.
    ///   - hasModifier: ⌃/⌥/⇧/⌘ held. Fn and Caps Lock do not count, matching 1.x.
    ///   - allowsBareKey: this field accepts a key with no modifier at all.
    public static func intent(isEscape: Bool,
                              isDelete: Bool,
                              hasModifier: Bool,
                              allowsBareKey: Bool) -> ShortcutCaptureIntent {
        // With a modifier held, Esc and Delete are ordinary keys — ⌘⌫ is a bindable combo.
        if hasModifier { return .record }
        if isEscape { return .cancel }
        if isDelete { return .clear }
        return allowsBareKey ? .record : .reject
    }
}
