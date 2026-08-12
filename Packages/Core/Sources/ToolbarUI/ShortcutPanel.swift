#if os(iOS)
    import Models
    import SwiftUI

    struct ShortcutPanel: View {
        let theme: TerminalTheme
        let userKeys: [ToolbarKey]
        let multiplexer: Bool
        let onKey: (ToolbarKey.Action) -> Void
        let onClose: () -> Void
        @Binding var category: ShortcutCategory

        private typealias Palette = ToolbarPalette
        private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

        var body: some View {
            VStack(spacing: 6) {
                header
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(ShortcutCatalog.chips(category, userKeys: userKeys)) { chip in
                            chipButton(chip)
                        }
                    }
                    if category == .multiplexer {
                        Text("Window")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Palette.text(theme).opacity(0.6))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(ShortcutCatalog.windowChips()) { chip in
                                chipButton(chip)
                            }
                        }
                    }
                }
                .frame(maxHeight: 168)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(Palette.bar(theme))
            .accessibilityIdentifier("terminal.shortcuts")
        }

        private var header: some View {
            HStack(spacing: 6) {
                ForEach(ShortcutCatalog.categories(multiplexer: multiplexer), id: \.self) { item in
                    Button {
                        category = item
                    } label: {
                        Image(systemName: item.icon)
                            .font(.system(size: 12))
                            .frame(width: 32, height: 26)
                            .background(category == item ? Palette.accentTint(theme) : Palette.key(theme))
                            .foregroundStyle(category == item ? Palette.accentDark(theme) : Palette.text(theme))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(category == item ? Palette.accentBorder(theme) : Palette.border(theme))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("shortcuts.\(item.rawValue)")
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .frame(width: 32, height: 26)
                        .foregroundStyle(Palette.text(theme))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("shortcuts.close")
            }
        }

        private func chipButton(_ chip: ShortcutChip) -> some View {
            Button {
                onKey(chip.action)
            } label: {
                VStack(spacing: 1) {
                    Text(chip.glyph)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.text(theme))
                    if !chip.label.isEmpty {
                        Text(chip.label)
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(Palette.text(theme).opacity(0.6))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Palette.key(theme))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border(theme)))
            }
            .buttonStyle(.plain)
        }
    }
#endif
