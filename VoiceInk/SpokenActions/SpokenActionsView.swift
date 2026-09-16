import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SpokenActionsView: View {
  @ObservedObject private var store = SpokenPhraseActionStore.shared
  @State private var editingAction: SpokenPhraseAction?
  @State private var isAdding = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Spoken Actions").font(.title2.bold())
          Text("Map spoken phrases to saved text, keyboard shortcuts, and stack actions.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Add Action", systemImage: "plus") { isAdding = true }
      }
      .padding(24)

      Divider()

      if store.actions.isEmpty {
        ContentUnavailableView(
          "No Spoken Actions",
          systemImage: "quote.bubble",
          description: Text("Add a phrase and choose what VoiceInk should do when it matches.")
        )
      } else {
        List {
          ForEach(store.actions) { action in
            SpokenActionRow(
              action: action,
              onToggle: { enabled in
                var changed = action
                changed.isEnabled = enabled
                store.update(changed)
              },
              onEdit: { editingAction = action },
              onDelete: { store.remove(id: action.id) }
            )
          }
        }
        .listStyle(.inset)
      }
    }
    .sheet(isPresented: $isAdding) {
      SpokenActionEditor { store.add($0) }
    }
    .sheet(item: $editingAction) { action in
      SpokenActionEditor(action: action) { store.update($0) }
    }
  }
}

private struct SpokenActionRow: View {
  let action: SpokenPhraseAction
  let onToggle: (Bool) -> Void
  let onEdit: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Toggle("", isOn: Binding(get: { action.isEnabled }, set: onToggle))
        .labelsHidden()
      VStack(alignment: .leading, spacing: 3) {
        Text(action.phrase).font(.headline)
        HStack(spacing: 8) {
          Text(action.operation.displayName)
          if action.operation.usesKeyboardShortcut {
            Text(action.shortcut.displayString)
          }
          if action.operation == .insertText {
            Text(action.savedText)
              .font(.system(.caption, design: .monospaced))
              .lineLimit(1)
          }
          if action.endsDictationAutomatically {
            Label("Auto-end", systemImage: "stop.circle")
          }
          if action.startsNewDictationAutomatically {
            Label("Keep listening", systemImage: "mic")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Edit", action: onEdit).buttonStyle(.borderless)
      Button(role: .destructive, action: onDelete) {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
    }
    .padding(.vertical, 5)
  }
}

private struct SpokenActionEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State private var draft: SpokenPhraseAction
  let onSave: (SpokenPhraseAction) -> Void

  init(action: SpokenPhraseAction? = nil, onSave: @escaping (SpokenPhraseAction) -> Void) {
    _draft = State(
      initialValue: action
        ?? SpokenPhraseAction(
          phrase: "",
          shortcut: .key(keyCode: UInt16(kVK_Return), modifierFlags: [])
        ))
    self.onSave = onSave
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Spoken Action").font(.title2.bold())
      Form {
        TextField("Spoken phrase", text: $draft.phrase)
        Picker("Action", selection: $draft.operation) {
          ForEach(SpokenPhraseAction.Operation.allCases, id: \.self) { operation in
            Text(operation.displayName).tag(operation)
          }
        }
        if draft.operation.usesKeyboardShortcut {
          LabeledContent("Keyboard shortcut") {
            ActionShortcutRecorder(shortcut: $draft.shortcut)
          }
        }
        if draft.operation == .insertText {
          VStack(alignment: .leading, spacing: 6) {
            Text("Text to insert")
            TextEditor(text: $draft.savedText)
              .font(.system(.body, design: .monospaced))
              .frame(height: 100)
              .border(.secondary.opacity(0.3))
              .accessibilityLabel("Text to insert")
            Text("Pastes exactly this text into the focused app. Does not press Return. In continuous mode, your stack stays queued and recording continues.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } else {
          Toggle(
            "Automatically end dictation when this phrase appears at the end of the preview",
            isOn: $draft.endsDictationAutomatically)
        }
        Text("Continuous mode runs enabled actions without stopping recording. Auto-end and restart settings apply to normal dictation.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Toggle(
          "Keep listening after running this action",
          isOn: $draft.startsNewDictationAutomatically)
        if draft.operation == .keyboardShortcut && draft.startsNewDictationAutomatically {
          Text("With live transcription and auto-end enabled, only the matched phrase is removed. The key runs without submitting text or restarting the recorder.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if draft.operation == .exitContinuousMode {
          Text("Stops continuous mode and discards queued text without submitting it.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Toggle("Enabled", isOn: $draft.isEnabled)
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Save") {
          var action = draft
          if action.operation != .keyboardShortcut {
            action.endsDictationAutomatically = true
          }
          onSave(action)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          SpokenPhraseMatcher.normalized(draft.phrase).isEmpty
            || (draft.operation == .insertText
              && draft.savedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        )
      }
    }
    .padding(24)
    .frame(width: 520)
  }
}

private struct ActionShortcutRecorder: View {
  @Binding var shortcut: Shortcut
  @State private var monitor: Any?
  @State private var isRecording = false

  var body: some View {
    Button(isRecording ? "Press a key combination" : shortcut.displayString) {
      isRecording ? stop() : start()
    }
    .onDisappear { stop() }
  }

  private func start() {
    isRecording = true
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let flags = Shortcut.normalizedModifierFlags(event.modifierFlags, forKeyCode: event.keyCode)
      if event.keyCode == UInt16(kVK_Escape), flags.isEmpty {
        stop()
        return nil
      }
      guard !Shortcut.isModifierKeyCode(event.keyCode) else { return nil }
      shortcut = .key(keyCode: event.keyCode, modifierFlags: flags)
      stop()
      return nil
    }
  }

  private func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    isRecording = false
  }
}
