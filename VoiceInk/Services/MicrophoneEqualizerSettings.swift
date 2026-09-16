import Combine
import Foundation

struct MicrophoneEqualizerSettings: Codable, Equatable, Sendable {
    static let bandFrequencies: [Float] = [125, 250, 500, 1_000, 2_000, 4_000]
    static let defaultHighPassFrequency: Float = 90
    static let defaultBandGains: [Float] = [-3.5, 1.5, 2.5, -1, -1.5, -2.5]
    static let defaultLowPassFrequency: Float = 6_600
    static let highPassRange: ClosedRange<Float> = 40...300
    static let lowPassRange: ClosedRange<Float> = 3_000...7_800
    static let gainRange: ClosedRange<Float> = -12...12

    var isEnabled: Bool
    var highPassFrequency: Float
    var bandGains: [Float]
    var lowPassFrequency: Float

    init(
        isEnabled: Bool = false,
        highPassFrequency: Float = defaultHighPassFrequency,
        bandGains: [Float] = defaultBandGains,
        lowPassFrequency: Float = defaultLowPassFrequency
    ) {
        self.isEnabled = isEnabled
        self.highPassFrequency = highPassFrequency
        self.bandGains = bandGains
        self.lowPassFrequency = lowPassFrequency
        sanitize()
    }

    mutating func sanitize() {
        highPassFrequency = highPassFrequency.clamped(to: Self.highPassRange)
        lowPassFrequency = lowPassFrequency.clamped(to: Self.lowPassRange)

        let gains = bandGains.prefix(Self.bandFrequencies.count).map {
            $0.clamped(to: Self.gainRange)
        }
        bandGains = gains + Array(
            repeating: 0,
            count: max(0, Self.bandFrequencies.count - gains.count)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case highPassFrequency
        case bandGains
        case lowPassFrequency
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        highPassFrequency = try container.decodeIfPresent(Float.self, forKey: .highPassFrequency)
            ?? Self.defaultHighPassFrequency
        bandGains = try container.decodeIfPresent([Float].self, forKey: .bandGains)
            ?? Self.defaultBandGains
        lowPassFrequency = try container.decodeIfPresent(Float.self, forKey: .lowPassFrequency)
            ?? Self.defaultLowPassFrequency
        sanitize()
    }
}

@MainActor
final class MicrophoneEqualizerSettingsStore: ObservableObject {
    static let shared = MicrophoneEqualizerSettingsStore()
    static let userDefaultsKey = "MicrophoneEqualizerSettings"

    @Published var settings: MicrophoneEqualizerSettings {
        didSet { save() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Self.userDefaultsKey),
           let settings = try? JSONDecoder().decode(MicrophoneEqualizerSettings.self, from: data) {
            self.settings = settings
        } else {
            settings = MicrophoneEqualizerSettings()
        }
    }

    func reset() {
        let isEnabled = settings.isEnabled
        settings = MicrophoneEqualizerSettings(isEnabled: isEnabled)
    }

    func replace(with settings: MicrophoneEqualizerSettings) {
        var sanitized = settings
        sanitized.sanitize()
        self.settings = sanitized
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.userDefaultsKey)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
