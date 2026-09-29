import Foundation

public struct TextCaptureSettings: Codable, Equatable {
    public struct Shortcut: Codable, Equatable {
        public let keyCode: Int
        public let modifiers: UInt32

        public init(keyCode: Int, modifiers: UInt32) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }

        public var isValid: Bool {
            // Carbon command, shift, option and control. A bare key must never be swallowed.
            let allowed: UInt32 = 256 | 512 | 2048 | 4096
            return (0...127).contains(keyCode) && modifiers != 0 && modifiers & ~allowed == 0
        }
    }

    public var shortcut: Shortcut?
    public var extra: [String: JSONValue]

    public init(shortcut: Shortcut? = nil, extra: [String: JSONValue] = [:]) {
        self.shortcut = shortcut
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        shortcut = try c.decodeIfPresent(Shortcut.self, forKey: AnyCodingKey("shortcut"))
        if let shortcut, !shortcut.isValid {
            throw DecodingError.dataCorruptedError(forKey: AnyCodingKey("shortcut"), in: c,
                                                   debugDescription: "Invalid Text Capture shortcut")
        }
        extra = try c.unknownValues(besides: ["shortcut"])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encodeIfPresent(shortcut, forKey: AnyCodingKey("shortcut"))
        try c.encodeExtra(extra)
    }
}
