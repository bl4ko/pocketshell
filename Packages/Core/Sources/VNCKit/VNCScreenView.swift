#if os(iOS)
import RoyalVNCKit
import SwiftUI
import UIKit

public struct VNCScreenView: View {
    private let session: VNCSessionController
    @State private var commandActive = false
    @State private var controlActive = false
    @State private var fullscreen = false
    @State private var fillScreen = false
    @State private var keyboardVisible = false
    @State private var addingShortcut = false
    @State private var newShortcutText = ""
    @AppStorage("pocketshell.vncCustomShortcuts") private var customShortcutsRaw = ""

    public init(session: VNCSessionController) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            VNCStatusBanner(session: session)
            VNCCanvas(session: session, fill: fillScreen)
                .ignoresSafeArea(.container, edges: fullscreen ? .top : [])
                .background(keyInput)
            if !keyboardVisible {
                controlBar
            }
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

    private var keyInput: some View {
        VNCKeyInputView(
            focused: $keyboardVisible,
            onInsert: { handleInsert($0) },
            onDelete: { sendKey(.delete) }
        ) {
            keyboardAccessory
        }
        .frame(width: 1, height: 1)
        .opacity(0.02)
    }

    private var controlBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                controlButton("keyboard") { keyboardVisible = true }
                controlButton("doc.on.clipboard") { pasteClipboard() }
                controlButton("command", active: commandActive) { commandActive.toggle() }
                controlButton("control", active: controlActive) { controlActive.toggle() }
                shortcutsMenu
                controlButton("aspectratio", active: fillScreen) { fillScreen.toggle() }
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
    }

    private var keyboardAccessory: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                controlButton("keyboard.chevron.compact.down") { keyboardVisible = false }
                controlButton("doc.on.clipboard") { pasteClipboard() }
                controlButton("command", active: commandActive) { commandActive.toggle() }
                controlButton("control", active: controlActive) { controlActive.toggle() }
                shortcutsMenu
                controlButton("escape") { sendKey(.escape) }
                controlButton("arrow.right.to.line") { sendKey(.tab) }
                controlButton("arrow.left") { sendKey(.leftArrow) }
                controlButton("arrow.up") { sendKey(.upArrow) }
                controlButton("arrow.down") { sendKey(.downArrow) }
                controlButton("arrow.right") { sendKey(.rightArrow) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.thinMaterial)
    }

    private func pasteClipboard() {
        guard let text = UIPasteboard.general.string else { return }
        session.sendText(text)
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

    private var activeModifiers: [VNCKeyCode] {
        var modifiers: [VNCKeyCode] = []
        if controlActive { modifiers.append(.control) }
        if commandActive { modifiers.append(.commandForARD) }
        return modifiers
    }

    private func consumeModifiers() -> [VNCKeyCode] {
        let modifiers = activeModifiers
        commandActive = false
        controlActive = false
        return modifiers
    }

    private func sendKey(_ key: VNCKeyCode) {
        let modifiers = consumeModifiers()
        if modifiers.isEmpty {
            session.sendKey(key)
        } else {
            session.sendKey(key, modifiers: modifiers)
        }
    }

    private func handleInsert(_ text: String) {
        for character in text {
            if character == "\n" {
                sendKey(.return)
            } else if !activeModifiers.isEmpty {
                if let key = VNCKeyCode.keyCodesFrom(characters: String(character)).first {
                    session.sendKey(key, modifiers: consumeModifiers())
                }
            } else {
                session.sendText(String(character))
            }
        }
    }
}

private struct VNCStatusBanner: View {
    @ObservedObject var session: VNCSessionController

    var body: some View {
        switch session.phase {
        case .failed(let message):
            banner(message, color: .red)
        case .disconnected:
            banner("disconnected", color: .orange)
        default:
            EmptyView()
        }
    }

    private func banner(_ text: String, color: Color) -> some View {
        HStack {
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(color)
                .lineLimit(2)
            Spacer()
            Button("Reconnect") { session.connect() }
                .font(.caption.bold())
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.15))
    }
}

private struct VNCCanvas: View {
    @ObservedObject var session: VNCSessionController
    let fill: Bool
    @State private var zoom: CGFloat = 1
    @State private var zoomAtGestureStart: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var offsetAtGestureStart: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            screen(in: geometry.size)
        }
        .background(Color.black)
        .clipped()
        .onChange(of: fill) { _, _ in
            resetZoom()
        }
    }

    private func screen(in viewSize: CGSize) -> some View {
        ZStack {
            Color.black
            if let image = session.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
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
            fill: fill
        )
    }
}
#endif
