#if os(iOS)
import Models
import SwiftUI

public struct TerminalToolbar: View {
    let keys: [ToolbarKey]
    @Binding var ctrlActive: Bool
    let onKey: (ToolbarKey.Action) -> Void
    let onHideKeyboard: (() -> Void)?

    public init(
        keys: [ToolbarKey],
        ctrlActive: Binding<Bool>,
        onKey: @escaping (ToolbarKey.Action) -> Void,
        onHideKeyboard: (() -> Void)? = nil
    ) {
        self.keys = keys
        self._ctrlActive = ctrlActive
        self.onKey = onKey
        self.onHideKeyboard = onHideKeyboard
    }

    public var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(keys) { key in
                        Button {
                            onKey(key.action)
                        } label: {
                            Text(key.label)
                                .font(.system(.footnote, design: .monospaced))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(background(for: key))
                                .foregroundStyle(.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            if let onHideKeyboard {
                Button {
                    onHideKeyboard()
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.15))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
            }
        }
        .background(.thinMaterial)
    }

    private func background(for key: ToolbarKey) -> Color {
        if case .ctrlModifier = key.action, ctrlActive {
            return Color.accentColor.opacity(0.4)
        }
        return Color.secondary.opacity(0.15)
    }
}
#endif
