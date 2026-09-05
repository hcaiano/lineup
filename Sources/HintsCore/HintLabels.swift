import Foundation

/// Deterministic fixed-length home-row label allocation.
///
/// Frozen keyboard map: alphabet `ASDFGHJKL`, case-insensitive; one character for up to 9
/// candidates, two up to 81, three up to 729, four up to 1,500 (the candidate budget).
/// Labels are uniform in length within a generation, which makes them prefix-safe: no label
/// is a proper prefix of another label in the same generation. Ordering is base-alphabet
/// Enumeration follows alphabet order (e.g. `a`, `s`, `d`, ..., `aa`, `as`, ..., `al`, `sa`).
public struct HintLabelMaker: Sendable, Hashable {

    public enum LabelError: Error, Equatable, Sendable {
        case emptyAlphabet
        case invalidCharacter(Character)
        case duplicateCharacter(Character)
        case nonPositiveMaxLength
        /// More candidates than the alphabet can cover within `maxLength`.
        case overflow(requested: Int, capacity: Int)
    }

    /// The frozen release alphabet.
    public static let defaultAlphabet = "ASDFGHJKL"

    /// Frozen cap on uniform label length (covers 1,500 candidates for the default alphabet).
    public static let defaultMaxLength = 4

    public let alphabet: String
    /// Lowercase letters of the alphabet, unique, in the configured order.
    public let normalizedAlphabet: [Character]
    public let maxLength: Int

    public init(alphabet: String, maxLength: Int = HintLabelMaker.defaultMaxLength) throws {
        let trimmed = alphabet
        guard !trimmed.isEmpty else { throw LabelError.emptyAlphabet }
        guard maxLength >= 1 else { throw LabelError.nonPositiveMaxLength }
        var seen = Set<Character>()
        var normalized: [Character] = []
        normalized.reserveCapacity(trimmed.count)
        for char in trimmed {
            guard char.isASCII, char.isLetter else { throw LabelError.invalidCharacter(char) }
            let lower = Character(char.lowercased())
            guard !seen.contains(lower) else { throw LabelError.duplicateCharacter(char) }
            seen.insert(lower)
            normalized.append(lower)
        }
        self.alphabet = trimmed
        self.normalizedAlphabet = normalized
        self.maxLength = maxLength
    }

    /// Lenient constructor: an invalid alphabet falls back to the frozen default so a bad
    /// config value never disables the tool outright. Returns the effective alphabet.
    public static func lenient(alphabet: String) -> HintLabelMaker {
        (try? HintLabelMaker(alphabet: alphabet)) ?? (try! HintLabelMaker(alphabet: HintLabelMaker.defaultAlphabet))
    }

    /// Total labels available at uniform `length` with this alphabet.
    public func capacity(length: Int) -> Int {
        guard !normalizedAlphabet.isEmpty, length >= 0 else { return 0 }
        var result = 1
        for _ in 0..<length {
            let base = normalizedAlphabet.count
            guard result <= (Int.max / base) else { return Int.max } // saturated; no overflow
            result *= base
        }
        return result
    }

    /// Total labels available at `maxLength`.
    public var maximumCapacity: Int { capacity(length: maxLength) }

    /// Smallest uniform fixed length covering `candidateCount`.
    /// `candidateCount <= 0` yields 0 (nothing to show); over `maximumCapacity` throws.
    public func requiredLength(candidateCount: Int) throws -> Int {
        guard candidateCount > 0 else { return 0 }
        let base = normalizedAlphabet.count
        var capacity = 1
        for length in 1...maxLength {
            guard capacity <= (Int.max / base) else {
                throw LabelError.overflow(requested: candidateCount, capacity: Int.max)
            }
            capacity *= base
            if capacity >= candidateCount { return length }
        }
        throw LabelError.overflow(requested: candidateCount, capacity: maximumCapacity)
    }

    /// Deterministic overflow truncation: the first `maximumCapacity` candidates survive;
    /// the remainder is reported so status surfaces can show a count-only truncation state.
    public struct Allocation: Equatable, Sendable {
        public let labels: [String]
        /// Candidates that did not receive a label.
        public let overflowed: Int

        public static func == (lhs: Allocation, rhs: Allocation) -> Bool {
            lhs.labels == rhs.labels && lhs.overflowed == rhs.overflowed
        }
    }

    /// `labels` has one entry per successfully labeled candidate; callers pair it by zip with
    /// the candidate list and must not index past it. Never varies for a given count.
    /// Overflow truncates deterministically (highest-ranked prefix keeps labels); only an
    /// invalidly configured maker makes this throw.
    public func allocate(candidateCount: Int) throws -> Allocation {
        guard candidateCount > 0 else { return Allocation(labels: [], overflowed: 0) }
        // The only throwing case of requiredLength is "beyond maximumCapacity", which is
        // exactly the truncation case: fall back to maxLength and drop the tail wholesale
        // rather than emitting partial or non-uniform labels.
        let length = (try? requiredLength(candidateCount: candidateCount)) ?? maxLength
        let usable = Swift.min(candidateCount, capacity(length: length))
        var labels: [String] = []
        labels.reserveCapacity(usable)
        let base = normalizedAlphabet.count
        for index in 0..<usable {
            labels.append(label(forIndex: index, length: length, base: base))
        }
        let overflowed = candidateCount - usable
        return Allocation(labels: labels, overflowed: overflowed)
    }

    public func labels(candidateCount: Int) throws -> [String] {
        try allocate(candidateCount: candidateCount).labels
    }

    func label(forIndex index: Int, length: Int, base: Int) -> String {
        var digits: [Character] = Array(repeating: normalizedAlphabet[0], count: length)
        var value = index
        for position in stride(from: length - 1, through: 0, by: -1) {
            digits[position] = normalizedAlphabet[value % base]
            value /= base
        }
        return String(digits)
    }
}
