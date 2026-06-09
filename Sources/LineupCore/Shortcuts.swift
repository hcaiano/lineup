import Foundation

/// One global shortcut: an action id bound to a key combo. `keyCode` is a Carbon virtual
/// key; `modifiers` is a Carbon modifier mask (cmd/opt/ctrl/shift bits). Stored as plain
/// ints so the model stays pure (no Carbon import in core).
public struct ShortcutBinding: Codable, Equatable {
    public var action: String   // "full"/"left"/... quick action, or "zone:N" positional
    public var keyCode: Int
    public var modifiers: Int

    public init(action: String, keyCode: Int, modifiers: Int) {
        self.action = action
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// The global shortcut set (same on every screen; targets resolve per-screen at fire time).
public struct Shortcuts: Codable, Equatable {
    public var bindings: [ShortcutBinding]

    public init(bindings: [ShortcutBinding] = []) {
        self.bindings = bindings
    }

    public func binding(for action: String) -> ShortcutBinding? {
        bindings.first { $0.action == action }
    }

    /// Replace (or add) the binding for `action`.
    public func setting(action: String, keyCode: Int, modifiers: Int) -> Shortcuts {
        var out = bindings.filter { $0.action != action }
        out.append(ShortcutBinding(action: action, keyCode: keyCode, modifiers: modifiers))
        return Shortcuts(bindings: out)
    }

    /// Remove the binding for `action` (leaves it unassigned).
    public func removing(action: String) -> Shortcuts {
        Shortcuts(bindings: bindings.filter { $0.action != action })
    }

    /// Actions whose combo collides with the given one (excluding `action` itself). Used by
    /// the recorder to warn before saving a duplicate.
    public func conflicts(keyCode: Int, modifiers: Int, excluding action: String) -> [String] {
        bindings.filter { $0.action != action && $0.keyCode == keyCode && $0.modifiers == modifiers }.map(\.action)
    }
}

/// Positional Zone-N action ids ("zone:1" = first zone). Indices are 1-based in the id,
/// 0-based when resolving against `Layout.zoneRect`.
public enum ZoneAction {
    public static func id(_ oneBased: Int) -> String { "zone:\(oneBased)" }

    /// 0-based zone index for a "zone:N" action id, or nil if it isn't one.
    public static func zeroBasedIndex(from action: String) -> Int? {
        guard action.hasPrefix("zone:"), let n = Int(action.dropFirst(5)), n >= 1 else { return nil }
        return n - 1
    }
}
