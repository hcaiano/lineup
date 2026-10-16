import CoreGraphics

public enum WindowIdentityGeometry {
    public static func matches(surface: CGRect, accessibility: CGRect) -> Bool {
        let differences = [surface.minX - accessibility.minX, surface.minY - accessibility.minY,
                           accessibility.maxX - surface.maxX, accessibility.maxY - surface.maxY]
        return differences.allSatisfy { $0.isFinite && $0 >= -1 && $0 <= 8 }
            && surface.width > 0 && surface.height > 0
    }
}
