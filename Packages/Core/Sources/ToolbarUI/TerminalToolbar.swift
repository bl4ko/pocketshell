#if os(iOS)
    import Foundation
    import Models
    import SwiftUI
    import UniformTypeIdentifiers

    public struct TerminalToolbar: View {
        private typealias Palette = ToolbarPalette

        let theme: TerminalTheme
        @Binding var ctrlActive: Bool
        let quickReplyOptions: [Int]
        let onKey: (ToolbarKey.Action) -> Void
        let onHideKeyboard: (() -> Void)?
        let keyboardVisible: Bool
        let onPaste: (([NSItemProvider]) -> Void)?
        let onCopy: (() -> Void)?
        let onToggleSelect: (() -> Void)?
        let onCompose: (() -> Void)?
        let onAttach: (() -> Void)?
        let onCamera: (() -> Void)?
        let uploadingFile: Bool
        let selectActive: Bool
        let composeActive: Bool
        let shortcutsActive: Bool
        let onShortcuts: (ShortcutCategory?) -> Void
        @State private var clipboardMenu = false

        public init(
            theme: TerminalTheme = .pocketshell,
            ctrlActive: Binding<Bool>,
            quickReplyOptions: [Int] = [],
            onKey: @escaping (ToolbarKey.Action) -> Void,
            onHideKeyboard: (() -> Void)? = nil,
            keyboardVisible: Bool = true,
            onPaste: (([NSItemProvider]) -> Void)? = nil,
            onCopy: (() -> Void)? = nil,
            onToggleSelect: (() -> Void)? = nil,
            onCompose: (() -> Void)? = nil,
            onAttach: (() -> Void)? = nil,
            onCamera: (() -> Void)? = nil,
            uploadingFile: Bool = false,
            selectActive: Bool = false,
            composeActive: Bool = false,
            shortcutsActive: Bool = false,
            onShortcuts: @escaping (ShortcutCategory?) -> Void
        ) {
            self.theme = theme
            self._ctrlActive = ctrlActive
            self.quickReplyOptions = quickReplyOptions
            self.onKey = onKey
            self.onHideKeyboard = onHideKeyboard
            self.keyboardVisible = keyboardVisible
            self.onPaste = onPaste
            self.onCopy = onCopy
            self.onToggleSelect = onToggleSelect
            self.onCompose = onCompose
            self.onAttach = onAttach
            self.onCamera = onCamera
            self.uploadingFile = uploadingFile
            self.selectActive = selectActive
            self.composeActive = composeActive
            self.shortcutsActive = shortcutsActive
            self.onShortcuts = onShortcuts
        }

        public var body: some View {
            VStack(spacing: 0) {
                if !quickReplyOptions.isEmpty {
                    quickReplyRow
                }
                bar
            }
            // Keyboard glass tints from what is behind it; this keeps that constant while the layout settles.
            .background(alignment: .top) { Palette.pinned(theme).frame(height: 1000) }
        }

        private var bar: some View {
            HStack(spacing: 5) {
                slot(icon: "square.grid.2x2", active: shortcutsActive) { onShortcuts(nil) }
                    .accessibilityLabel("Special keys")
                    .accessibilityIdentifier("terminal.shortcutsToggle")
                slot("ctrl", active: ctrlActive) { onKey(.ctrlModifier) }
                slot("esc") { onKey(.escape) }
                slot("tab") { onKey(.tab) }
                slot(icon: "return") { onKey(.sequence("\r")) }
                    .accessibilityLabel("Enter")
                    .accessibilityIdentifier("terminal.enter")
                if let onAttach, let onCamera {
                    Menu {
                        Button("Take Photo", systemImage: "camera") { onCamera() }
                            .accessibilityIdentifier("terminal.camera")
                        Button("Choose File", systemImage: "doc") { onAttach() }
                            .accessibilityIdentifier("terminal.chooseFile")
                    } label: {
                        slotLabel(icon: "paperclip", busy: uploadingFile)
                    }
                    .disabled(uploadingFile)
                    .accessibilityLabel("Attach")
                    .accessibilityValue(uploadingFile ? "Uploading" : "Ready")
                    .accessibilityIdentifier("terminal.attach")
                } else if let onAttach {
                    slot(icon: "paperclip", busy: uploadingFile, action: onAttach)
                        .disabled(uploadingFile)
                        .accessibilityLabel("Attach file")
                        .accessibilityValue(uploadingFile ? "Uploading" : "Ready")
                        .accessibilityIdentifier("terminal.attach")
                }
                if let onPaste {
                    Group {
                        if selectActive {
                            slot(icon: "selection.pin.in.out", active: true) { onCopy?() }
                        } else {
                            PasteButton(supportedContentTypes: [.image, .text], payloadAction: onPaste)
                                .labelStyle(.iconOnly)
                                .buttonBorderShape(.roundedRectangle(radius: 8))
                                .tint(Palette.key(theme))
                                .foregroundStyle(Palette.text(theme))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    // .contextMenu breaks the secure paste: its press effect drops the authentication and iOS prompts.
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in clipboardMenu = true })
                    .confirmationDialog("Clipboard", isPresented: $clipboardMenu) {
                        if let onCopy { Button("Copy selection") { onCopy() } }
                        if let onToggleSelect {
                            Button(selectActive ? "Done selecting" : "Select text") { onToggleSelect() }
                        }
                    }
                    .accessibilityIdentifier("terminal.clipboard")
                }
                if let onCompose {
                    slot(icon: "text.bubble", active: composeActive) { onCompose() }
                        .accessibilityIdentifier("terminal.compose")
                }
                if let onHideKeyboard {
                    slot(icon: KeyboardToggle.icon(keyboardVisible: keyboardVisible)) { onHideKeyboard() }
                        .accessibilityLabel(keyboardVisible ? "Hide keyboard" : "Show keyboard")
                        .accessibilityIdentifier("terminal.keyboard")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(Palette.pinned(theme))
        }

        private var quickReplyRow: some View {
            HStack(spacing: 5) {
                ForEach(quickReplyOptions, id: \.self) { option in
                    Button {
                        onKey(.sequence("\(option)\n"))
                    } label: {
                        slotLabel(
                            "\(option)↵",
                            background: option == quickReplyOptions.first
                                ? Palette.accent(theme) : Palette.key(theme),
                            border: Palette.accentBorder(theme),
                            foreground: option == quickReplyOptions.first ? .white : Palette.accentDark(theme)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Palette.accentTint(theme))
        }

        private func slot(_ label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                slotLabel(
                    label,
                    background: active ? Palette.accentTint(theme) : Palette.key(theme),
                    border: active ? Palette.accentBorder(theme) : Palette.border(theme),
                    foreground: active ? Palette.accentDark(theme) : Palette.text(theme)
                )
            }
            .buttonStyle(.plain)
        }

        private func slot(
            icon: String, active: Bool = false, busy: Bool = false, action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                slotLabel(icon: icon, active: active, busy: busy)
            }
            .buttonStyle(.plain)
        }

        private func slotLabel(
            _ text: String,
            background: Color? = nil,
            border: Color? = nil,
            foreground: Color? = nil
        ) -> some View {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(background ?? Palette.key(theme))
                .foregroundStyle(foreground ?? Palette.text(theme))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(border ?? Palette.border(theme)))
        }

        private func slotLabel(icon: String, active: Bool = false, busy: Bool = false) -> some View {
            Image(systemName: icon)
                .font(.system(size: 13))
                .opacity(busy ? 0 : 1)
                .overlay {
                    if busy { ProgressView().controlSize(.mini).tint(Palette.text(theme)) }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(active ? Palette.accentTint(theme) : Palette.key(theme))
                .foregroundStyle(active ? Palette.accentDark(theme) : Palette.text(theme))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(active ? Palette.accentBorder(theme) : Palette.border(theme))
                )
        }
    }
#endif

enum KeyboardToggle {
    static func icon(keyboardVisible: Bool) -> String {
        keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard"
    }
}
