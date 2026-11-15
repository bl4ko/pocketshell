#if os(iOS)
    import Foundation
    import Models
    import SwiftUI
    import UniformTypeIdentifiers

    public struct TerminalToolbar: View {
        private typealias Palette = ToolbarPalette
        static let keyHeight: CGFloat = 33

        let theme: TerminalTheme
        @Binding var ctrlActive: Bool
        let quickReplyOptions: [Int]
        let onKey: (ToolbarKey.Action) -> Void
        let onHideKeyboard: (() -> Void)?
        let keyboardVisible: Bool
        let onPaste: (([NSItemProvider]) -> Void)?
        let onCopy: (() -> Void)?
        let onToggleSelect: (() -> Void)?
        let onVoice: (() -> Void)?
        let onCompose: (() -> Void)?
        let onAttach: (() -> Void)?
        let onCamera: (() -> Void)?
        let uploadingFile: Bool
        let selectActive: Bool
        let voiceActive: Bool
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
            onVoice: (() -> Void)? = nil,
            onCompose: (() -> Void)? = nil,
            onAttach: (() -> Void)? = nil,
            onCamera: (() -> Void)? = nil,
            uploadingFile: Bool = false,
            selectActive: Bool = false,
            voiceActive: Bool = false,
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
            self.onVoice = onVoice
            self.onCompose = onCompose
            self.onAttach = onAttach
            self.onCamera = onCamera
            self.uploadingFile = uploadingFile
            self.selectActive = selectActive
            self.voiceActive = voiceActive
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
            // Keyboard glass tints from what is behind it: constant while the layout settles, the theme under dark glass.
            .background(alignment: .top) { Palette.keyboard(theme).frame(height: 1000) }
        }

        private var bar: some View {
            HStack(spacing: 5) {
                ForEach(ToolbarSlot.allCases, id: \.self, content: barSlot)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(Palette.pinned(theme))
        }

        @ViewBuilder private func barSlot(_ slot: ToolbarSlot) -> some View {
            switch slot {
            case .shortcuts:
                self.slot(icon: "square.grid.2x2", active: shortcutsActive) { onShortcuts(nil) }
                    .accessibilityLabel("Special keys")
                    .accessibilityIdentifier("terminal.shortcutsToggle")
            case .ctrl: self.slot("ctrl", active: ctrlActive) { onKey(.ctrlModifier) }
            case .escape: self.slot("esc") { onKey(.escape) }
            case .tab: self.slot("tab") { onKey(.tab) }
            case .enter:
                self.slot(icon: "return") { onKey(.sequence("\r")) }
                    .accessibilityLabel("Enter")
                    .accessibilityIdentifier("terminal.enter")
            case .attach: attachSlot
            case .clipboard: clipboardSlot
            case .voice: voiceSlot
            case .keyboard:
                if let onHideKeyboard {
                    self.slot(icon: KeyboardToggle.icon(keyboardVisible: keyboardVisible)) { onHideKeyboard() }
                        .accessibilityLabel(keyboardVisible ? "Hide keyboard" : "Show keyboard")
                        .accessibilityIdentifier("terminal.keyboard")
                }
            }
        }

        @ViewBuilder private var attachSlot: some View {
            if let onAttach, let onCamera {
                Menu {
                    Button("Take Photo", systemImage: "camera") { onCamera() }
                        .accessibilityIdentifier("terminal.camera")
                    Button("Choose File", systemImage: "doc") { onAttach() }
                        .accessibilityIdentifier("terminal.chooseFile")
                } label: {
                    slotLabel(icon: "paperclip", busy: uploadingFile)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
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
        }

        @ViewBuilder private var clipboardSlot: some View {
            if let onPaste {
                Group {
                    if selectActive {
                        slot(icon: "selection.pin.in.out", active: true) { onCopy?() }
                    } else {
                        PasteKey(
                            background: UIColor(Palette.key(theme)),
                            foreground: UIColor(Palette.text(theme)),
                            border: UIColor(Palette.border(theme)),
                            onPaste: onPaste
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.keyHeight)
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
        }

        @ViewBuilder private var voiceSlot: some View {
            if let onVoice {
                slotLabel(icon: "waveform", active: voiceActive)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onVoice)
                    .onLongPressGesture(minimumDuration: 0.5) { onCompose?() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Voice mode")
                    .accessibilityValue(voiceActive ? "On" : "Off")
                    .accessibilityHint(onCompose == nil ? "" : "Hold to write a message")
                    .accessibilityAction(named: "Write a message") { onCompose?() }
                    .accessibilityIdentifier("terminal.voice")
            }
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
                .frame(maxWidth: .infinity)
                .frame(height: Self.keyHeight)
                .background(background ?? Palette.key(theme))
                .foregroundStyle(foreground ?? Palette.text(theme))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(border ?? Palette.border(theme)))
        }

        private func slotLabel(icon: String, active: Bool = false, busy: Bool = false) -> some View {
            Image(systemName: icon)
                .font(.system(size: 13))
                .opacity(busy ? 0 : 1)
                .overlay {
                    if busy { ProgressView().controlSize(.mini).tint(Palette.text(theme)) }
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.keyHeight)
                .background(active ? Palette.accentTint(theme) : Palette.key(theme))
                .foregroundStyle(active ? Palette.accentDark(theme) : Palette.text(theme))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(active ? Palette.accentBorder(theme) : Palette.border(theme))
                )
        }
    }
#endif

enum ToolbarSlot: CaseIterable {
    case shortcuts, ctrl, escape, tab, attach, clipboard, voice, keyboard, enter
}

enum KeyboardToggle {
    static func icon(keyboardVisible: Bool) -> String {
        keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard"
    }
}
