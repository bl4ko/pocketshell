#if os(iOS)
import Models
import SwiftUI

public struct TerminalToolbar: View {
    let keys: [ToolbarKey]
    @Binding var ctrlActive: Bool
    let onKey: (ToolbarKey.Action) -> Void

    public init(keys: [ToolbarKey], ctrlActive: Binding<Bool>, onKey: @escaping (ToolbarKey.Action) -> Void) {
        self.keys = keys
        self._ctrlActive = ctrlActive
        self.onKey = onKey
    }

    public var body: some View {
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
