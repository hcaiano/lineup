import Foundation

/// Only routing preferences are saved. Display levels always come from the current connection.
public struct DisplayControlSettings: Codable, Equatable {
    public struct MonitorPreferences: Codable, Equatable {
        public var brightnessKeys = true
        public var volumeKeys = true
        /// Sync maps a common logical brightness through this display's hardware interval.
        public var brightnessMinimum = 0.0
        public var brightnessLimit = 1.0
        private var extra: [String: JSONValue] = [:]

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            brightnessKeys = try c.decodeIfPresent(Bool.self, forKey: AnyCodingKey("brightnessKeys")) ?? true
            volumeKeys = try c.decodeIfPresent(Bool.self, forKey: AnyCodingKey("volumeKeys")) ?? true
            brightnessMinimum = try c.decodeIfPresent(Double.self, forKey: AnyCodingKey("brightnessMinimum")) ?? 0
            brightnessLimit = try c.decodeIfPresent(Double.self, forKey: AnyCodingKey("brightnessLimit")) ?? 1
            guard brightnessLimit.isFinite, (0.05...1).contains(brightnessLimit) else {
                throw DecodingError.dataCorruptedError(forKey: AnyCodingKey("brightnessLimit"), in: c,
                                                       debugDescription: "brightnessLimit must be between 0.05 and 1")
            }
            guard brightnessMinimum.isFinite, brightnessMinimum >= 0, brightnessMinimum < brightnessLimit else {
                throw DecodingError.dataCorruptedError(forKey: AnyCodingKey("brightnessMinimum"), in: c,
                    debugDescription: "brightnessMinimum must be nonnegative and lower than brightnessLimit")
            }
            extra = try c.unknownValues(besides: ["brightnessKeys", "volumeKeys", "brightnessMinimum", "brightnessLimit"])
        }

        public func encode(to encoder: Encoder) throws {
            guard brightnessLimit.isFinite, (0.05...1).contains(brightnessLimit),
                  brightnessMinimum.isFinite, brightnessMinimum >= 0, brightnessMinimum < brightnessLimit else {
                throw EncodingError.invalidValue([brightnessMinimum, brightnessLimit], .init(codingPath: encoder.codingPath,
                    debugDescription: "brightness limits must satisfy 0 <= minimum < maximum <= 1 with maximum >= 0.05"))
            }
            var c = encoder.container(keyedBy: AnyCodingKey.self)
            try c.encode(brightnessKeys, forKey: AnyCodingKey("brightnessKeys"))
            try c.encode(volumeKeys, forKey: AnyCodingKey("volumeKeys"))
            try c.encode(brightnessMinimum, forKey: AnyCodingKey("brightnessMinimum"))
            try c.encode(brightnessLimit, forKey: AnyCodingKey("brightnessLimit"))
            try c.encodeExtra(extra)
        }
    }

    public var brightnessKeys = false
    public var volumeKeys = false
    public var synchronizeBrightness = false
    /// An extra Brightness Down at the minimum can cover a readable display with a black shade.
    /// Only the opt-in is saved; a screen's current blackout state never enters configuration.
    public var blackScreenBelowMinimum = false
    /// Nil targets the screen containing the pointer. A saved, disconnected display has no fallback.
    public var brightnessTarget: String?
    public var volumeTarget: String?
    public var monitors: [String: MonitorPreferences] = [:]
    private var extra: [String: JSONValue] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        brightnessKeys = try c.decodeIfPresent(Bool.self, forKey: AnyCodingKey("brightnessKeys")) ?? false
        volumeKeys = try c.decodeIfPresent(Bool.self, forKey: AnyCodingKey("volumeKeys")) ?? false
        synchronizeBrightness = try c.decodeIfPresent(Bool.self, forKey: AnyCodingKey("synchronizeBrightness")) ?? false
        blackScreenBelowMinimum = try c.decodeIfPresent(Bool.self, forKey: AnyCodingKey("blackScreenBelowMinimum")) ?? false
        brightnessTarget = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("brightnessTarget"))
        volumeTarget = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("volumeTarget"))
        monitors = try c.decodeIfPresent([String: MonitorPreferences].self, forKey: AnyCodingKey("monitors")) ?? [:]
        extra = try c.unknownValues(besides: ["brightnessKeys", "volumeKeys", "synchronizeBrightness", "blackScreenBelowMinimum", "brightnessTarget", "volumeTarget", "monitors"])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(brightnessKeys, forKey: AnyCodingKey("brightnessKeys"))
        try c.encode(volumeKeys, forKey: AnyCodingKey("volumeKeys"))
        try c.encode(synchronizeBrightness, forKey: AnyCodingKey("synchronizeBrightness"))
        try c.encode(blackScreenBelowMinimum, forKey: AnyCodingKey("blackScreenBelowMinimum"))
        try c.encodeIfPresent(brightnessTarget, forKey: AnyCodingKey("brightnessTarget"))
        try c.encodeIfPresent(volumeTarget, forKey: AnyCodingKey("volumeTarget"))
        try c.encode(monitors, forKey: AnyCodingKey("monitors"))
        try c.encodeExtra(extra)
    }
}
