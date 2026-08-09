import Foundation

/// Pure "press the key, which app should win?" math for a multi-app binding (an *app group*).
///
/// Where `WindowCycle` decides the next *window* of one app, this decides the next *app* of a
/// group, and gives up window cycling. The AppKit layer (Sources/cycler) owns the live process
/// list and the launch/activate/hide side effects; this type owns the *decision*, so the
/// round-robin behaviour is unit-testable without a running app. Keep it free of AppKit so it
/// builds under `swift run cycler-tests`.
///
/// It is intentionally **stateless**: every press recomputes the decision from the live
/// installed/running/frontmost snapshot. There is no remembered "current app", so hide↔activate
/// alternation falls out for free (hiding the frontmost app means the next press no longer sees it
/// as frontmost, so it activates it again).
public enum AppGroupCycle {
    /// What the app-side HUD should render for a group press, independent of AppKit names/icons.
    public struct Display: Equatable, Sendable {
        public var rows: [DisplayRow]
        public var selectedIndex: Int?
    }

    public struct DisplayRow: Equatable, Sendable {
        public var bundleIdentifier: String
        public var isRunning: Bool
        public var isSelected: Bool
    }

    /// What the caller should do with the group on this press. The payload is a bundle id drawn
    /// from `group`, so the caller never has to map an index back to an app.
    public enum Action: Equatable, Sendable {
        /// None of the group is running: launch this (the first *installed* app in group order).
        case launch(String)
        /// Bring this running app forward (un-hiding it if needed).
        case activate(String)
        /// The group's only running app is frontmost: hide it (a repeat press will re-activate it).
        case hide(String)
        /// Nothing to do — the group is empty, or none of its apps are installed.
        case none
    }

    public typealias Direction = WindowCycle.Direction

    /// Decide the action for one press of a group hotkey.
    ///
    /// - Parameters:
    ///   - group: the binding's apps, in the user's configured cycle order.
    ///   - installed: which of those apps are installed (resolvable to an app). Only consulted
    ///     when nothing in the group is running, to pick what to launch.
    ///   - running: which of those apps are currently running.
    ///   - frontmost: the bundle id of the frontmost app, if any (may be outside the group).
    ///   - direction: `.forward` advances in group order, `.backward` steps back.
    public static func next(
        group: [String],
        installed: Set<String>,
        running: Set<String>,
        frontmost: String?,
        direction: Direction = .forward
    ) -> Action {
        let runningInGroup = group.filter { running.contains($0) }

        // Nobody's home: launch the first installed app in order (skipping missing ones).
        guard let first = runningInGroup.first else {
            guard let toLaunch = group.first(where: { installed.contains($0) }) else { return .none }
            return .launch(toLaunch)
        }

        // Exactly one member up: toggle it. Frontmost → hide; otherwise bring it forward.
        guard runningInGroup.count > 1 else {
            return frontmost == first ? .hide(first) : .activate(first)
        }

        // Several members up: advance to the next/previous running app in group order. If the
        // frontmost app isn't one of them (we're entering the group from outside), enter at the
        // first running app going forward, or the last going backward.
        guard let current = frontmost, let idx = runningInGroup.firstIndex(of: current) else {
            return .activate(direction == .forward ? first : runningInGroup[runningInGroup.count - 1])
        }
        let count = runningInGroup.count
        let step = direction == .forward ? (idx + 1) % count : (idx - 1 + count) % count
        return .activate(runningInGroup[step])
    }

    /// Build the ordered group rows for display. Non-running apps stay in the list so skipped
    /// positions remain visible; only launch/activate actions select a target for the HUD.
    public static func display(group: [String], running: Set<String>, action: Action) -> Display {
        let selected: String?
        switch action {
        case .launch(let bundleIdentifier), .activate(let bundleIdentifier):
            selected = bundleIdentifier
        case .hide, .none:
            selected = nil
        }
        return Display(
            rows: group.map { bundleIdentifier in
                DisplayRow(
                    bundleIdentifier: bundleIdentifier,
                    isRunning: running.contains(bundleIdentifier),
                    isSelected: bundleIdentifier == selected)
            },
            selectedIndex: selected.flatMap { group.firstIndex(of: $0) })
    }
}
