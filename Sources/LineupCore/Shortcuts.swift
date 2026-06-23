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

/// Carbon modifier masks used by drag-snap. Kept in core so config fallback and exact
/// matching stay covered by the dependency-free test runner.
public enum DragSnapModifierMask {
    public static let command = 0x0100
    public static let shift = 0x0200
    public static let option = 0x0800
    public static let control = 0x1000
    public static let hyper = control | option | shift | command
    public static let all = control | option | shift | command
    public static let `default` = shift
    public static let choices = [
        shift,
        option,
        control,
        command,
        control | option,
        control | shift,
        option | shift,
        command | shift,
        control | command,
        option | command,
        control | option | shift,
        control | option | command,
        control | shift | command,
        option | shift | command,
        hyper,
    ]

    public static func normalized(_ modifiers: Int?) -> Int {
        let candidate = modifiers ?? Self.default
        return choices.contains(candidate) ? candidate : Self.default
    }

    public static func matches(active: Int, required: Int) -> Bool {
        (active & all) == normalized(required)
    }
}

public struct DragSnapTrigger: Equatable {
    public var keyCode: Int?
    public var modifiers: Int

    public init(keyCode: Int? = nil, modifiers: Int = DragSnapModifierMask.default) {
        self.keyCode = keyCode
        self.modifiers = keyCode == nil
            ? DragSnapModifierMask.normalized(modifiers)
            : modifiers & DragSnapModifierMask.all
    }

    public static let `default` = DragSnapTrigger()

    public func matches(activeKeyDown: Bool, activeModifiers: Int) -> Bool {
        guard (activeModifiers & DragSnapModifierMask.all) == modifiers else { return false }
        return keyCode == nil || activeKeyDown
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
