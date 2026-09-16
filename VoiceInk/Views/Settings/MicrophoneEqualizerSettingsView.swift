import SwiftUI

struct MicrophoneEqualizerSettingsView: View {
    @ObservedObject private var store = MicrophoneEqualizerSettingsStore.shared

    var body: some View {
        Toggle("Enable Microphone EQ", isOn: enabledBinding)

        if store.settings.isEnabled {
            filterRow(
                title: "High-pass",
                detail: "Cut low frequencies",
                value: valueBinding(for: \.highPassFrequency),
                range: MicrophoneEqualizerSettings.highPassRange,
                step: 5,
                formattedValue: frequencyLabel(store.settings.highPassFrequency)
            )

            ForEach(Array(MicrophoneEqualizerSettings.bandFrequencies.enumerated()), id: \.offset) {
                index, frequency in
                filterRow(
                    title: frequencyLabel(frequency),
                    detail: "Gain",
                    value: gainBinding(at: index),
                    range: MicrophoneEqualizerSettings.gainRange,
                    step: 0.5,
                    formattedValue: gainLabel(store.settings.bandGains[index])
                )
            }

            filterRow(
                title: "Low-pass",
                detail: "Cut high frequencies",
                value: valueBinding(for: \.lowPassFrequency),
                range: MicrophoneEqualizerSettings.lowPassRange,
                step: 100,
                formattedValue: frequencyLabel(store.settings.lowPassFrequency)
            )

            HStack {
                Text("Applied before peak normalization")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Reset EQ") {
                    store.reset()
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func filterRow(
        title: String,
        detail: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        step: Float,
        formattedValue: String
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 105, alignment: .leading)

            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(formattedValue)

            Text(formattedValue)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.isEnabled },
            set: { isEnabled in
                var settings = store.settings
                settings.isEnabled = isEnabled
                store.settings = settings
            }
        )
    }

    private func valueBinding(
        for keyPath: WritableKeyPath<MicrophoneEqualizerSettings, Float>
    ) -> Binding<Float> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { value in
                var settings = store.settings
                settings[keyPath: keyPath] = value
                store.settings = settings
            }
        )
    }

    private func gainBinding(at index: Int) -> Binding<Float> {
        Binding(
            get: { store.settings.bandGains[index] },
            set: { gain in
                var settings = store.settings
                settings.bandGains[index] = gain
                store.settings = settings
            }
        )
    }

    private func frequencyLabel(_ frequency: Float) -> String {
        if frequency >= 1_000 {
            return frequency.truncatingRemainder(dividingBy: 1_000) == 0
                ? "\(Int(frequency / 1_000)) kHz"
                : String(format: "%.1f kHz", frequency / 1_000)
        }
        return "\(Int(frequency)) Hz"
    }

    private func gainLabel(_ gain: Float) -> String {
        String(format: "%+.1f dB", gain)
    }
}
