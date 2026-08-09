import AppKit
import AppCore
import Darwin
import os

/// Runs every tool's teardown exactly once, on the exit paths the process can actually observe:
/// `applicationWillTerminate` (Quit, a Sparkle relaunch, a logout) and SIGINT/SIGTERM/SIGHUP,
/// whichever comes first.
///
/// It cannot cover SIGKILL, Force Quit or a crash — nothing can. What survives those is the
/// Caps Lock `hidutil` mapping, which is why its ownership is persisted: the next launch finds
/// the flag and clears the mapping, and `CapsLockHandoff` can offer to restore Caps Lock when
/// the owner never comes back at all.
///
/// Standalone Cycler installed its own SIGINT/SIGTERM/SIGHUP handler that stopped the hyper-key
/// controller and then `exit(128+sig)`'d — which, in a three-tool app, would skip Zones' and
/// Cycler's cleanups entirely. Ownership therefore moves here: tools register a cleanup block
/// and the shell fans out in reverse registration order.
///
/// `HyperKeyController`'s static `atexit` drain is still kept (Phase 6): it covers exit while a
/// `hidutil` remap is in flight, which no coordinator can.
@MainActor
final class TerminationCoordinator {
    static let shared = TerminationCoordinator()

    private var cleanups: [(id: ToolID, block: () -> Void)] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var didRunCleanups = false
    private let log = Logger(subsystem: Product.logSubsystem, category: "termination")

    /// Installed once, from `AppShell`.
    func installSignalHandlers() {
        guard signalSources.isEmpty else { return }
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            Darwin.signal(sig, SIG_IGN) // the DispatchSource is the handler now
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    TerminationCoordinator.shared.runCleanups()
                }
                fflush(stderr)
                exit(128 + sig)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Registered by a tool in `start()`, removed in `stop()`.
    func addCleanup(_ id: ToolID, _ block: @escaping () -> Void) {
        removeCleanup(id)
        cleanups.append((id, block))
    }

    func removeCleanup(_ id: ToolID) {
        cleanups.removeAll { $0.id == id }
    }

    /// Reverse registration order, once per process. Called from the signal handler and from
    /// `applicationWillTerminate`, whichever happens first.
    func runCleanups() {
        guard !didRunCleanups else { return }
        didRunCleanups = true
        for entry in cleanups.reversed() {
            log.debug("running cleanup for \(entry.id.rawValue, privacy: .public)")
            entry.block()
        }
    }
}
