#if os(iOS)
    import Foundation
    import Models
    import SwiftUI

    public struct TerminalToolbar: View {
        private typealias Palette = ToolbarPalette

        let keys: [ToolbarKey]
        let theme: TerminalTheme
        @Binding var ctrlActive: Bool
        let quickReplyOptions: [Int]
        let onKey: (ToolbarKey.Action) -> Void
        let onHideKeyboard: (() -> Void)?
        let onPaste: (() -> Void)?
        let onCopy: (() -> Void)?
        let onToggleSelect: (() -> Void)?
        let onCompose: (() -> Void)?
        let selectActive: Bool
        let composeActive: Bool
        let multiplexer: Bool
        @AppStorage("pocketshell.toolbar.shortcuts") private var panelOpen = false
        // Default off: the extra row resizes the terminal right after attach, and the
        // caret settle gate then parks on the last pane tmux redrew instead of the
        // active one (caught by testTmuxRepaintsKeepCaretParked).
        @AppStorage("pocketshell.toolbar.dpad") private var dpadOpen = false
        @State private var category: ShortcutCategory = .favorites

        public init(
            keys: [ToolbarKey],
            theme: TerminalTheme = .pocketshell,
            ctrlActive: Binding<Bool>,
            quickReplyOptions: [Int] = [],
            onKey: @escaping (ToolbarKey.Action) -> Void,
            onHideKeyboard: (() -> Void)? = nil,
            onPaste: (() -> Void)? = nil,
            onCopy: (() -> Void)? = nil,
            onToggleSelect: (() -> Void)? = nil,
            onCompose: (() -> Void)? = nil,
            selectActive: Bool = false,
            composeActive: Bool = false,
            multiplexer: Bool = false
        ) {
            self.keys = keys
            self.theme = theme
            self._ctrlActive = ctrlActive
            self.quickReplyOptions = quickReplyOptions
            self.onKey = onKey
            self.onHideKeyboard = onHideKeyboard
            self.onPaste = onPaste
            self.onCopy = onCopy
            self.onToggleSelect = onToggleSelect
            self.onCompose = onCompose
            self.selectActive = selectActive
            self.composeActive = composeActive
            self.multiplexer = multiplexer
        }

        public var body: some View {
            VStack(spacing: 0) {
                if panelOpen {
                    ShortcutPanel(
                        theme: theme,
                        userKeys: keys,
                        multiplexer: multiplexer,
                        onKey: onKey,
                        onClose: { panelOpen = false },
                        category: $category
                    )
                    Divider().overlay(Palette.border(theme))
                }
                if !quickReplyOptions.isEmpty {
                    quickReplyRow
                }
                if dpadOpen {
                    dpadRow
                }
                bar
            }
            .background(Palette.bar(theme))
        }

        private var bar: some View {
            HStack(spacing: 5) {
                slot(icon: "square.grid.2x2", active: panelOpen) { panelOpen.toggle() }
                    .accessibilityIdentifier("terminal.shortcutsToggle")
                slot("ctrl", active: ctrlActive) { onKey(.ctrlModifier) }
                slot("esc") { onKey(.escape) }
                slot("tab") { onKey(.tab) }
                slot(icon: "dpad", active: dpadOpen) { dpadOpen.toggle() }
                    .accessibilityIdentifier("terminal.dpad")
                if multiplexer {
                    slot("^b") {
                        category = .multiplexer
                        panelOpen = true
                    }
                    .accessibilityIdentifier("terminal.prefix")
                }
                if let onPaste {
                    Menu {
                        Button("Paste") { onPaste() }
                        if let onCopy { Button("Copy selection") { onCopy() } }
                        if let onToggleSelect {
                            Button(selectActive ? "Done selecting" : "Select text") { onToggleSelect() }
                        }
                    } label: {
                        slotLabel(
                            icon: selectActive ? "selection.pin.in.out" : "doc.on.clipboard",
                            active: selectActive
                        )
                    } primaryAction: {
                        if selectActive { onCopy?() } else { onPaste() }
                    }
                    .accessibilityIdentifier("terminal.clipboard")
                }
                if let onCompose {
                    slot(icon: "text.bubble", active: composeActive) { onCompose() }
                        .accessibilityIdentifier("terminal.compose")
                }
                if let onHideKeyboard {
                    slot(icon: "keyboard.chevron.compact.down") { onHideKeyboard() }
                        .accessibilityIdentifier("terminal.keyboard")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(Palette.pinned(theme))
        }

        private var dpadRow: some View {
            HStack(spacing: 5) {
                arrowKey("←", .arrowLeft)
                arrowKey("↓", .arrowDown)
                arrowKey("↑", .arrowUp)
                arrowKey("→", .arrowRight)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
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

        private func arrowKey(_ label: String, _ action: ToolbarKey.Action) -> some View {
            Button {
                onKey(action)
            } label: {
                slotLabel(label)
            }
            .buttonStyle(.plain)
            .buttonRepeatBehavior(.enabled)
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

        private func slot(icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                slotLabel(icon: icon, active: active)
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

        private func slotLabel(icon: String, active: Bool = false) -> some View {
            Image(systemName: icon)
                .font(.system(size: 13))
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
