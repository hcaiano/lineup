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

    /// True when `hidutil` reports no user key mapping at all — on every service, in the
    /// per-service format.
    ///
    /// An EMPTY string is deliberately not "empty": that is what a `hidutil` that failed to run
    /// produces, and treating a failure as "nothing is mapped" would let us stomp on a mapping we
    /// never actually read. A service table with no rows is not "empty" for the same reason.
    public static func isEmpty(_ output: String) -> Bool {
        guard let values = serviceValues(in: output) else { return isEmptyValue(output) }
        return !values.isEmpty && values.allSatisfy(isEmptyValue)
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
    /// In the per-service format, every service that holds a mapping must hold exactly this one:
    /// a single service with a different remap means somebody else configured that device.
    public static func isLineupMapping(_ output: String) -> Bool {
        guard let values = serviceValues(in: output) else { return isLineupValue(output) }
        let mapped = values.filter { !isEmptyValue($0) }
        return !mapped.isEmpty && mapped.allSatisfy(isLineupValue)
    }

    private static func isEmptyValue(_ value: String) -> Bool {
        let compact = value.filter { !$0.isWhitespace }.lowercased()
        return compact == "()" || compact == "(null)" || compact == "null"
    }

    private static func isLineupValue(_ value: String) -> Bool {
        pairs(in: value) == [Pair(src: capsLockHID, dst: f18HID)]
    }

    /// Each service's printed value when `output` is the macOS 27 per-service table, or nil for
    /// the single-value format. A row starts with a hexadecimal registry ID and the property key;
    /// every other line continues the value of the row above it.
    private static func serviceValues(in output: String) -> [String]? {
        guard output.split(whereSeparator: \.isWhitespace).first == "RegistryID" else { return nil }
        var values: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            if fields.count >= 2, fields[0].allSatisfy(\.isHexDigit), fields[1] == "UserKeyMapping" {
                values.append(fields.count == 3 ? String(fields[2]) : "")
            } else if !values.isEmpty {
                values[values.count - 1] += "\n" + line
            }
        }
        return values
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
