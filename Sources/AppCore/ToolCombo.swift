import Foundation

/// A key combination and the tool that has it bound.
///
/// This is the conflict source the Settings recorders check against, and it is deliberately NOT
/// the live Carbon registry: a tool that is switched off has unregistered every one of its
/// hotkeys, but it still OWNS the combos sitting in its `config.json` section. Answering "is this
/// combo taken?" from the registry alone let another tool's recorder silently claim one of them,
/// and the theft only surfaced when the user switched the first tool back on and its shortcut
/// failed to register.
///
/// Built from each registered tool's persisted section (running or not) plus anything currently
/// live, so the answer is the same whichever tools happen to be enabled right now.
public struct ToolCombo: Hashable, Sendable {
    public let owner: ToolID
    public let keyCode: Int
    /// Carbon modifier mask — the canonical form, as `RegisterEventHotKey` takes it.
    public let modifiers: UInt32

    public init(owner: ToolID, keyCode: Int, modifiers: UInt32) {
        self.owner = owner
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public extension Sequence where Element == ToolCombo {
    /// The first tool OTHER than `owner` that has this combo bound, or nil when it is free.
    ///
    /// `owner` is excluded here rather than by the caller so a pane can hand over the whole list:
    /// a tool re-recording one of its own combos is an internal move (Zones reassigns, Cycler
    /// merges), never a cross-tool conflict.
    func conflictOwner(keyCode: Int, modifiers: UInt32, excluding owner: ToolID) -> ToolID? {
        first {
            $0.owner != owner && $0.keyCode == keyCode && $0.modifiers == modifiers
        }?.owner
    }
}
