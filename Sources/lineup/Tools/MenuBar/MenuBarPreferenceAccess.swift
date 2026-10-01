import AppCore
import Foundation
import CoreFoundation
import Darwin

/// Changes only the selected native visibility flags. Use the domain and its container:
/// treating the plist path as a domain can retain bytes without notifying MenuBarAgent.
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

    private enum ContainerPreferences {
        typealias Copy = @convention(c) (CFString, CFString, CFString, CFString, CFString) -> Unmanaged<AnyObject>?
        typealias Set = @convention(c) (CFString, CFPropertyList, CFString, CFString, CFString, CFString) -> Void
        typealias Synchronize = @convention(c) (CFString, CFString, CFString, CFString) -> UInt8
        static let copy = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CFPreferencesCopyValueWithContainer")
            .map { unsafeBitCast($0, to: Copy.self) }
        static let set = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CFPreferencesSetValueWithContainer")
            .map { unsafeBitCast($0, to: Set.self) }
        static let synchronize = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CFPreferencesSynchronizeWithContainer")
            .map { unsafeBitCast($0, to: Synchronize.self) }
        static let domain = "group.com.apple.controlcenter" as CFString
        static let key = "trackedApplications" as CFString

        static func container(for url: URL) -> CFString {
            url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path as CFString
        }
    }

    static var available: Bool {
        ContainerPreferences.copy != nil && ContainerPreferences.set != nil && ContainerPreferences.synchronize != nil
    }

    private static func read(at url: URL) throws -> Data {
        guard let copy = ContainerPreferences.copy, let synchronize = ContainerPreferences.synchronize,
              synchronize(ContainerPreferences.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost,
                          ContainerPreferences.container(for: url)) != 0,
              let data = copy(ContainerPreferences.key, ContainerPreferences.domain, kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost, ContainerPreferences.container(for: url))?.takeRetainedValue() as? Data else {
            throw Failure(message: "Menu bar settings could not be read. Grant access again in Menu Bar settings.")
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
            guard let set = ContainerPreferences.set, let synchronize = ContainerPreferences.synchronize else {
                throw Failure(message: "This version of macOS cannot change menu bar visibility safely.")
            }
            let container = ContainerPreferences.container(for: url)
            set(ContainerPreferences.key, try document.encoded() as CFData, ContainerPreferences.domain,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container)
            guard synchronize(ContainerPreferences.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container) != 0 else {
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
                throw Failure(message: "Restore the previous menu bar session before hiding icons again.")
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

    /// Extend the same recovery transaction when a selected app gains a new native record.
    static func extend(_ original: [String: Bool], journal: URL) throws {
        guard !original.isEmpty else { return }
        try withLock(journal) {
            let old = try JSONDecoder().decode(MenuBarRecoveryRecord.self, from: Data(contentsOf: journal))
            var merged = old.original
            for (key, value) in original where merged[key] == nil { merged[key] = value }
            let next = MenuBarRecoveryRecord(session: old.session, bookmark: old.bookmark, original: merged)
            try JSONEncoder().encode(next).write(to: journal, options: .atomic)
            try set(original.mapValues { _ in false }, bookmark: old.bookmark)
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
/// no app shell, config imports, shortcuts, updater or status items. It restores the
/// recorded native flags when its parent exits, including after SIGKILL.
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
