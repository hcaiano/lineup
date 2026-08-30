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
    private static var pendingChannelAfterSession: UpdateChannel?

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
        pendingChannelAfterSession = nil
        delegate.channel = channel
        _ = shared
    }

    /// The channel currently supplied to Sparkle. The default channel is implicit and is always
    /// included by Sparkle, so Stable returns an empty additional-channel set.
    static var channel: UpdateChannel { delegate.channel }

    /// Apply the channel that survived the shared config write. The caller must persist first;
    /// this changes Sparkle's live delegate and resets its schedule, or defers both until an
    /// active session finishes.
    static func apply(channel: UpdateChannel) {
        guard isBundled else {
            delegate.channel = channel
            return
        }
        if shared.updater.sessionInProgress {
            // Leave the active session on the channel it started with. A later delegate callback
            // applies the newest persisted choice and resets the cycle for future checks.
            pendingChannelAfterSession = delegate.channel == channel ? nil : channel
            return
        }
        pendingChannelAfterSession = nil
        guard delegate.channel != channel else { return }
        delegate.channel = channel
        // `resetUpdateCycle` is a user-setting change, not a manual check. Do not call it for a
        // command-line development run whose updater was never started.
        shared.updater.resetUpdateCycle()
    }

    fileprivate static func didFinishUpdateCycle(_ updater: SPUUpdater) {
        guard let channel = pendingChannelAfterSession else { return }
        pendingChannelAfterSession = nil
        delegate.channel = channel
        // Sparkle notifies the delegate before it schedules its ordinary next cycle. Let that
        // callback unwind first, then reset so the channel change wins the scheduling decision.
        DispatchQueue.main.async {
            updater.resetUpdateCycle()
        }
    }

    /// Resolve the loaded config without taking ownership of config.json. A rejected load, or a
    /// decoded schema newer than this build, always fails closed to Stable.
    static func initialChannel(config: LineupAppConfig,
                               state: LineupAppConfigStore.State) -> UpdateChannel {
        guard state == .ok, config.schemaVersion <= LineupAppConfig.currentSchema else {
            return .stable
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
                 didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: Error?) {
        AppUpdater.didFinishUpdateCycle(updater)
    }
}
