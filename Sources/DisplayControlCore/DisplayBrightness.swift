import Foundation

/// Calibration is applied only to synchronized brightness keys. It never changes a display
/// while preferences load, and manual controls continue to use the display's hardware scale.
public enum DisplayBrightnessMath {
    public static func hardwareLevel(logicalLevel: Double, brightnessLimit: Double,
                                     brightnessMinimum: Double = 0) -> Double? {
        guard logicalLevel.isFinite, validRange(minimum: brightnessMinimum, maximum: brightnessLimit)
        else { return nil }
        return brightnessMinimum + min(1, max(0, logicalLevel)) * (brightnessLimit - brightnessMinimum)
    }

    public static func logicalLevel(hardwareLevel: Double, brightnessLimit: Double,
                                    brightnessMinimum: Double = 0) -> Double? {
        guard hardwareLevel.isFinite, (0...1).contains(hardwareLevel),
              validRange(minimum: brightnessMinimum, maximum: brightnessLimit)
        else { return nil }
        return min(1, max(0, (hardwareLevel - brightnessMinimum) / (brightnessLimit - brightnessMinimum)))
    }

    private static func validRange(minimum: Double, maximum: Double) -> Bool {
        minimum.isFinite && maximum.isFinite && minimum >= 0 && minimum < maximum
            && (0.05...1).contains(maximum)
    }
}

/// A held brightness key retains its initial connections and unrounded logical intent.
/// Recomputing intent from rounded hardware values would lose fine steps at low display limits.
public struct DisplayBrightnessGroup: Sendable {
    public let generation: UUID
    public let reference: UUID
    public let connections: [UUID]
    public let isSynchronized: Bool
    public private(set) var logicalLevel: Double

    init(generation: UUID, reference: UUID, connections: [UUID], isSynchronized: Bool,
         logicalLevel: Double) {
        self.generation = generation
        self.reference = reference
        self.connections = connections
        self.isSynchronized = isSynchronized
        self.logicalLevel = logicalLevel
    }

    mutating func setLogicalLevel(_ value: Double) { logicalLevel = value }
}
