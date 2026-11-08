#if !os(watchOS)
    @preconcurrency import AVFoundation
    import Foundation

    @MainActor
    public protocol MicrophoneSource: AnyObject {
        var onInputLevel: ((Float) -> Void)? { get set }
        func setSink(_ sink: (@Sendable (AVAudioPCMBuffer) -> Void)?)
    }

    public protocol AudioLine: AnyObject, Sendable {
        func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void) -> Bool
        func stop()
    }

    public final class AudioTimeline: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 0
        private var last: TimeInterval = 0
        private let clock: @Sendable () -> TimeInterval

        public init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
            self.clock = clock
        }

        public func advance(seconds added: TimeInterval) {
            let now = clock()
            lock.withLock {
                seconds += added
                last = now
            }
        }

        public var audioSeconds: TimeInterval { lock.withLock { seconds } }

        public func uptime(atAudioSecond second: TimeInterval) -> TimeInterval {
            lock.withLock { last - max(0, seconds - second) }
        }
    }

    public final class PCM16Resampler: @unchecked Sendable {
        public static let sampleRate: Double = 16000
        public let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: PCM16Resampler.sampleRate, channels: 1, interleaved: true)!
        private let lock = NSLock()
        private var converter: AVAudioConverter?

        public init() {}

        public func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
            lock.withLock {
                guard buffer.frameLength > 0 else { return nil }
                if converter?.inputFormat != buffer.format {
                    converter = AVAudioConverter(from: buffer.format, to: format)
                }
                guard let converter else { return nil }
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
                guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return nil }
                return Data(bytes: samples, count: Int(out.frameLength) * 2)
            }
        }
    }

    public enum PCM {
        public static func floatBuffer(s16le data: Data, sampleRate: Double) -> AVAudioPCMBuffer? {
            let frames = data.count / 2
            guard frames > 0,
                let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                let out = buffer.floatChannelData?[0]
            else { return nil }
            data.withUnsafeBytes { raw in
                for index in 0..<frames {
                    let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                    out[index] = Float(sample) / 32768
                }
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            return buffer
        }

        public static func level(_ buffer: AVAudioPCMBuffer) -> Float {
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return 0 }
            var sum: Float = 0
            if let samples = buffer.floatChannelData?[0] {
                for frame in 0..<frames { sum += samples[frame] * samples[frame] }
            } else if let samples = buffer.int16ChannelData?[0] {
                for frame in 0..<frames {
                    let value = Float(samples[frame]) / Float(Int16.max)
                    sum += value * value
                }
            }
            return min(1, (sum / Float(frames)).squareRoot() * 5)
        }

        public static func wav(s16le samples: Data, sampleRate: Int) -> Data {
            var data = Data()
            func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
            func put(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
            data.append(contentsOf: Array("RIFF".utf8))
            put(UInt32(36 + samples.count))
            data.append(contentsOf: Array("WAVEfmt ".utf8))
            put(UInt32(16))
            put(UInt16(1))
            put(UInt16(1))
            put(UInt32(sampleRate))
            put(UInt32(sampleRate * 2))
            put(UInt16(2))
            put(UInt16(16))
            data.append(contentsOf: Array("data".utf8))
            put(UInt32(samples.count))
            data.append(samples)
            return data
        }
    }
#endif
