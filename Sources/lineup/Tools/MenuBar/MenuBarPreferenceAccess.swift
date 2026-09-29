import AppCore
import Foundation
import CoreFoundation
import Darwin

enum MenuBarPreferenceAccess {
    static var expectedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist")
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func access<T>(_ bookmark: Data, _ body: (URL) throws -> T) throws -> T {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.resolvingSymlinksInPath().standardizedFileURL
                == expectedURL.resolvingSymlinksInPath().standardizedFileURL else {
            throw Failure(message: "Choose the Control Center settings file shown by Lineup.")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // The explicit read verifies that the user's selected-file grant still works.
        _ = try Data(contentsOf: url)
        return try body(url)
    }

    private static func read(at url: URL) throws -> Data {
        let domain = url.deletingPathExtension().path as CFString
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
              let data = CFPreferencesCopyValue("trackedApplications" as CFString, domain,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Data else {
            throw Failure(message: "Control Center settings could not be read. Grant access again in Menu Bar settings.")
        }
        return data
    }

    static func snapshot(bookmark: Data) throws -> MenuBarPreferences {
        try access(bookmark) { try MenuBarPreferences(data: read(at: $0)) }
    }

    static func set(_ changes: [String: Bool], bookmark: Data) throws {
        guard !changes.isEmpty else { return }
        try access(bookmark) { url in
            let before = try read(at: url)
            var document = try MenuBarPreferences(data: before)
            try document.setAllowed(changes)
            // Avoid overwriting an edit observed between the read and write. Only
            // the tracked-app key is sent to cfprefsd; unrelated keys stay untouched.
            guard try read(at: url) == before else {
                throw Failure(message: "Menu bar settings changed in another app. Try again.")
            }
            let domain = url.deletingPathExtension().path as CFString
            CFPreferencesSetValue("trackedApplications" as CFString, try document.encoded() as CFData,
                                  domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
                throw Failure(message: "macOS could not save the menu bar change.")
            }
            let verified = try MenuBarPreferences(data: read(at: url))
            guard changes.allSatisfy({ verified.allowed[$0.key] == $0.value }) else {
                throw Failure(message: "macOS did not retain the menu bar change. Your previous visibility will be restored.")
            }
        }
    }

    static func restore(journal: URL, session: UUID? = nil) throws {
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        try withLock(journal) {
            guard FileManager.default.fileExists(atPath: journal.path) else { return }
            let record = try JSONDecoder().decode(MenuBarRecoveryRecord.self, from: Data(contentsOf: journal))
            guard session == nil || record.session == session else { return }
            let current = try snapshot(bookmark: record.bookmark)
            // Missing apps may have been uninstalled. Do not recreate their records.
            let restore = current.changesToRestore(original: record.original)
            try set(restore, bookmark: record.bookmark)
            try FileManager.default.removeItem(at: journal)
        }
    }

    static func prepare(_ record: MenuBarRecoveryRecord, journal: URL) throws {
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try withLock(journal) {
            guard !FileManager.default.fileExists(atPath: journal.path) else {
                throw Failure(message: "Restore the previous menu bar session before hiding items again.")
            }
            try JSONEncoder().encode(record).write(to: journal, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        }
    }

    static func hide(journal: URL, session: UUID) throws {
        try withLock(journal) {
            let record = try JSONDecoder().decode(MenuBarRecoveryRecord.self, from: Data(contentsOf: journal))
            guard record.session == session else { throw Failure(message: "The menu bar session changed. Try again.") }
            try set(record.original.mapValues { _ in false }, bookmark: record.bookmark)
        }
    }

    static func renewAccess(_ bookmark: Data, journal: URL) throws {
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        _ = try snapshot(bookmark: bookmark)
        try withLock(journal) {
            guard FileManager.default.fileExists(atPath: journal.path) else { return }
            let old = try JSONDecoder().decode(MenuBarRecoveryRecord.self, from: Data(contentsOf: journal))
            let renewed = MenuBarRecoveryRecord(session: old.session, bookmark: bookmark, original: old.original)
            try JSONEncoder().encode(renewed).write(to: journal, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        }
    }

    private static func withLock<T>(_ journal: URL, body: () throws -> T) throws -> T {
        let fd = open(journal.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw Failure(message: "The menu bar recovery record could not be opened.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw Failure(message: "Menu bar recovery is still finishing. Try again in a moment.")
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

private final class MenuBarRecoveryLifetime {
    private let lock = NSLock()
    private var stopped = false
    private var signals: [DispatchSourceSignal] = []

    init() {
        for number in [SIGTERM, SIGINT] {
            let source = TerminationCoordinator.recoverySignal(number) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.stopped = true
                self.lock.unlock()
            }
            signals.append(source)
        }
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    deinit { for source in signals { source.cancel() } }
}

/// The same signed executable runs this before creating NSApplication. It gets
/// no app shell, config imports, shortcuts, updater or status items.
func runMenuBarRecoveryIfRequested() -> Bool {
    let args = CommandLine.arguments
    guard args.dropFirst().first == "--menu-bar-recovery" else { return false }
    guard args.count == 6, let parent = Int32(args[4]), parent > 1,
          let session = UUID(uuidString: args[5]) else {
        fputs("Invalid Menu Bar recovery arguments.\n", stderr)
        return true
    }
    let journal = URL(fileURLWithPath: args[2])
    let ready = URL(fileURLWithPath: args[3])
    _ = setpgid(0, 0)
    let lifetime = MenuBarRecoveryLifetime()
    do {
        let record = try JSONDecoder().decode(MenuBarRecoveryRecord.self, from: Data(contentsOf: journal))
        guard record.session == session else { return true }
        _ = try MenuBarPreferenceAccess.snapshot(bookmark: record.bookmark)
        try Data(session.uuidString.utf8).write(to: ready, options: .atomic)
        while getppid() == parent && kill(parent, 0) == 0 && !lifetime.isStopped {
            Thread.sleep(forTimeInterval: 0.2)
        }
        for attempt in 0..<3 {
            do {
                try MenuBarPreferenceAccess.restore(journal: journal, session: session)
                break
            } catch {
                if attempt == 2 { throw error }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    } catch {
        // Keep the journal for the next launch or the Settings recovery action.
        fputs("Menu Bar recovery failed: \(error.localizedDescription)\n", stderr)
    }
    try? FileManager.default.removeItem(at: ready)
    return true
}
