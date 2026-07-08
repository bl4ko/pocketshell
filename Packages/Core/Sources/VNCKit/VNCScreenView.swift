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
    @State private var fullscreen = false
    @State private var fillScreen = false
    @State private var addingShortcut = false
    @State private var newShortcutText = ""
    @AppStorage("pocketshell.vncCustomShortcuts") private var customShortcutsRaw = ""
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
            .ignoresSafeArea(.container, edges: fullscreen ? .top : [])
            controlBar
        }
        .toolbar(fullscreen ? .hidden : .automatic, for: .navigationBar)
        .statusBarHidden(fullscreen)
        .animation(.easeInOut(duration: 0.2), value: fullscreen)
        .alert("Add shortcut", isPresented: $addingShortcut) {
            TextField("cmd+shift+4", text: $newShortcutText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") { addShortcut() }
            Button("Cancel", role: .cancel) { newShortcutText = "" }
        } message: {
            Text("Modifiers: cmd, shift, ctrl, alt. Keys: letters, digits, space, tab, esc, return, arrows, f1-f19.")
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
                    .aspectRatio(contentMode: fillScreen ? .fill : .fit)
                    .frame(width: viewSize.width, height: viewSize.height)
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
                        resetZoom()
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

    private func resetZoom() {
        zoom = 1
        offset = .zero
        offsetAtGestureStart = .zero
        zoomAtGestureStart = 1
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
            offset: offset,
            fill: fillScreen
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
                controlButton(keyboardFocused ? "keyboard.chevron.compact.down" : "keyboard", active: keyboardFocused) {
                    keyboardFocused.toggle()
                }
                controlButton("command", active: commandActive) {
                    commandActive.toggle()
                }
                shortcutsMenu
                controlButton("aspectratio", active: fillScreen) {
                    fillScreen.toggle()
                    resetZoom()
                }
                controlButton(
                    fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    active: fullscreen
                ) {
                    fullscreen.toggle()
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
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        keyboardAccessory
                    }
                }
        }
    }

    private var keyboardAccessory: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                controlButton("keyboard.chevron.compact.down") { keyboardFocused = false }
                controlButton("command", active: commandActive) { commandActive.toggle() }
                shortcutsMenu
                controlButton("escape") { sendKey(.escape) }
                controlButton("arrow.right.to.line") { sendKey(.tab) }
                controlButton("arrow.left") { sendKey(.leftArrow) }
                controlButton("arrow.up") { sendKey(.upArrow) }
                controlButton("arrow.down") { sendKey(.downArrow) }
                controlButton("arrow.right") { sendKey(.rightArrow) }
            }
        }
    }

    private var customShortcuts: [VNCKeyCombo] {
        customShortcutsRaw
            .split(separator: "\n")
            .compactMap { VNCKeyCombo.parse(String($0)) }
    }

    private var shortcutsMenu: some View {
        Menu {
            ForEach(VNCKeyCombo.presets) { combo in
                Button(combo.label) { sendCombo(combo) }
            }
            if !customShortcuts.isEmpty {
                Divider()
                ForEach(customShortcuts) { combo in
                    Button(combo.label) { sendCombo(combo) }
                }
                Menu("Remove custom") {
                    ForEach(customShortcuts) { combo in
                        Button(combo.label, role: .destructive) { removeShortcut(combo) }
                    }
                }
            }
            Divider()
            Button {
                addingShortcut = true
            } label: {
                Label("Add custom…", systemImage: "plus")
            }
        } label: {
            Image(systemName: "command.square")
                .font(.system(size: 16))
                .frame(width: 40, height: 32)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
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

    private func addShortcut() {
        let text = newShortcutText.trimmingCharacters(in: .whitespaces)
        newShortcutText = ""
        guard let combo = VNCKeyCombo.parse(text),
              !customShortcuts.contains(combo),
              !VNCKeyCombo.presets.contains(combo) else { return }
        customShortcutsRaw = (customShortcuts.isEmpty ? text : customShortcutsRaw + "\n" + text)
    }

    private func removeShortcut(_ combo: VNCKeyCombo) {
        customShortcutsRaw = customShortcutsRaw
            .split(separator: "\n")
            .filter { VNCKeyCombo.parse(String($0)) != combo }
            .joined(separator: "\n")
    }

    private func sendCombo(_ combo: VNCKeyCombo) {
        session.sendKey(combo.key, modifiers: combo.modifiers)
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
