import Foundation
import ScrollCore

/// Scroll preferences. Each value reverses the macOS direction; the system setting is unchanged.
///
/// The defaults cover the common request: a traditional mouse wheel with a natural trackpad.
/// Horizontal reversal starts off because apps turn horizontal scrolling into page navigation.
public struct ScrollSettings: Codable, Equatable {
    public var reverseMouse = true
    public var reverseTrackpad = false
    public var reverseVertical = true
    public var reverseHorizontal = false
    public var constantWheelScrolling = false
    public var wheelLines = 3
    private var extra: [String: JSONValue] = [:]

    private static let keys = ["reverseMouse", "reverseTrackpad", "reverseVertical", "reverseHorizontal",
                               "constantWheelScrolling", "wheelLines"]

    public init() {}

    /// The axes reversed for each device.
    public var reversal: ScrollReversal {
        var axes: ScrollAxes = []
        if reverseVertical { axes.insert(.vertical) }
        if reverseHorizontal { axes.insert(.horizontal) }
        return ScrollReversal(mouse: reverseMouse ? axes : [], trackpad: reverseTrackpad ? axes : [])
    }

    public var options: ScrollOptions {
        ScrollOptions(reversal: reversal, wheelLines: constantWheelScrolling ? wheelLines : nil)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let defaults = ScrollSettings()
        reverseMouse = try c.decodeIfPresent(Bool.self, forKey: AnyCodingKey("reverseMouse")) ?? defaults.reverseMouse
        reverseTrackpad = try c.decodeIfPresent(Bool.self, forKey: AnyCodingKey("reverseTrackpad")) ?? defaults.reverseTrackpad
        reverseVertical = try c.decodeIfPresent(Bool.self, forKey: AnyCodingKey("reverseVertical")) ?? defaults.reverseVertical
        reverseHorizontal = try c.decodeIfPresent(Bool.self, forKey: AnyCodingKey("reverseHorizontal")) ?? defaults.reverseHorizontal
        constantWheelScrolling = try c.decodeIfPresent(Bool.self, forKey: AnyCodingKey("constantWheelScrolling"))
            ?? defaults.constantWheelScrolling
        wheelLines = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("wheelLines")) ?? defaults.wheelLines
        guard (1...10).contains(wheelLines) else {
            throw DecodingError.dataCorruptedError(forKey: AnyCodingKey("wheelLines"), in: c,
                                                  debugDescription: "Wheel lines must be between 1 and 10.")
        }
        extra = try c.unknownValues(besides: Set(Self.keys))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(reverseMouse, forKey: AnyCodingKey("reverseMouse"))
        try c.encode(reverseTrackpad, forKey: AnyCodingKey("reverseTrackpad"))
        try c.encode(reverseVertical, forKey: AnyCodingKey("reverseVertical"))
        try c.encode(reverseHorizontal, forKey: AnyCodingKey("reverseHorizontal"))
        try c.encode(constantWheelScrolling, forKey: AnyCodingKey("constantWheelScrolling"))
        try c.encode(wheelLines, forKey: AnyCodingKey("wheelLines"))
        try c.encodeExtra(extra)
    }
}
