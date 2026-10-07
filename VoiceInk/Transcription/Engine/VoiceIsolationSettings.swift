import Foundation

/// Snapshotted at the start of each recording or import.
enum VoiceIsolationSettings {
    enum BlendMode: String, CaseIterable, Identifiable {
        case linear
        case equalPower

        var id: String { rawValue }
        var title: String {
            switch self {
            case .linear: return "Linear"
            case .equalPower: return "Equal-power"
            }
        }

        func mix(original: Float, isolated: Float, strength: Float) -> Float {
            let amount = VoiceIsolationSettings.validatedStrength(strength)
            if amount == 0 { return original }
            if amount == 1 { return isolated }
            switch self {
            case .linear: return original + amount * (isolated - original)
            case .equalPower:
                return cos(amount * .pi / 2) * original + sin(amount * .pi / 2) * isolated
            }
        }
    }

    static let blendModeKey = "voiceIsolationBlendMode"
    static func loadBlendMode(from defaults: UserDefaults = .standard) -> BlendMode {
        BlendMode(rawValue: defaults.string(forKey: blendModeKey) ?? "") ?? .linear
    }

    static let strengthKey = "voiceIsolationStrength"
    // Preserve unvoiced whisper detail that full suppression can remove.
    static let defaultStrength: Float = 0.35

    static func validatedStrength(_ strength: Float) -> Float {
        guard strength.isFinite else { return defaultStrength }
        return min(max(strength, 0), 1)
    }

    static func loadStrength(from defaults: UserDefaults = .standard) -> Float {
        guard let value = defaults.object(forKey: strengthKey) as? NSNumber else { return defaultStrength }
        return validatedStrength(value.floatValue)
    }
}
