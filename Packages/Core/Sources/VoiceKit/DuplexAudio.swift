#if os(iOS)
    @preconcurrency import AVFoundation
    import Foundation
    import UIKit

    @MainActor
    public final class DuplexAudio: MicrophoneSource {
        public var onInputLevel: ((Float) -> Void)?
        public var onInterruption: ((Bool) -> Void)?
        public private(set) var running = false
        public private(set) var line: PlaybackLine
        private let tap = MicrophoneTap()
        private var engine = AVAudioEngine()
        private var observers: [NSObjectProtocol] = []
        private var restarts = 0
        private var recovery = AudioRecovery()

        public init() {
            line = PlaybackLine(player: AVAudioPlayerNode())
        }

        public var report: String {
            let session = AVAudioSession.sharedInstance()
            let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }
            let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }
            return "running=\(running) engine=\(engine.isRunning) vp=\(engine.inputNode.isVoiceProcessingEnabled)"
                + " paused=\(recovery.paused) restarts=\(restarts) in=\(inputs.joined(separator: ",")) out=\(outputs.joined(separator: ","))"
        }

        public func setSink(_ sink: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
            tap.sink = sink
        }

        public func setRecorder(_ recorder: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
            tap.recorder = recorder
        }

        public func start() throws {
            guard !running else { return }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            try build()
            running = true
            recovery = AudioRecovery()
            observe()
        }

        public func stop() {
            guard running else { return }
            running = false
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            line.stop()
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            tap.sink = nil
            tap.recorder = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        private func build() throws {
            let input = engine.inputNode
            if !input.isVoiceProcessingEnabled { try input.setVoiceProcessingEnabled(true) }
            if line.player.engine !== engine { engine.attach(line.player) }
            engine.connect(line.player, to: engine.mainMixerNode, format: line.format)
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw NoMicrophone() }
            Self.installTap(on: input, format: format, tap: tap) { [weak self] level in self?.onInputLevel?(level) }
            engine.prepare()
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw error
            }
        }

        private func rebuild(fresh: Bool) -> Bool {
            guard running else { return false }
            restarts += 1
            line.stop()
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            if fresh {
                engine = AVAudioEngine()
                line = PlaybackLine(player: AVAudioPlayerNode())
            }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try build()
                return true
            } catch {
                return false
            }
        }

        private func recover(_ event: AudioRecovery.Event) {
            guard running else { return }
            switch recovery.handle(event, engineRunning: engine.isRunning) {
            case .none:
                break
            case .pause:
                line.stop()
                onInterruption?(true)
            case .restart:
                recover(.restarted(rebuild(fresh: false)))
            case .resumed:
                onInterruption?(false)
            }
        }

        private func observe() {
            let center = NotificationCenter.default
            observers.append(
                center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.recover(.restarted(self.rebuild(fresh: false)))
                    }
                })
            observers.append(
                center.addObserver(
                    forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.recover(.restarted(self.rebuild(fresh: true)))
                    }
                })
            observers.append(
                center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) {
                    [weak self] note in
                    let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue ?? 0
                    let began = AVAudioSession.InterruptionType(rawValue: raw) == .began
                    MainActor.assumeIsolated { self?.recover(began ? .interruptionBegan : .interruptionEnded) }
                })
            observers.append(
                center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.recover(.appActive) }
                })
        }

        nonisolated private static func installTap(
            on node: AVAudioInputNode, format: AVAudioFormat, tap: MicrophoneTap,
            level: @escaping @MainActor (Float) -> Void
        ) {
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                if let peak = tap.append(buffer) {
                    Task { @MainActor in level(peak) }
                }
            }
        }
    }

    private struct NoMicrophone: LocalizedError {
        var errorDescription: String? { "No microphone input is available" }
    }

    final class MicrophoneTap: @unchecked Sendable {
        private let lock = NSLock()
        private var target: (@Sendable (AVAudioPCMBuffer) -> Void)?
        private var recording: (@Sendable (AVAudioPCMBuffer) -> Void)?
        private var count = 0

        var sink: (@Sendable (AVAudioPCMBuffer) -> Void)? {
            get { lock.withLock { target } }
            set { lock.withLock { target = newValue } }
        }

        var recorder: (@Sendable (AVAudioPCMBuffer) -> Void)? {
            get { lock.withLock { recording } }
            set { lock.withLock { recording = newValue } }
        }

        func append(_ buffer: AVAudioPCMBuffer) -> Float? {
            let (sink, recorder, index) = lock.withLock {
                () -> ((@Sendable (AVAudioPCMBuffer) -> Void)?, (@Sendable (AVAudioPCMBuffer) -> Void)?, Int) in
                count += 1
                return (target, recording, count)
            }
            sink?(buffer)
            recorder?(buffer)
            guard index % 3 == 0, let samples = buffer.floatChannelData?[0] else { return nil }
            var peak: Float = 0
            for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[frame])) }
            return min(1, peak * 4)
        }
    }

    public final class PlaybackLine: AudioLine, @unchecked Sendable {
        public let player: AVAudioPlayerNode
        public let format: AVAudioFormat
        private let lock = NSLock()
        private var converter: AVAudioConverter?

        init(player: AVAudioPlayerNode) {
            self.player = player
            format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        }

        public func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void) -> Bool {
            guard let converted = convert(buffer), player.engine?.isRunning == true else { return false }
            player.scheduleBuffer(converted, completionCallbackType: .dataPlayedBack) { _ in completion() }
            if !player.isPlaying { player.play() }
            return true
        }

        public func stop() {
            player.stop()
        }

        private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            if buffer.format == format { return buffer }
            return lock.withLock {
                if converter?.inputFormat != buffer.format {
                    converter = AVAudioConverter(from: buffer.format, to: format)
                }
                guard let converter, buffer.frameLength > 0 else { return nil }
                let ratio = format.sampleRate / buffer.format.sampleRate
                let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
                guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
                nonisolated(unsafe) var fed = false
                var error: NSError?
                converter.convert(to: out, error: &error) { _, status in
                    if fed {
                        status.pointee = .noDataNow
                        return nil
                    }
                    fed = true
                    status.pointee = .haveData
                    return buffer
                }
                return error == nil && out.frameLength > 0 ? out : nil
            }
        }
    }
#endif
