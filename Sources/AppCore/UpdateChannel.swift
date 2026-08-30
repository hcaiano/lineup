import Foundation

/// The public update channels Lineup can receive from its one Sparkle feed.
///
/// The persisted value is deliberately optional in `GeneralConfig`. A missing value means that
/// the install follows its build marker (`stable` for the public build, `nightly` for a Nightly
/// build). Once a user chooses a channel, the explicit choice wins across installs and updates.
public enum UpdateChannel: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
    case stable
    case nightly

    public static let defaultChannel: UpdateChannel = .stable
    public static let nightlySparkleChannel = "nightly"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .stable: return "Stable"
        case .nightly: return "Nightly"
        }
    }

    public var sparkleAllowedChannels: Set<String> {
        switch self {
        case .stable: return []
        case .nightly: return [Self.nightlySparkleChannel]
        }
    }

    /// The user-facing explanation for the one channel picker in Settings.
    public var settingsDescription: String {
        switch self {
        case .stable: return "Tested releases."
        case .nightly:
            return "Newest public builds, which may be less reliable. Returning to Stable waits "
                + "for a newer Stable release; Lineup does not downgrade automatically."
        }
    }

    /// Resolve a stored preference against the channel marker embedded in the app bundle.
    public static func effective(preference: UpdateChannel?, buildChannel: UpdateChannel) -> UpdateChannel {
        preference ?? buildChannel
    }
}

/// Version values embedded by `Scripts/build-app.sh` in the app bundle.
public enum BuildChannelMarker {
    public static let infoPlistKey = "LineupBuildChannel"

    /// Invalid or missing markers fail closed to Stable. A malformed bundle must never opt a user
    /// into prerelease updates by accident.
    public static func fromInfoPlist(_ value: Any?) -> UpdateChannel {
        guard let raw = value as? String, let channel = UpdateChannel(rawValue: raw) else {
            return .stable
        }
        return channel
    }
}

/// Helpers for the numeric-with-prerelease-suffix `CFBundleVersion` used by Nightly builds.
///
/// Apple permits a development suffix on an otherwise numeric bundle version. The current
/// Stable build is the first component, the UTC day ordinal since 2026-01-01 is packed into the
/// two two-digit revision components, and the sequence is a zero-padded suffix number. For the
/// current Stable build 19, this produces `19.00.01a001`, which Sparkle orders above `19` and
/// below the next Stable build `20`. The non-zero revision component is intentional: Sparkle's
/// comparator treats trailing zero components as equal, so `19.00.00` could sort as Stable 19.
/// This preserves a clean Stable supersession path while still making Nightly versions monotonic
/// by date and sequence.
public enum NightlyBuildVersion {
    public static let firstSequence = 1
    public static let maximumSequence = 255
    public static let referenceDateComponents = DateComponents(year: 2026, month: 1, day: 1)

    public static func value(date: Date,
                             sequence: Int,
                             stableBuild: Int,
                             calendar: Calendar? = nil) -> String? {
        guard (firstSequence...maximumSequence).contains(sequence) else { return nil }
        guard (1...9999).contains(stableBuild) else { return nil }
        let utc = calendar ?? utcCalendar
        guard let reference = utc.date(from: referenceDateComponents),
              let dayOffset = utc.dateComponents([.day], from: reference, to: date).day,
              (0...9998).contains(dayOffset) else {
            return nil
        }
        // Number the first day as ordinal 1. This avoids an all-zero version, which Sparkle
        // treats as equivalent to the current Stable build. The resulting range is 00.01–99.99.
        let ordinal = dayOffset + 1
        let revision = ordinal / 100
        let fix = ordinal % 100
        guard revision <= 99 else { return nil }
        return String(format: "%d.%02d.%02da%03d", stableBuild, revision, fix, sequence)
    }

    /// Apple’s documented shape, including the development suffix allowed for unreleased builds.
    /// The first component is at most four digits; the second and third are at most two digits;
    /// the suffix build number is 1 through 255.
    public static func isAppleValid(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }

        // Keep parsing explicit rather than accepting arbitrary punctuation through a loose
        // regular expression. This is also usable by the dependency-free test runner.
        let suffixStart = value.firstIndex(where: { $0.isLetter })
        let numeric = suffixStart.map { String(value[..<$0]) } ?? value
        let numbers = numeric.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(numbers.count), numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return false
        }
        guard numbers[0].count <= 4, numbers.dropFirst().allSatisfy({ $0.count <= 2 }),
              numbers[0].first != "0" else { return false }
        guard let suffixStart else { return true }
        let suffix = String(value[suffixStart...])
        let prefix: String
        let sequenceString: String
        if suffix.hasPrefix("fc") {
            prefix = "fc"
            sequenceString = String(suffix.dropFirst(2))
        } else if let first = suffix.first, ["d", "a", "b"].contains(first) {
            prefix = String(first)
            sequenceString = String(suffix.dropFirst())
        } else {
            return false
        }
        guard !prefix.isEmpty, !sequenceString.isEmpty,
              sequenceString.allSatisfy(\.isNumber), let sequence = Int(sequenceString) else { return false }
        return (firstSequence...maximumSequence).contains(sequence)
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
