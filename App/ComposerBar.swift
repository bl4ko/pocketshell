import Models
import SwiftUI

/// Writes a prompt outside the TUI, then sends it into the live session as one block.
///
/// Two reasons it exists: agent prompts are long and editing them inside a TUI on a phone is
/// painful, and it is a plain iOS text field, so every IME composes in it even when a TUI
/// swallows composition events.
struct ComposerBar: View {
    @Binding var text: String
    let theme: TerminalTheme
    let onSend: () -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("message…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1...6)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focused)
                .accessibilityIdentifier("composer.field")
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(PocketshellTheme.paper)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(PocketshellTheme.chipBorder))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(text.isEmpty ? PocketshellTheme.secondary : PocketshellTheme.accent)
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier("composer.send")
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(PocketshellTheme.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("composer.close")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(PocketshellTheme.surface)
        .onAppear { focused = true }
    }

    private func send() {
        guard !text.isEmpty else { return }
        onSend()
        text = ""
        focused = true
    }
}
