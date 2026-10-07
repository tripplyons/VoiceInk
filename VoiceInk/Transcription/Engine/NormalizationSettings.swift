import Foundation

/// Persisted at the app boundary and snapshotted once per recording or import.
enum NormalizationSettings {
    static let strengthKey = "audioNormalizationStrength"
    static let defaultStrength: Float = 1
    static let lookaheadKey = "audioNormalizationLookaheadMilliseconds"
    static let startupRampKey = "audioNormalizationStartupRampMilliseconds"
    static let defaultLookaheadMilliseconds: Double = 10
    static let defaultStartupRampMilliseconds: Double = 100
    static let lookaheadRange: ClosedRange<Double> = 5...100
    static let startupRampRange: ClosedRange<Double> = 1...100

    struct Timing: Codable, Equatable {
        let lookaheadMilliseconds: Double
        let startupRampMilliseconds: Double
        var lookaheadSeconds: Double { lookaheadMilliseconds / 1_000 }
        var startupRampSeconds: Double { startupRampMilliseconds / 1_000 }

        init(lookaheadMilliseconds: Double = defaultLookaheadMilliseconds,
             startupRampMilliseconds: Double = defaultStartupRampMilliseconds) {
            self.lookaheadMilliseconds = Self.validated(lookaheadMilliseconds,
                range: lookaheadRange, fallback: defaultLookaheadMilliseconds)
            self.startupRampMilliseconds = Self.validated(startupRampMilliseconds,
                range: startupRampRange, fallback: defaultStartupRampMilliseconds)
        }

        private static func validated(_ value: Double, range: ClosedRange<Double>, fallback: Double) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }

        private enum CodingKeys: String, CodingKey { case lookaheadMilliseconds, startupRampMilliseconds }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(lookaheadMilliseconds: try values.decodeIfPresent(Double.self, forKey: .lookaheadMilliseconds)
                        ?? defaultLookaheadMilliseconds,
                startupRampMilliseconds: try values.decodeIfPresent(Double.self, forKey: .startupRampMilliseconds)
                        ?? defaultStartupRampMilliseconds)
        }
    }

    static func validatedStrength(_ strength: Float) -> Float {
        guard strength.isFinite else { return defaultStrength }
        return min(max(strength, 0), 1)
    }

    static func loadStrength(from defaults: UserDefaults = .standard) -> Float {
        guard let value = defaults.object(forKey: strengthKey) as? NSNumber else { return defaultStrength }
        return validatedStrength(value.floatValue)
    }

    static func loadTiming(from defaults: UserDefaults = .standard) -> Timing {
        Timing(lookaheadMilliseconds: (defaults.object(forKey: lookaheadKey) as? NSNumber)?.doubleValue
                    ?? defaultLookaheadMilliseconds,
               startupRampMilliseconds: (defaults.object(forKey: startupRampKey) as? NSNumber)?.doubleValue
                    ?? defaultStartupRampMilliseconds)
    }

    static func saveTiming(_ timing: Timing, to defaults: UserDefaults = .standard) {
        defaults.set(timing.lookaheadMilliseconds, forKey: lookaheadKey)
        defaults.set(timing.startupRampMilliseconds, forKey: startupRampKey)
    }
}
