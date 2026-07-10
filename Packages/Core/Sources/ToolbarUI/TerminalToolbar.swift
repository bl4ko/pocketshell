#if os(iOS)
import Models
import SwiftUI

public struct TerminalToolbar: View {
    let keys: [ToolbarKey]
    @Binding var ctrlActive: Bool
    let onKey: (ToolbarKey.Action) -> Void
    let onHideKeyboard: (() -> Void)?
    let onPaste: (() -> Void)?
    let onCopy: (() -> Void)?

    public init(
        keys: [ToolbarKey],
        ctrlActive: Binding<Bool>,
        onKey: @escaping (ToolbarKey.Action) -> Void,
        onHideKeyboard: (() -> Void)? = nil,
        onPaste: (() -> Void)? = nil,
        onCopy: (() -> Void)? = nil
    ) {
        self.keys = keys
        self._ctrlActive = ctrlActive
        self.onKey = onKey
        self.onHideKeyboard = onHideKeyboard
        self.onPaste = onPaste
        self.onCopy = onCopy
    }

    public var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let onPaste {
                        Menu {
                            Button("Paste") { onPaste() }
                            if let onCopy {
                                Button("Copy selection") { onCopy() }
                            }
                        } label: {
                            keyLabel(icon: "doc.on.clipboard")
                        } primaryAction: {
                            onPaste()
                        }
                    }
                    ForEach(ToolbarKey.scrollRow(from: keys)) { key in
                        Button {
                            onKey(key.action)
                        } label: {
                            keyLabel(key.label)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            Divider()
                .frame(height: 24)
            HStack(spacing: 5) {
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
                    keyLabel("ctrl", background: ctrlBackground)
                }
                .buttonStyle(.plain)
                if let onHideKeyboard {
                    Button {
                        onHideKeyboard()
                    } label: {
                        keyLabel(icon: "keyboard", background: Color.accentColor.opacity(0.2))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .background(.thinMaterial)
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

    private var ctrlBackground: Color {
        ctrlActive ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15)
    }

    private func keyLabel(_ text: String, background: Color? = nil) -> some View {
        Text(text)
            .font(.system(.footnote, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(background ?? Color.secondary.opacity(0.15))
            .foregroundStyle(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func keyLabel(icon: String, background: Color? = nil) -> some View {
        Image(systemName: icon)
            .font(.footnote)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(background ?? Color.secondary.opacity(0.15))
            .foregroundStyle(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
#endif
