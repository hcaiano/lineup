import CoreGraphics
import DisplayControlCore
import DisplayHardware
import Foundation

struct DisplayTransportMonitor: Sendable {
    let monitor: DisplayControlMonitor
    let displayID: CGDirectDisplayID
    let connectionDescription: String
}

enum DisplayTransportFailure: Error, LocalizedError {
    case unsupported
    case ambiguous
    case disconnected
    case communication
    case invalidResponse
    case apiUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupported: return "This display or connection does not support this hardware control."
        case .ambiguous: return "The hardware connection cannot be matched to a single display safely."
        case .disconnected: return "The display connection changed. Refresh the displays and try again."
        case .communication: return "The display did not respond. Check its DDC/CI setting, cable or dock, then refresh."
        case .invalidResponse: return "The display returned an invalid reading. Refresh to try again."
        case .apiUnavailable: return "This macOS version does not expose the required hardware interface."
        }
    }

    init(_ result: LDHardwareResult) {
        switch result {
        case LDHardwareUnsupported: self = .unsupported
        case LDHardwareAmbiguous: self = .ambiguous
        case LDHardwareDisconnected: self = .disconnected
        case LDHardwareInvalidPacket: self = .invalidResponse
        case LDHardwareAPIUnavailable: self = .apiUnavailable
        default: self = .communication
        }
    }
}

/// Owns connection handles on the tool's serial queue. Discovery never applies saved levels.
/// A rebuilt list has new UUID tokens, so old commands cannot reach replacement displays.
// The tool confines every call and all mutable state to its single serial display queue.
final class DisplayTransport: @unchecked Sendable {
    private final class Connection {
        let native: OpaquePointer?
        let ddc: OpaquePointer?
        var levels: [DisplayControl: DisplayControlLevel] = [:]
        var readback = DDCVCPReadback()

        init(native: OpaquePointer?, ddc: OpaquePointer?) {
            self.native = native
            self.ddc = ddc
        }

        deinit {
            LDDisplayClose(native)
            LDDisplayClose(ddc)
        }
    }

    private var connections: [UUID: Connection] = [:]

    func invalidate() { connections = [:] }

    func discover() -> [DisplayTransportMonitor] {
        invalidate()
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displayIDs, &count) == .success else { return [] }
        return displayIDs.prefix(Int(count)).map { displayID in
            let token = UUID()
            let builtin = CGDisplayIsBuiltin(displayID) != 0
            var nativeResult = LDHardwareUnsupported
            var ddcResult = LDHardwareUnsupported
            let native = LDDisplayOpenNative(displayID, &nativeResult)
            let ddc = builtin ? nil : LDDisplayOpenDDC(displayID, &ddcResult)
            let connection = Connection(native: native, ddc: ddc)
            connections[token] = connection

            let brightness = probe(.brightness, connection: token,
                                   unavailable: native == nil && ddc == nil
                                    ? DisplayTransportFailure(builtin ? nativeResult : ddcResult) : nil)
            let volume = builtin
                ? DisplayControlStatus(availability: .unsupported("Built-in volume uses macOS sound controls."))
                : probe(.volume, connection: token,
                        unavailable: ddc == nil ? DisplayTransportFailure(ddcResult) : nil)
            let uuid = string { LDDisplayGetUUID(displayID, $0, $1) }
            let hardwareID = "\(CGDisplayVendorNumber(displayID)):\(CGDisplayModelNumber(displayID)):\(CGDisplaySerialNumber(displayID))"
            let name = string { LDDisplayGetName(displayID, $0, $1) }
            return DisplayTransportMonitor(
                monitor: DisplayControlMonitor(
                    stableID: uuid.isEmpty ? "hardware:\(hardwareID)" : "display:\(uuid.lowercased())",
                    connection: token,
                    name: name.isEmpty ? (builtin ? "Built-in Display" : "External Display") : name,
                    brightness: brightness, volume: volume
                ),
                displayID: displayID,
                connectionDescription: native != nil ? "Native brightness"
                    : ddc != nil ? "Hardware DDC/CI" : "Hardware control unavailable"
            )
        }
    }

    func read(_ control: DisplayControl, connection token: UUID)
        -> Result<DisplayControlLevel, DisplayTransportFailure> {
        guard let connection = connections[token] else { return .failure(.disconnected) }
        let result: Result<DisplayControlLevel, DisplayTransportFailure>
        if control == .brightness, let native = connection.native {
            var value: Float = 0
            let response = LDDisplayReadNative(native, &value)
            if response == LDHardwareSuccess,
               let level = DisplayControlLevel(current: UInt16((value * 1000).rounded()), maximum: 1000) {
                result = .success(level)
            } else {
                result = .failure(response == LDHardwareSuccess ? .invalidResponse : DisplayTransportFailure(response))
            }
        } else if let ddc = connection.ddc {
            result = readDDC(control, handle: ddc, connection: connection)
        } else { result = .failure(.unsupported) }

        switch result {
        case .success(let level):
            connection.levels[control] = level
        case .failure: connection.levels.removeValue(forKey: control)
        }
        return result
    }

    func write(_ value: UInt16, control: DisplayControl, connection token: UUID)
        -> Result<Void, DisplayTransportFailure> {
        guard let connection = connections[token] else { return .failure(.disconnected) }
        guard let reading = connection.levels[control], value <= reading.maximum else { return .failure(.invalidResponse) }
        let response: LDHardwareResult
        if control == .brightness, let native = connection.native {
            response = LDDisplayWriteNative(native, Float(value) / Float(reading.maximum))
        } else if let ddc = connection.ddc {
            let transport: DDCVCPTransport = LDDisplayDDCUsesIOAV(ddc) ? .ioAV : .i2c
            let packet = DDCVCP.writePacket(control, value: value, transport: transport)
            response = packet.withUnsafeBufferPointer {
                LDDisplayExchange(ddc, $0.baseAddress, UInt32($0.count), nil, 0)
            }
            if response == LDHardwareSuccess { connection.readback.didWrite(control) }
        } else { return .failure(.unsupported) }
        // A sent value is not a confirmed reading. Require a new read before another write.
        connection.levels.removeValue(forKey: control)
        return response == LDHardwareSuccess ? .success(()) : .failure(DisplayTransportFailure(response))
    }

    private func readDDC(_ control: DisplayControl, handle: OpaquePointer, connection: Connection)
        -> Result<DisplayControlLevel, DisplayTransportFailure> {
        let transport: DDCVCPTransport = LDDisplayDDCUsesIOAV(handle) ? .ioAV : .i2c
        let packet = DDCVCP.readPacket(control, transport: transport)
        var failure = DisplayTransportFailure.communication
        // Some monitor controllers return the previous VCP request's reply. Retrying only
        // reads, and checking the reply's VCP code, prevents brightness/volume mixups.
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.02) }
            var reply = [UInt8](repeating: 0, count: 11)
            let response = packet.withUnsafeBufferPointer { send in
                reply.withUnsafeMutableBufferPointer { receive in
                    LDDisplayExchange(handle, send.baseAddress, UInt32(send.count), receive.baseAddress, UInt32(receive.count))
                }
            }
            if response == LDHardwareSuccess {
                switch DDCVCP.parseReply(reply, control: control) {
                case .success(let level):
                    // A same-control reply can still predate Set VCP. The readback policy
                    // flushes it before a subsequent Get VCP request can confirm a level.
                    if let fresh = connection.readback.accept(level, control: control) { return .success(fresh) }
                case .failure(.unsupported): return .failure(.unsupported)
                case .failure(.malformed): failure = .invalidResponse
                }
            } else {
                failure = DisplayTransportFailure(response)
                if response != LDHardwareCommunicationFailed { return .failure(failure) }
            }
        }
        return .failure(failure)
    }

    private func probe(_ control: DisplayControl, connection: UUID,
                       unavailable: DisplayTransportFailure?) -> DisplayControlStatus {
        if let unavailable { return DisplayControlStatus(availability: .unsupported(unavailable.localizedDescription)) }
        switch read(control, connection: connection) {
        case .success(let level): return DisplayControlStatus(availability: .supported, level: level)
        case .failure(let failure): return DisplayControlStatus(availability: .unsupported(failure.localizedDescription))
        }
    }

    private func string(_ fill: (UnsafeMutablePointer<CChar>, UInt32) -> Void) -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        buffer.withUnsafeMutableBufferPointer { fill($0.baseAddress!, UInt32($0.count)) }
        return String(cString: buffer)
    }
}
