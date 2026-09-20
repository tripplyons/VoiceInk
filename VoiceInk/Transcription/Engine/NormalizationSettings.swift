import Foundation

/// Persisted at the app boundary and snapshotted once per recording or import.
enum NormalizationSettings {
    static let strengthKey = "audioNormalizationStrength"
    static let defaultStrength: Float = 0.5

    static func validatedStrength(_ strength: Float) -> Float {
        guard strength.isFinite else { return defaultStrength }
        return min(max(strength, 0), 1)
    }

    static func loadStrength(from defaults: UserDefaults = .standard) -> Float {
        guard let value = defaults.object(forKey: strengthKey) as? NSNumber else { return defaultStrength }
        return validatedStrength(value.floatValue)
    }
}
