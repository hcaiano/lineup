import Darwin
import Foundation
import TilesCore

enum TilesRecoveryJournalStoreError: LocalizedError {
    case unsafePermissions(Int)
    case atomicReplaceFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .unsafePermissions(let mode):
            return "The Tiles recovery journal has unsafe permissions (\(String(mode, radix: 8)))."
        case .atomicReplaceFailed(let code):
            return "The Tiles recovery journal could not be replaced (errno \(code))."
        }
    }
}

final class TilesRecoveryJournalStore {
    let url: URL
    private let fileManager: FileManager

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lineup/tiles-recovery.json"),
         fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    func preflight() throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        guard fileManager.fileExists(atPath: url.path) else { return }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard mode & 0o077 == 0 else {
            throw TilesRecoveryJournalStoreError.unsafePermissions(mode)
        }
        _ = try load()
    }

    func load() throws -> RecoveryJournal {
        guard fileManager.fileExists(atPath: url.path) else { return RecoveryJournal() }
        return try RecoveryJournal.decode(Data(contentsOf: url))
    }

    func write(_ journal: RecoveryJournal) throws {
        try journal.validate()
        try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".tiles-recovery.\(UUID().uuidString).tmp")
        let data = try journal.encoded()
        guard fileManager.createFile(atPath: temporary.path, contents: data,
                                     attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? fileManager.removeItem(at: temporary) }

        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        guard Darwin.chmod(temporary.path, mode_t(0o600)) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw TilesRecoveryJournalStoreError.atomicReplaceFailed(errno)
        }
    }

    func remove() throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
