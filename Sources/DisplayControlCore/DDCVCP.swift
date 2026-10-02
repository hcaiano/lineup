public enum DDCVCPTransport: Equatable, Sendable {
    case i2c
    case ioAV
}

public enum DDCVCPError: Error, Equatable, Sendable {
    case unsupported
    case malformed
}

/// Some DDC controllers reply with the previous request's value. After a successful Set VCP,
/// the first valid Get VCP reply can still predate that write. Each connection owns this state.
public struct DDCVCPReadback: Sendable {
    private var needsFreshReply: Set<DisplayControl> = []

    public init() {}

    public mutating func didWrite(_ control: DisplayControl) {
        needsFreshReply.insert(control)
    }

    public mutating func accept(_ level: DisplayControlLevel,
                                control: DisplayControl) -> DisplayControlLevel? {
        if needsFreshReply.remove(control) != nil { return nil }
        return level
    }
}

/// DDC/CI framing for the two continuous VCP controls used by Display Control.
public enum DDCVCP {
    public static func readPacket(_ control: DisplayControl,
                                  transport: DDCVCPTransport) -> [UInt8] {
        var payload: [UInt8] = [0x82, 0x01, code(control)]
        if transport == .i2c { payload.insert(0x51, at: 0) }
        return payload + [payload.reduce(0x6e, ^)]
    }

    public static func writePacket(_ control: DisplayControl, value: UInt16,
                                   transport: DDCVCPTransport) -> [UInt8] {
        var packet: [UInt8] = [0x51, 0x84, 0x03, code(control),
                               UInt8(value >> 8), UInt8(value & 0xff)]
        packet.append(packet.reduce(0x6e, ^))
        // IOAV supplies the source address itself, but the Set VCP checksum still includes it.
        if transport == .ioAV { packet.removeFirst() }
        return packet
    }

    public static func parseReply(_ bytes: [UInt8], control: DisplayControl)
        -> Result<DisplayControlLevel, DDCVCPError> {
        guard bytes.count == 11, bytes[0] == 0x6e, bytes[1] == 0x88, bytes[2] == 0x02,
              bytes[4] == code(control), bytes[5] == 0x00,
              bytes.dropLast().reduce(0x50, ^) == bytes[10] else { return .failure(.malformed) }
        if bytes[3] == 0x01 { return .failure(.unsupported) }
        guard bytes[3] == 0x00,
              let level = DisplayControlLevel(current: UInt16(bytes[8]) << 8 | UInt16(bytes[9]),
                                              maximum: UInt16(bytes[6]) << 8 | UInt16(bytes[7]))
        else { return .failure(.malformed) }
        return .success(level)
    }

    private static func code(_ control: DisplayControl) -> UInt8 {
        control == .brightness ? 0x10 : 0x62
    }
}
