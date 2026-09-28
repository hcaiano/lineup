import AppCore
import Foundation
import Sparkle

/// The app's single Sparkle updater. Stable and Nightly use the same bundle identity and feed;
/// the delegate opts into the `nightly` channel only when the user's persisted choice (or the
/// build marker on a first install) says so. Sparkle always includes its default channel.
@MainActor
enum AppUpdater {
    /// True only when running from the assembled .app bundle. A bare `swift run` executable
    /// has no Info.plist, so starting Sparkle there fails and shows an alert on every launch.
    static let isBundled = Bundle.main.bundleIdentifier == Product.bundleID

    private static let delegate = ChannelDelegate(channel: Product.buildChannel)
    /// A track change whose schedule reset still has to reach Sparkle. `resetUpdateCycle` does
    /// nothing while `sessionInProgress` is true, and Sparkle also sets that flag during the
    /// installer probe it runs before scheduling each check, a probe that ends without any
    /// delegate callback. So the reset waits for the flag to fall, whatever raised it.
    private static var needsResetWhenIdle = false
    private static var sessionObservation: NSKeyValueObservation?

    /// A Nightly the user downloaded and then dismissed. Sparkle keeps it and resumes it on the
    /// next check BEFORE it reads the feed, so `allowedChannels` cannot filter it, and one that
    /// began installing still installs when Lineup quits. Until the user skips or installs it,
    /// a switch to Stable is only pending, and Settings says so.
    private(set) static var hasDeferredNightly = false {
        didSet {
            guard hasDeferredNightly != oldValue else { return }
            onDeferredNightlyChange?()
        }
    }
    /// Set by the shell so an open Settings window refreshes when the deferred Nightly resolves.
    static var onDeferredNightlyChange: (() -> Void)?

    /// `startingUpdater: isBundled` begins scheduled update checks as soon as the shell first
    /// touches this controller after loading config; dev runs never start the updater.
    static let shared = SPUStandardUpdaterController(
        startingUpdater: isBundled,
        updaterDelegate: delegate,
        userDriverDelegate: nil)

    /// Select the channel after the shell has loaded the authoritative config, before the one
    /// Sparkle controller starts. AppUpdater does not read config.json itself: the shell owns the
    /// load outcome and passes the fail-closed result here.
    static func start(channel: UpdateChannel) {
        delegate.channel = channel
        _ = shared
        guard isBundled, sessionObservation == nil else { return }
        sessionObservation = shared.updater.observe(\.sessionInProgress, options: [.new]) { _, change in
            guard change.newValue == false else { return }
            // Sparkle flips the flag inside its own completion blocks, before it schedules the
            // next check. Reset only after that block unwinds, and only if still idle.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { resetIfIdle() }
            }
        }
    }

    /// The channel currently supplied to Sparkle. The default channel is implicit and is always
    /// included by Sparkle, so Stable returns an empty additional-channel set.
    static var channel: UpdateChannel { delegate.channel }

    /// Apply the channel that survived the shared config write. The caller must persist first.
    /// The delegate answers with the new channel at once, so no later feed read can use the old
    /// one; the schedule reset that makes Sparkle check again waits until Sparkle is idle.
    static func apply(channel: UpdateChannel) {
        guard delegate.channel != channel else { return }
        delegate.channel = channel
        // A command-line development run never started the updater, so there is no cycle to reset.
        guard isBundled else { return }
        needsResetWhenIdle = true
        resetIfIdle()
    }

    private static func resetIfIdle() {
        guard needsResetWhenIdle, !shared.updater.sessionInProgress else { return }
        needsResetWhenIdle = false
        // Sparkle compares the allowed channels with its last check and fires a new check at once
        // when they differ.
        shared.updater.resetUpdateCycle()
    }

    fileprivate static func userDidMake(_ choice: SPUUserUpdateChoice,
                                        forUpdate item: SUAppcastItem,
                                        stage: SPUUserUpdateStage) {
        guard item.channel == UpdateChannel.nightlySparkleChannel else { return }
        // Dismissing a downloaded or installing Nightly keeps it; skipping or installing it ends
        // the wait. Dismissing one that was never downloaded leaves nothing behind.
        hasDeferredNightly = choice == .dismiss && stage != .notDownloaded
    }

    /// Resolve the loaded config without taking ownership of config.json. A rejected load cannot
    /// provide a preference, so it follows this bundle's marker; a Nightly app must not become
    /// trapped on the Stable feed just because its config is temporarily unreadable.
    static func initialChannel(config: LineupAppConfig,
                               state: LineupAppConfigStore.State) -> UpdateChannel {
        guard state == .ok, config.schemaVersion <= LineupAppConfig.currentSchema else {
            return Product.buildChannel
        }
        return config.general.effectiveUpdateChannel(buildChannel: Product.buildChannel)
    }
}

/// Sparkle retains the updater delegate weakly. Keeping this object as a static property also
/// gives the one controller a stable, live answer when Settings changes the channel.
@MainActor
private final class ChannelDelegate: NSObject, SPUUpdaterDelegate {
    var channel: UpdateChannel

    init(channel: UpdateChannel) {
        self.channel = channel
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        return channel.sparkleAllowedChannels
    }

    func updater(_ updater: SPUUpdater,
                 userDidMake choice: SPUUserUpdateChoice,
                 forUpdate updateItem: SUAppcastItem,
                 state: SPUUserUpdateState) {
        AppUpdater.userDidMake(choice, forUpdate: updateItem, stage: state.stage)
    }
}
