import Foundation

enum ShortcutAction: Hashable {
    case primaryRecording
    case secondaryRecording
    case cancelRecorder
    case quickAddToDictionary
    case enableContinuousMode
    case toggleContinuousMode
    case stopContinuousMode
    case mode(UUID)
    case recorderPanelEscape
    case recorderPanelMode(Int)

    var userDefaultsKey: String {
        "Shortcut_\(storageName)"
    }

    var isStored: Bool {
        switch self {
        case .recorderPanelEscape, .recorderPanelMode:
            return false
        default:
            return true
        }
    }

    var storageName: String {
        switch self {
        case .primaryRecording:
            return "primaryRecording"
        case .secondaryRecording:
            return "secondaryRecording"
        case .cancelRecorder:
            return "cancelRecorder"
        case .quickAddToDictionary:
            return "quickAddToDictionary"
        case .enableContinuousMode:
            return "enableContinuousMode"
        case .toggleContinuousMode:
            return "toggleContinuousMode"
        case .stopContinuousMode:
            return "stopContinuousMode"
        case .mode(let id):
            return "mode_\(id.uuidString)"
        case .recorderPanelEscape:
            return "recorderPanelEscape"
        case .recorderPanelMode(let index):
            return "recorderPanelMode_\(index)"
        }
    }

    var displayName: String {
        switch self {
        case .primaryRecording:
            return String(localized: "Primary Shortcut")
        case .secondaryRecording:
            return String(localized: "Secondary Shortcut")
        case .cancelRecorder:
            return String(localized: "Cancel Recording")
        case .quickAddToDictionary:
            return String(localized: "Quick Add to Dictionary")
        case .enableContinuousMode:
            return String(localized: "Enable Continuous Mode")
        case .toggleContinuousMode:
            return String(localized: "Toggle Continuous Mode")
        case .stopContinuousMode:
            return String(localized: "Stop Continuous Mode")
        case .mode(let id):
            if let config = ModeManager.shared.getConfiguration(with: id) {
                return String(format: String(localized: "%@ Mode"), config.name)
            }

            if let template = StarterModeCatalog.templates.first(where: { $0.id == id }) {
                return String(format: String(localized: "%@ Mode"), template.name)
            }

            return String(localized: "Mode")
        case .recorderPanelEscape:
            return String(localized: "Recorder Cancel")
        case .recorderPanelMode(let index):
            return String(format: String(localized: "Select Mode %@"), Self.displayNumber(forRecorderPanelIndex: index))
        }
    }

    static let continuousModeActions: [Self] = [
        .enableContinuousMode, .toggleContinuousMode, .stopContinuousMode,
    ]

    static let globalUtilityActions: [Self] = [.quickAddToDictionary] + continuousModeActions

    static let recorderPanelStoredActions: [Self] = [
        .cancelRecorder
    ]

    static let legacyKeyboardShortcutActions: [Self] = [
        .primaryRecording,
        .secondaryRecording,
        .cancelRecorder,
        .quickAddToDictionary,
    ]

    private static func displayNumber(forRecorderPanelIndex index: Int) -> String {
        index == 9 ? "10" : "\(index + 1)"
    }
}
