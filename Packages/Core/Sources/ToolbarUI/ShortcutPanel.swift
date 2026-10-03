#if os(iOS)
    import Models
    import SwiftUI

    public struct ShortcutPanel: View {
        let theme: TerminalTheme
        let userKeys: [ToolbarKey]
        let multiplexer: Bool
        let onKey: (ToolbarKey.Action) -> Void
        let onClose: () -> Void
        @Binding var category: ShortcutCategory
        @State private var arrowShiftActive = false

        private typealias Palette = ToolbarPalette
        private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

        public init(
            theme: TerminalTheme,
            userKeys: [ToolbarKey],
            multiplexer: Bool,
            onKey: @escaping (ToolbarKey.Action) -> Void,
            onClose: @escaping () -> Void,
            category: Binding<ShortcutCategory>
        ) {
            self.theme = theme
            self.userKeys = userKeys
            self.multiplexer = multiplexer
            self.onKey = onKey
            self.onClose = onClose
            self._category = category
        }

        public var body: some View {
            VStack(spacing: 8) {
                header
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
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
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(ShortcutCatalog.windowChips()) { chip in
                                chipButton(chip)
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Palette.bar(theme))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("terminal.shortcuts")
            .onChange(of: multiplexer, initial: true) { _, attached in
                if !attached, category == .multiplexer { category = .favorites }
            }
            .onChange(of: category) { _, _ in arrowShiftActive = false }
            .onDisappear { arrowShiftActive = false }
        }

        private var header: some View {
            HStack(spacing: 6) {
                ForEach(ShortcutCatalog.categories(multiplexer: multiplexer), id: \.self) { item in
                    Button {
                        category = item
                    } label: {
                        headerIcon(item.icon, active: category == item)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.rawValue)
                    .accessibilityValue(category == item ? "selected" : "")
                    .accessibilityIdentifier("shortcuts.\(item.rawValue)")
                }
                if category == .arrows {
                    Button {
                        arrowShiftActive.toggle()
                    } label: {
                        headerIcon("shift", active: arrowShiftActive)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Shift arrows")
                    .accessibilityValue(arrowShiftActive ? "on" : "off")
                    .accessibilityIdentifier("terminal.arrowShift")
                }
                Spacer(minLength: 0)
                Button {
                    arrowShiftActive = false
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(Palette.text(theme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show keyboard")
                .accessibilityIdentifier("shortcuts.close")
            }
        }

        private func headerIcon(_ icon: String, active: Bool) -> some View {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 36, height: 36)
                .background(active ? Palette.accentTint(theme) : Palette.key(theme))
                .foregroundStyle(active ? Palette.accentDark(theme) : Palette.text(theme))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(active ? Palette.accentBorder(theme) : Palette.border(theme))
                )
                .padding(4)
                .contentShape(Rectangle())
        }

        private func chipButton(_ chip: ShortcutChip) -> some View {
            Button {
                if category == .arrows, arrowShiftActive,
                    let data = ToolbarKeyEncoder.data(for: chip.action, shift: true)
                {
                    onKey(.sequence(String(decoding: data, as: UTF8.self)))
                } else {
                    onKey(chip.action)
                }
                arrowShiftActive = false
            } label: {
                VStack(spacing: 2) {
                    Text(chip.glyph)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.text(theme))
                    Text(chip.label.isEmpty ? " " : chip.label)
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.text(theme).opacity(0.6))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Palette.key(theme))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border(theme)))
            }
            .buttonStyle(.plain)
            .buttonRepeatBehavior(category == .arrows ? .enabled : .disabled)
            .accessibilityIdentifier(
                category == .arrows ? "terminal.arrow.\(chip.glyph)" : "shortcuts.key.\(chip.glyph)")
        }
    }
#endif
