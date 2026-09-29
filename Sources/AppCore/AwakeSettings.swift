import Foundation

/// Preferences only. A running session is never written to disk.
public struct AwakeSettings: Codable, Equatable {
    public static let durations = [15, 30, 60, 120]
    public var durationMinutes: Int = 30
    public var keepDisplayOn = false
    private var extra: [String: JSONValue] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        durationMinutes = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("durationMinutes")) ?? 30
        guard Self.durations.contains(durationMinutes) else {
            throw DecodingError.dataCorruptedError(forKey: AnyCodingKey("durationMinutes"), in: c,
                                                  debugDescription: "Unsupported Keep Awake duration")
        }
        keepDisplayOn = try c.decodeIfPresent(Bool.self, forKey: AnyCodingKey("keepDisplayOn")) ?? false
        extra = try c.unknownValues(besides: ["durationMinutes", "keepDisplayOn"])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(durationMinutes, forKey: AnyCodingKey("durationMinutes"))
        try c.encode(keepDisplayOn, forKey: AnyCodingKey("keepDisplayOn"))
        try c.encodeExtra(extra)
    }

    public static func durationLabel(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) minutes" : "\(minutes / 60) \(minutes == 60 ? "hour" : "hours")"
    }
}
