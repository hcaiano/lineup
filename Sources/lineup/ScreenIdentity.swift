import AppKit
import LineupCore

/// Builds a stable `ScreenInfo` for a live `NSScreen`. Primary key is the display's
/// hardware UUID (`CGDisplayCreateUUIDFromDisplayID`); when that's unavailable
/// (virtual/headless), a best-effort composite with a live display tie-breaker is used.
enum ScreenIdentity {
    static func info(for screen: NSScreen) -> ScreenInfo {
        let displayID = self.displayID(for: screen)
        let pxW = displayID.map { Int(CGDisplayPixelsWide($0)) } ?? Int(screen.frame.width)
        let pxH = displayID.map { Int(CGDisplayPixelsHigh($0)) } ?? Int(screen.frame.height)
        let label = screen.localizedName

        if let displayID, let uuidStr = uuidString(for: displayID) {
            return ScreenInfo(key: uuidStr, label: label, pixelsWide: pxW, pixelsHigh: pxH, keyIsStable: true)
        }

        // Fallback: composite of hardware identifiers + a live-display tie-breaker.
        let vendor = displayID.map { Int(CGDisplayVendorNumber($0)) } ?? 0
        let model = displayID.map { Int(CGDisplayModelNumber($0)) } ?? 0
        let serial = displayID.map { Int(CGDisplaySerialNumber($0)) } ?? 0
        let tieBreaker = fallbackTieBreaker(displayID: displayID, screen: screen)
        let key = ScreenKey.fallback(vendor: vendor, model: model, serial: serial,
                                     width: pxW, height: pxH, name: label, tieBreaker: tieBreaker)
        return ScreenInfo(key: key, label: label, pixelsWide: pxW, pixelsHigh: pxH, keyIsStable: false)
    }

    private static func fallbackTieBreaker(displayID: CGDirectDisplayID?, screen: NSScreen) -> String {
        if let displayID {
            let unit = CGDisplayUnitNumber(displayID)
            return "unit:\(unit):display:\(displayID)"
        }
        let x = Int(screen.frame.minX.rounded())
        let y = Int(screen.frame.minY.rounded())
        return "frame:\(x),\(y)"
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let num = screen.deviceDescription[key] as? NSNumber else { return nil }
        return CGDirectDisplayID(num.uint32Value)
    }

    private static func uuidString(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String?
    }
}
