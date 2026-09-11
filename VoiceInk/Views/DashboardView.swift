import AppKit
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var navigation: MainWindowNavigation
    @EnvironmentObject private var recorderUIManager: RecorderUIManager

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("VoiceInk")
                    .font(.system(size: 32, weight: .bold))
                Text("Dictate into any app or transcribe an audio file.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Toggle Recorder") {
                    recorderUIManager.handleToggleRecorderPanelNotification()
                }
                .buttonStyle(.borderedProminent)

                Button("Transcribe Audio") {
                    navigation.navigate(to: .transcribeAudio)
                }
                .buttonStyle(.bordered)
            }

            if !AXIsProcessTrusted() {
                Label("Accessibility permission is required to paste dictated text.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(32)
    }
}
