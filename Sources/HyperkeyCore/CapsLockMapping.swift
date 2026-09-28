import Foundation

/// The `hidutil` Caps Lock -> F18 remap, as data.
///
/// Split out of `HyperKeyController` so the parsing is testable: the app target is an AppKit
/// executable the runner cannot import, and `hidutil property --get UserKeyMapping` prints a
/// CoreFoundation description whose key order, quoting and spacing are not guaranteed. Running
/// `hidutil` itself stays in the controller.
///
/// macOS 13–26 print one value for the whole event system. macOS 27 prints one row per HID
/// service instead, and a value can continue over the next lines:
///
///     RegistryID  Key                   Value
///     100000b49   UserKeyMapping   (null)
///     100000bb1   UserKeyMapping   (
///             {
///             HIDKeyboardModifierMappingDst = 30064771181;
///             HIDKeyboardModifierMappingSrc = 30064771129;
///         }
///     )
///
/// `hidutil property --set` without `--matching` still writes every service, so both formats
/// describe one mapping; services that do not hold the property keep printing `(null)`.
public enum CapsLockMapping {
    /// HID usage page 0x07 (keyboard), usage 0x39 — Caps Lock.
    public static let capsLockHID: UInt64 = 0x700000039
    /// HID usage page 0x07, usage 0x6D — F18. Nothing on a Mac keyboard produces it, which is
    /// why it is the hyper trigger.
    public static let f18HID: UInt64 = 0x70000006D

    /// One `Src -> Dst` remap.
    public struct Pair: Equatable {
        public let src: UInt64
        public let dst: UInt64

        public init(src: UInt64, dst: UInt64) {
            self.src = src
            self.dst = dst
        }
    }

    /// What one `hidutil` dump says about the Caps Lock remap.
    public enum State: Equatable {
        /// No service holds a mapping.
        case empty
        /// Every service that holds a mapping holds exactly Caps Lock -> F18.
        case lineup
        /// Caps Lock -> F18 on some services and an explicitly empty mapping (`()`) on others: the
        /// same shape, not installed everywhere. Only the per-service format can report this.
        case partialLineup
        /// Anything else, including output that could not be read completely.
        case foreign
    }

    /// Classifies a whole `hidutil property --get UserKeyMapping` dump.
    ///
    /// An EMPTY string is deliberately not `.empty`: that is what a `hidutil` that failed to run
    /// produces, and treating a failure as "nothing is mapped" would let us stomp on a mapping we
    /// never actually read. For the same reason a service table that is not readable line by
    /// line, or that has no rows, is `.foreign`.
    public static func state(of output: String) -> State {
        guard output.split(whereSeparator: \.isWhitespace).first == "RegistryID" else {
            if isNullValue(output) || isEmptyArray(output) { return .empty }
            return isLineupValue(output) ? .lineup : .foreign
        }
        guard let values = serviceValues(in: output), !values.isEmpty else { return .foreign }
        var mapped = 0
        var emptied = 0
        for value in values where !isNullValue(value) {
            if isEmptyArray(value) {
                emptied += 1
            } else if isLineupValue(value) {
                mapped += 1
            } else {
                return .foreign
            }
        }
        if mapped == 0 { return .empty }
        return emptied == 0 ? .lineup : .partialLineup
    }

    /// True when `hidutil` reports no user key mapping at all — on every service, in the
    /// per-service format.
    public static func isEmpty(_ output: String) -> Bool {
        state(of: output) == .empty
    }

    /// Every `Src -> Dst` pair in ONE printed value, split per printed dictionary so each Src
    /// keeps its own Dst. A REVERSED mapping (F18 -> Caps Lock) contains exactly the same two
    /// numbers, so matching them independently would claim somebody else's mapping as ours.
    public static func pairs(in output: String) -> [Pair] {
        output.components(separatedBy: "}").compactMap { entry in
            guard let src = firstValue(in: entry, forKey: "HIDKeyboardModifierMappingSrc"),
                  let dst = firstValue(in: entry, forKey: "HIDKeyboardModifierMappingDst")
            else { return nil }
            return Pair(src: src, dst: dst)
        }
    }

    /// Exactly the one mapping Lineup installs — and nothing else alongside it. Standalone Cycler
    /// and Raycast's Hyper Key install the identical pair, so this is a SHAPE test, never a
    /// statement of ownership (see `CapsLockHandoff`).
    ///
    /// A partial table counts: clearing it only empties services that hold our pair or nothing, so
    /// cleanup and recovery stay safe. Installing is stricter; see `HyperKeyController`.
    public static func isLineupMapping(_ output: String) -> Bool {
        let state = state(of: output)
        return state == .lineup || state == .partialLineup
    }

    private static func isNullValue(_ value: String) -> Bool {
        let compact = value.filter { !$0.isWhitespace }.lowercased()
        return compact == "(null)" || compact == "null"
    }

    private static func isEmptyArray(_ value: String) -> Bool {
        value.filter { !$0.isWhitespace } == "()"
    }

    private static func isLineupValue(_ value: String) -> Bool {
        isComplete(value) && pairs(in: value) == [Pair(src: capsLockHID, dst: f18HID)]
    }

    /// A printed array whose dictionaries all closed and all parsed. `pairs(in:)` skips a
    /// dictionary it cannot read, so a truncated dump could otherwise read as ours and a clear
    /// would take the skipped remap with it.
    private static func isComplete(_ value: String) -> Bool {
        let compact = value.filter { !$0.isWhitespace }
        guard compact.hasPrefix("("), compact.hasSuffix(")") else { return false }
        let opened = compact.filter { $0 == "{" }.count
        return opened == compact.filter { $0 == "}" }.count && opened == pairs(in: value).count
    }

    /// Each service's printed value in the macOS 27 table, or nil when a line is neither the
    /// header, a row, nor the continuation of a row. A row starts with a hexadecimal registry ID
    /// and the property key; other lines continue the row above it until its outer `(` closes.
    private static func serviceValues(in output: String) -> [String]? {
        var values: [String] = []
        var sawHeader = false
        var openParens = 0
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            if !sawHeader {
                if fields.isEmpty { continue }
                guard fields[0] == "RegistryID" else { return nil }
                sawHeader = true
            } else if fields.count >= 2, fields[1] == "UserKeyMapping" {
                guard fields[0].allSatisfy(\.isHexDigit) else { return nil }
                let value = fields.count == 3 ? String(fields[2]) : ""
                values.append(value)
                openParens = parenDepth(value)
            } else if fields.isEmpty {
                continue
            } else if !values.isEmpty, openParens > 0 {
                values[values.count - 1] += "\n" + line
                openParens += parenDepth(line)
            } else {
                return nil
            }
        }
        return values
    }

    private static func parenDepth(_ text: some StringProtocol) -> Int {
        text.reduce(0) { $0 + ($1 == "(" ? 1 : $1 == ")" ? -1 : 0) }
    }

    /// The value of `key` inside one printed dictionary. CoreFoundation prints these numbers in
    /// decimal; hexadecimal is accepted too, because the format is not contractual.
    private static func firstValue(in entry: String, forKey key: String) -> UInt64? {
        guard let range = entry.range(of: key) else { return nil }
        var tail = entry[range.upperBound...]
        // Skip the closing quote, the spaces and the '=' between the key and its value. A ';'
        // first means this entry has no value for the key.
        while let character = tail.first, !character.isHexDigit {
            if character == ";" { return nil }
            tail = tail.dropFirst()
        }
        if tail.hasPrefix("0x") || tail.hasPrefix("0X") {
            return UInt64(tail.dropFirst(2).prefix { $0.isHexDigit }, radix: 16)
        }
        return UInt64(tail.prefix { $0.isNumber })
    }
}
