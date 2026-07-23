#if os(iOS)
    import Foundation
    import Models
    import SwiftUI

    public struct TerminalToolbar: View {
        private enum Palette {
            static let dark = Color(red: 22 / 255, green: 24 / 255, blue: 26 / 255)
            static let darkKey = Color(red: 35 / 255, green: 38 / 255, blue: 42 / 255)
            static let darkBorder = Color(red: 60 / 255, green: 64 / 255, blue: 69 / 255)

            static func bar(_ theme: TerminalTheme) -> Color { themed("ECEAE3", theme, mix: 0.12) }
            static func pinned(_ theme: TerminalTheme) -> Color { themed("E5E3DA", theme, mix: 0.16) }
            static func key(_ theme: TerminalTheme) -> Color { themed("FFFFFF", theme, mix: 0.08) }
            static func border(_ theme: TerminalTheme) -> Color { themed("CFCCC0", theme, mix: 0.28) }
            static func text(_ theme: TerminalTheme) -> Color { themed("3C4045", theme, dark: theme.foreground) }
            static func accent(_ theme: TerminalTheme) -> Color { themed("E8590C", theme, dark: theme.accentHex) }
            static func accentDark(_ theme: TerminalTheme) -> Color {
                themed("C2410C", theme, dark: theme.accentHex)
            }
            static func accentTint(_ theme: TerminalTheme) -> Color {
                themed("FDF1E8", theme, dark: mixed(theme.background, theme.accentHex, 0.18))
            }
            static func accentBorder(_ theme: TerminalTheme) -> Color {
                themed("EAB896", theme, dark: mixed(theme.background, theme.accentHex, 0.50))
            }

            private static func themed(_ light: String, _ theme: TerminalTheme, dark: String) -> Color {
                color(theme == .pocketshell ? light : dark)
            }

            private static func themed(_ light: String, _ theme: TerminalTheme, mix: Double) -> Color {
                themed(light, theme, dark: mixed(theme.background, theme.foreground, mix))
            }

            private static func color(_ hex: String) -> Color {
                let rgb = RGBColor(hex: hex) ?? RGBColor(red: 0, green: 0, blue: 0)
                return Color(
                    red: Double(rgb.red) / 255,
                    green: Double(rgb.green) / 255,
                    blue: Double(rgb.blue) / 255
                )
            }

            private static func mixed(_ from: String, _ to: String, _ amount: Double) -> String {
                guard let from = RGBColor(hex: from), let to = RGBColor(hex: to) else { return from }
                func channel(_ a: UInt8, _ b: UInt8) -> UInt8 {
                    UInt8((Double(a) + (Double(b) - Double(a)) * amount).rounded())
                }
                return String(
                    format: "%02x%02x%02x",
                    channel(from.red, to.red),
                    channel(from.green, to.green),
                    channel(from.blue, to.blue)
                )
            }
        }

        let keys: [ToolbarKey]
        let theme: TerminalTheme
        @Binding var ctrlActive: Bool
        let quickReplyOptions: [Int]
        let onKey: (ToolbarKey.Action) -> Void
        let onHideKeyboard: (() -> Void)?
        let onPaste: (() -> Void)?
        let onCopy: (() -> Void)?
        @State private var prefixPaletteActive = false
        @State private var prefixExpiry = Date.distantPast

        public init(
            keys: [ToolbarKey],
            theme: TerminalTheme = .pocketshell,
            ctrlActive: Binding<Bool>,
            quickReplyOptions: [Int] = [],
            onKey: @escaping (ToolbarKey.Action) -> Void,
            onHideKeyboard: (() -> Void)? = nil,
            onPaste: (() -> Void)? = nil,
            onCopy: (() -> Void)? = nil
        ) {
            self.keys = keys
            self.theme = theme
            self._ctrlActive = ctrlActive
            self.quickReplyOptions = quickReplyOptions
            self.onKey = onKey
            self.onHideKeyboard = onHideKeyboard
            self.onPaste = onPaste
            self.onCopy = onCopy
        }

        public var body: some View {
            Group {
                if prefixPaletteActive {
                    prefixPalette
                } else {
                    normalToolbar
                }
            }
            .task(id: prefixExpiry) {
                guard prefixPaletteActive else { return }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                prefixPaletteActive = false
            }
        }

        private var normalToolbar: some View {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let onPaste {
                            Menu {
                                Button("Paste") { onPaste() }
                                if let onCopy { Button("Copy selection") { onCopy() } }
                            } label: {
                                keyLabel(icon: "doc.on.clipboard")
                            } primaryAction: {
                                onPaste()
                            }
                        }
                        if !quickReplyOptions.isEmpty {
                            HStack(spacing: 5) {
                                ForEach(quickReplyOptions, id: \.self) { option in
                                    Button {
                                        onKey(.sequence("\(option)\n"))
                                    } label: {
                                        keyLabel(
                                            "\(option)↵",
                                            background: option == quickReplyOptions.first
                                                ? Palette.accent(theme) : Palette.key(theme),
                                            border: Palette.accentBorder(theme),
                                            foreground: option == quickReplyOptions.first
                                                ? .white : Palette.accentDark(theme)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Palette.accentTint(theme))
                            Divider().frame(height: 22).overlay(Palette.accentBorder(theme))
                        }
                        ForEach(ToolbarKey.scrollRow(from: keys)) { key in
                            Button {
                                handle(key)
                            } label: {
                                keyLabel(key.label)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .clipped()
                Divider().frame(height: 22).overlay(Palette.border(theme))
                HStack(spacing: 4) {
                    arrowMenu(label: "↑", primary: .arrowUp)
                    arrowMenu(label: "↓", primary: .arrowDown)
                    Button {
                        onKey(.escape)
                    } label: {
                        keyLabel("esc")
                    }
                    .buttonStyle(.plain)
                    Button {
                        onKey(.ctrlModifier)
                    } label: {
                        keyLabel(
                            "ctrl",
                            background: ctrlActive ? Palette.accentTint(theme) : Palette.key(theme),
                            border: ctrlActive ? Palette.accentBorder(theme) : Palette.border(theme),
                            foreground: ctrlActive ? Palette.accentDark(theme) : Palette.text(theme)
                        )
                    }
                    .buttonStyle(.plain)
                    if let onHideKeyboard {
                        Button {
                            onHideKeyboard()
                        } label: {
                            keyLabel(icon: "keyboard.chevron.compact.down")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("terminal.keyboard")
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Palette.pinned(theme))
            }
            .background(Palette.bar(theme))
        }

        private var prefixPalette: some View {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        prefixKey("c", "new")
                        prefixKey("n", "next")
                        prefixKey("p", "prev")
                        prefixKey("z", "zoom")
                        prefixKey("%", "split")
                        prefixKey("\"", "stack")
                        prefixKey("o", "pane")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                TimelineView(.animation(minimumInterval: 0.05)) { _ in
                    ProgressView(value: max(0, prefixExpiry.timeIntervalSinceNow), total: 3)
                        .progressViewStyle(.circular)
                        .tint(Palette.accent(theme))
                        .frame(width: 26, height: 26)
                }
                .padding(.trailing, 8)
            }
            .background(Palette.dark)
        }

        private func prefixKey(_ key: String, _ title: String) -> some View {
            Button {
                onKey(.sequence(key))
                prefixPaletteActive = false
            } label: {
                HStack(spacing: 4) {
                    Text(key).fontWeight(.bold)
                    Text(title).foregroundStyle(.secondary)
                }
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color(red: 236 / 255, green: 234 / 255, blue: 227 / 255))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Palette.darkKey)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.darkBorder))
            }
            .buttonStyle(.plain)
        }

        private func handle(_ key: ToolbarKey) {
            onKey(key.action)
            if key.action == .sequence("\u{02}") {
                prefixExpiry = Date().addingTimeInterval(3)
                prefixPaletteActive = true
            }
        }

        private func arrowMenu(label: String, primary: ToolbarKey.Action) -> some View {
            Menu {
                Button("↑ up") { onKey(.arrowUp) }
                Button("↓ down") { onKey(.arrowDown) }
                Button("← left") { onKey(.arrowLeft) }
                Button("→ right") { onKey(.arrowRight) }
            } label: {
                keyLabel(label)
            } primaryAction: {
                onKey(primary)
            }
        }

        private func keyLabel(
            _ text: String,
            background: Color? = nil,
            border: Color? = nil,
            foreground: Color? = nil
        ) -> some View {
            Text(text)
                .font(.system(size: 10.5, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .frame(minWidth: 28)
                .background(background ?? Palette.key(theme))
                .foregroundStyle(foreground ?? Palette.text(theme))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(border ?? Palette.border(theme)))
                .shadow(color: Palette.border(theme), radius: 0, y: 1)
        }

        private func keyLabel(icon: String) -> some View {
            Image(systemName: icon)
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .frame(minWidth: 28)
                .background(Palette.key(theme))
                .foregroundStyle(Palette.text(theme))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.border(theme)))
                .shadow(color: Palette.border(theme), radius: 0, y: 1)
        }
    }
#endif
