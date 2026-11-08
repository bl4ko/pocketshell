import BrainKit
import SwiftUI
import VoiceKit

struct VoiceBrainBarHost: View {
    @ObservedObject var session: VoiceBrainSession

    var body: some View {
        if let brain = session.brain {
            VoiceBrainBar(brain: brain, testEars: session.testEars)
        }
    }
}

struct VoiceBrainBar: View {
    @ObservedObject var brain: VoiceBrain
    let testEars: TextEars?
    @State private var expanded = false
    @State private var testInput = ""

    var body: some View {
        if brain.isOn {
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Button {
                        expanded = true
                    } label: {
                        VoiceOrb(
                            phase: brain.phase, input: brain.inputLevel, output: brain.outputLevel, muted: brain.muted
                        )
                        .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Expand voice mode")
                    .accessibilityIdentifier("voice.orb")
                    Text(VoiceBrainText.caption(brain))
                        .font(.callout)
                        .foregroundStyle(PocketshellTheme.ink)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("voice.caption")
                    VoiceBrainControls(brain: brain, compact: true)
                }
                if let testEars {
                    TextField("say…", text: $testInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit {
                            testEars.submit(testInput)
                            testInput = ""
                        }
                        .accessibilityIdentifier("voice.testInput")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(PocketshellTheme.surface)
            .overlay(alignment: .top) { Rectangle().fill(PocketshellTheme.divider).frame(height: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("voice.bar")
            .fullScreenCover(isPresented: $expanded) {
                VoiceBrainFullView(brain: brain, onCollapse: { expanded = false })
            }
            .onChange(of: brain.isOn) { _, on in
                if !on { expanded = false }
            }
        }
    }
}

struct VoiceBrainFullView: View {
    @ObservedObject var brain: VoiceBrain
    let onCollapse: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Button(action: onCollapse) {
                    Image(systemName: "chevron.down")
                        .font(.title2)
                        .foregroundStyle(PocketshellTheme.secondary)
                }
                .accessibilityLabel("Collapse voice mode")
                .accessibilityIdentifier("voice.collapse")
                Spacer()
                Text(brain.hostName)
                    .font(.headline)
                    .foregroundStyle(PocketshellTheme.ink)
                Spacer()
                Color.clear.frame(width: 28, height: 28)
            }
            Spacer()
            VoiceOrb(phase: brain.phase, input: brain.inputLevel, output: brain.outputLevel, muted: brain.muted)
                .frame(width: 220, height: 220)
                .onTapGesture(perform: onCollapse)
                .accessibilityIdentifier("voice.orb.large")
            Text(VoiceBrainText.caption(brain))
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(PocketshellTheme.ink)
                .lineLimit(6)
                .accessibilityIdentifier("voice.caption.full")
            if let detail = brain.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(PocketshellTheme.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(8)
                    .accessibilityIdentifier("voice.detail")
            }
            Spacer()
            VoiceBrainControls(brain: brain, compact: false)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PocketshellTheme.paper)
    }
}

private struct VoiceBrainControls: View {
    @ObservedObject var brain: VoiceBrain
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 12 : 48) {
            Button {
                brain.setMuted(!brain.muted)
            } label: {
                Image(systemName: brain.muted ? "mic.slash.fill" : "mic.fill")
                    .font(compact ? .title3 : .largeTitle)
                    .foregroundStyle(brain.muted ? PocketshellTheme.accent : PocketshellTheme.secondary)
                    .frame(width: compact ? 30 : 64, height: compact ? 30 : 64)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(brain.muted ? "Unmute" : "Mute")
            .accessibilityIdentifier("voice.mute")
            Button {
                brain.end()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(compact ? .title2 : .largeTitle)
                    .foregroundStyle(compact ? PocketshellTheme.secondary : Color.red)
                    .frame(width: compact ? 30 : 64, height: compact ? 30 : 64)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End voice mode")
            .accessibilityIdentifier("voice.end")
        }
    }
}

enum VoiceBrainText {
    @MainActor
    static func caption(_ brain: VoiceBrain) -> String {
        if let caption = brain.caption, !caption.text.isEmpty { return caption.text }
        switch brain.mode {
        case .off: return ""
        case .starting: return "Starting…"
        case .dictation(let reason): return reason
        case .conversing: break
        }
        if brain.muted { return "Muted" }
        switch brain.phase {
        case .listening: return "Listening…"
        case .userSpeaking: return "Hearing you…"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking…"
        }
    }
}

struct VoiceOrb: View {
    let phase: TurnTaking.Phase
    let input: Float
    let output: Float
    let muted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                draw(in: &canvas, size: size, time: time)
            }
        }
        .animation(.easeOut(duration: 0.15), value: input)
        .animation(.easeOut(duration: 0.15), value: output)
    }

    private var energy: Double {
        switch phase {
        case .speaking: Double(max(output, 0.25))
        case .userSpeaking, .listening: muted ? 0 : Double(input)
        case .thinking: 0.15
        }
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, time: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2
        let base = radius * (0.62 + 0.18 * energy)
        let accent = muted ? PocketshellTheme.muted : PocketshellTheme.accent
        let glow = Path(
            ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        canvas.fill(
            glow,
            with: .radialGradient(
                Gradient(colors: [accent.opacity(0.28 + 0.3 * energy), accent.opacity(0)]),
                center: center, startRadius: base * 0.6, endRadius: radius))
        var blob = Path()
        let lobes = phase == .speaking ? 5.0 : 3.0
        let wobble = (phase == .thinking ? 0.05 : 0.04 + 0.1 * energy) * base
        for step in 0...72 {
            let angle = Double(step) / 72 * 2 * .pi
            let swing = sin(angle * lobes + time * 2.2) * wobble + cos(angle * 2 - time * 1.3) * wobble * 0.6
            let point = CGPoint(x: center.x + cos(angle) * (base + swing), y: center.y + sin(angle) * (base + swing))
            if step == 0 { blob.move(to: point) } else { blob.addLine(to: point) }
        }
        blob.closeSubpath()
        canvas.fill(
            blob,
            with: .linearGradient(
                Gradient(colors: [accent, accent.opacity(0.55), PocketshellTheme.waiting.opacity(muted ? 0.2 : 0.7)]),
                startPoint: CGPoint(x: center.x - base, y: center.y - base),
                endPoint: CGPoint(x: center.x + base, y: center.y + base)))
        if phase == .thinking {
            var ring = Path()
            ring.addArc(
                center: center, radius: base * 1.18, startAngle: .radians(time * 3),
                endAngle: .radians(time * 3 + 1.6), clockwise: false)
            canvas.stroke(
                ring, with: .color(accent.opacity(0.8)),
                style: StrokeStyle(lineWidth: max(1.5, radius * 0.06), lineCap: .round))
        }
        let shine = Path(
            ellipseIn: CGRect(
                x: center.x - base * 0.45, y: center.y - base * 0.6, width: base * 0.5, height: base * 0.32))
        canvas.fill(shine, with: .color(.white.opacity(0.22)))
    }
}
