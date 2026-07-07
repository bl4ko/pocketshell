#if os(iOS)
import RoyalVNCKit
import SwiftUI

public struct VNCScreenView: View {
    @ObservedObject private var session: VNCSessionController
    @State private var zoom: CGFloat = 1
    @State private var zoomAtGestureStart: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var offsetAtGestureStart: CGSize = .zero
    @State private var keyboardText = sentinel
    @State private var commandActive = false
    @FocusState private var keyboardFocused: Bool

    private static let sentinel = "\u{200b}"

    public init(session: VNCSessionController) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            statusBanner
            GeometryReader { geometry in
                screen(in: geometry.size)
            }
            .background(Color.black)
            .clipped()
            controlBar
        }
        .onDisappear {
            session.disconnect()
        }
    }

    private func screen(in viewSize: CGSize) -> some View {
        ZStack {
            Color.black
            if let image = session.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom)
                    .offset(offset)
            } else if session.phase == .connecting {
                ProgressView()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { location in
            if let point = framebufferPoint(location, viewSize: viewSize) {
                session.click(.left, at: point)
            }
        }
        .gesture(longPressRightClick(viewSize: viewSize))
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    zoom = min(max(zoomAtGestureStart * value.magnification, 1), 8)
                }
                .onEnded { _ in
                    zoomAtGestureStart = zoom
                    if zoom <= 1.01 {
                        zoom = 1
                        offset = .zero
                        offsetAtGestureStart = .zero
                        zoomAtGestureStart = 1
                    }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard zoom > 1 else { return }
                    offset = CGSize(
                        width: offsetAtGestureStart.width + value.translation.width,
                        height: offsetAtGestureStart.height + value.translation.height
                    )
                }
                .onEnded { _ in
                    offsetAtGestureStart = offset
                }
        )
    }

    private func longPressRightClick(viewSize: CGSize) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onEnded { value in
                if case .second(true, let drag) = value, let drag,
                   let point = framebufferPoint(drag.location, viewSize: viewSize) {
                    session.click(.right, at: point)
                }
            }
    }

    private func framebufferPoint(_ touch: CGPoint, viewSize: CGSize) -> CGPoint? {
        VNCPointerMath.framebufferPoint(
            touch: touch,
            viewSize: viewSize,
            imageSize: session.framebufferSize,
            zoom: zoom,
            offset: offset
        )
    }

    private var statusBanner: some View {
        Group {
            switch session.phase {
            case .failed(let message):
                bannerText(message, color: .red)
            case .disconnected:
                bannerText("disconnected", color: .orange)
            default:
                EmptyView()
            }
        }
    }

    private func bannerText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(color.opacity(0.15))
    }

    private var controlBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                controlButton("keyboard") {
                    keyboardFocused.toggle()
                }
                controlButton("command", active: commandActive) {
                    commandActive.toggle()
                }
                controlButton("escape") { sendKey(.escape) }
                controlButton("arrow.left") { sendKey(.leftArrow) }
                controlButton("arrow.up") { sendKey(.upArrow) }
                controlButton("arrow.down") { sendKey(.downArrow) }
                controlButton("arrow.right") { sendKey(.rightArrow) }
                controlButton("arrow.turn.down.left") { sendKey(.return) }
                controlButton("delete.left") { sendKey(.delete) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.thinMaterial)
        .overlay {
            TextField("", text: $keyboardText)
                .focused($keyboardFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .opacity(0.011)
                .frame(width: 1, height: 1)
                .onChange(of: keyboardText) { oldValue, newValue in
                    handleKeyboardChange(from: oldValue, to: newValue)
                }
        }
    }

    private func controlButton(_ systemImage: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .frame(width: 40, height: 32)
                .background(active ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func sendKey(_ key: VNCKeyCode) {
        if commandActive {
            commandActive = false
            session.sendKey(key, modifiers: [.commandForARD])
        } else {
            session.sendKey(key)
        }
    }

    private func handleKeyboardChange(from oldValue: String, to newValue: String) {
        guard newValue != Self.sentinel else { return }
        if newValue.isEmpty || !newValue.hasPrefix(Self.sentinel) {
            sendKey(.delete)
        } else {
            let typed = String(newValue.dropFirst(Self.sentinel.count))
            for character in typed {
                if character == "\n" {
                    sendKey(.return)
                } else if commandActive {
                    commandActive = false
                    if let key = VNCKeyCode.keyCodesFrom(characters: String(character)).first {
                        session.sendKey(key, modifiers: [.commandForARD])
                    }
                } else {
                    session.sendText(String(character))
                }
            }
        }
        keyboardText = Self.sentinel
    }
}
#endif
