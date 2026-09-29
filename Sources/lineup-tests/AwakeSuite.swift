import Foundation
import AppCore

private final class RecordingPowerRequests: AwakePowerRequests {
    struct Request { let kind: AwakeRequestKind; let timeout: TimeInterval }
    var live: [UInt32: Request] = [:]
    var nextID: UInt32 = 1
    var failKind: AwakeRequestKind?
    var duplicateReleases = 0
    func acquire(_ kind: AwakeRequestKind, timeout: TimeInterval) throws -> UInt32 {
        if kind == failKind { throw Refused.request }
        let id = nextID
        nextID += 1
        live[id] = Request(kind: kind, timeout: timeout)
        return id
    }
    func release(_ id: UInt32) {
        if live.removeValue(forKey: id) == nil { duplicateReleases += 1 }
    }
    private enum Refused: Error { case request }
}

func runAwakeTests() throws {
    let power = RecordingPowerRequests()
    let session = AwakeSession(power: power)
    try session.start(duration: 60, keepDisplayOn: false, now: 100)
    check(session.isActive && power.live.count == 1 && power.live.values.first?.kind == .system,
          "Keep Awake starts with only an idle-system request when display is off")
    check(session.remaining(now: 115) == 45 && power.live.values.first?.timeout == 60,
          "countdown uses elapsed time and each power request has a system timeout")

    try session.setDisplayOn(true, now: 120)
    check(session.deadline == 160 && power.live.count == 2
            && power.live.values.allSatisfy { $0.timeout == 40 },
          "enabling display replaces requests without extending the original deadline")
    try session.setDisplayOn(false, now: 130)
    check(power.live.count == 1 && power.live.values.first?.kind == .system && session.deadline == 160,
          "disabling display releases its request and preserves the system session deadline")
    let unchanged = Set(power.live.keys)
    try session.setDisplayOn(false, now: 135)
    check(Set(power.live.keys) == unchanged, "unchanged display setting does not create duplicate requests")

    try session.start(duration: 120, keepDisplayOn: true, now: 140)
    check(session.deadline == 260 && power.live.count == 2
            && unchanged.isDisjoint(with: power.live.keys),
          "choosing a new duration replaces every old request and starts a new deadline")
    session.expire(now: 259)
    check(session.isActive, "a session remains active before its deadline")
    session.expire(now: 300)
    check(!session.isActive && power.live.isEmpty,
          "a delayed timer expires the session instead of adding missed time")
    try session.setDisplayOn(true, now: 310)
    check(!session.isActive && power.live.isEmpty, "editing display after expiration never restarts a session")

    for kind in [AwakeRequestKind.system, .display] {
        try session.start(duration: 30, keepDisplayOn: false, now: 400)
        power.failKind = kind
        var failed = false
        do { try session.start(duration: 60, keepDisplayOn: true, now: 410) }
        catch { failed = true }
        check(failed && !session.isActive && power.live.isEmpty,
              "request failure releases the replaced session and any partially acquired request: \(kind)")
        power.failKind = nil
        try session.start(duration: 60, keepDisplayOn: true, now: 420)
        check(session.isActive && power.live.count == 2, "request failure leaves session start retryable: \(kind)")
        session.cancel()
        session.cancel()
        check(power.live.isEmpty && power.duplicateReleases == 0,
              "repeated lifecycle cleanup releases each owned request once: \(kind)")
    }
    try session.start(duration: 10, keepDisplayOn: false, now: 500)
    try session.setDisplayOn(true, now: 511)
    check(!session.isActive && power.live.isEmpty,
          "display changes cannot revive a session whose timer callback has not run yet")
    do {
        let owned = AwakeSession(power: power)
        try owned.start(duration: 60, keepDisplayOn: true, now: 600)
    }
    check(power.live.isEmpty, "destroying a session owner releases outstanding requests")
    let restarted = AwakeSession(power: power)
    check(!restarted.isActive && power.live.isEmpty, "a new session owner never resumes the previous session")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lineup-awake-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.json")
    let store = LineupAppConfigStore(url: url)
    _ = store.load()
    try store.setSettings(["preserve": true], for: .zones)
    try store.setEnabled(true, for: .awake)
    var preferences = try JSONDecoder().decode(AwakeSettings.self,
        from: Data(#"{"durationMinutes":60,"keepDisplayOn":true,"futureOption":"preserve"}"#.utf8))
    preferences.durationMinutes = 120
    try store.setSettings(preferences, for: .awake)
    let loaded = LineupAppConfigStore(url: url)
    _ = loaded.load()
    check(try loaded.config.settings(AwakeSettings.self, for: .awake) == preferences,
          "Keep Awake preferences survive saving through the shared store and reloading")
    check(loaded.config.isEnabled(.awake) == true
            && loaded.config.section(for: .zones)?.settings["preserve"] == .bool(true)
            && loaded.config.section(for: .awake)?.settings["futureOption"] == .string("preserve"),
          "preference edits preserve tool enablement, siblings, and unknown future settings")

    for invalid in [#"{"durationMinutes":-1}"#, #"{"keepDisplayOn":"yes"}"#] {
        var rejected = false
        do { _ = try JSONDecoder().decode(AwakeSettings.self, from: Data(invalid.utf8)) }
        catch { rejected = true }
        check(rejected, "unsupported Keep Awake settings are rejected instead of replaced by defaults")
    }
    for rejectedData in [Data("broken".utf8), Data(#"{"schemaVersion":999}"#.utf8)] {
        try rejectedData.write(to: url)
        _ = loaded.load()
        var refused = false
        do { try loaded.setSettings(preferences, for: .awake) } catch { refused = true }
        let preserved = try Data(contentsOf: url)
        check(refused && preserved == rejectedData,
              "Keep Awake cannot overwrite a malformed or newer shared config")
    }
}
