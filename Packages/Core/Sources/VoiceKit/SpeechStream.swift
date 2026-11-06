#if !os(watchOS)
    @preconcurrency import AVFoundation
    import Foundation
    @preconcurrency import Speech

    @available(iOS 26, macOS 26, *)
    public final class SpeechStream: @unchecked Sendable {
        public enum Event: Equatable, Sendable {
            case partial(String)
            case phrase(String)
        }

        public let events: AsyncThrowingStream<Event, Error>
        public let engine: String
        public let locale: Locale
        public let format: AVAudioFormat
        private let analyzer: SpeechAnalyzer
        private let input: AsyncStream<AnalyzerInput>.Continuation
        private let lock = NSLock()
        private var converter: AVAudioConverter?

        public static func make(
            contextualStrings: [String], installing: @escaping @Sendable () -> Void = {}
        ) async throws -> SpeechStream {
            let preferred =
                Locale.current.language.languageCode == .english ? Locale.current : Locale(identifier: "en-US")
            if SpeechTranscriber.isAvailable,
                let locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferred)
            {
                return try await SpeechStream(
                    module: SpeechTranscriber(locale: locale, preset: .progressiveTranscription), engine: "speech",
                    locale: locale, contextualStrings: contextualStrings, installing: installing, text: { $0.text })
            }
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: preferred) else {
                throw Unsupported()
            }
            return try await SpeechStream(
                module: DictationTranscriber(locale: locale, preset: .progressiveLongDictation), engine: "dictation",
                locale: locale, contextualStrings: contextualStrings, installing: installing, text: { $0.text })
        }

        private init<Module: SpeechModule>(
            module: Module, engine: String, locale: Locale, contextualStrings: [String],
            installing: @escaping @Sendable () -> Void, text: @escaping @Sendable (Module.Result) -> AttributedString
        ) async throws {
            _ = try? await AssetInventory.reserve(locale: locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                installing()
                try await request.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                throw Unsupported()
            }
            let (audio, input) = AsyncStream<AnalyzerInput>.makeStream()
            let (events, sink) = AsyncThrowingStream<Event, Error>.makeStream()
            let analyzer = SpeechAnalyzer(
                modules: [module], options: .init(priority: .userInitiated, modelRetention: .lingering))
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try await analyzer.setContext(context)
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: audio)
            Task {
                do {
                    for try await result in module.results {
                        let words = String(text(result).characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        sink.yield(
                            result.isFinal && !words.isEmpty ? .phrase(words) : .partial(result.isFinal ? "" : words))
                    }
                    sink.finish()
                } catch {
                    sink.finish(throwing: error)
                }
            }
            self.events = events
            self.engine = engine
            self.locale = locale
            self.format = format
            self.analyzer = analyzer
            self.input = input
        }

        public func append(_ buffer: AVAudioPCMBuffer) {
            lock.withLock {
                if converter?.inputFormat != buffer.format {
                    converter = AVAudioConverter(from: buffer.format, to: format)
                }
                guard let converter, buffer.frameLength > 0 else { return }
                let ratio = format.sampleRate / buffer.format.sampleRate
                let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
                guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
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
                if error == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
            }
        }

        public func flush() async {
            try? await analyzer.finalize(through: nil)
        }

        public func finish() async {
            input.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        private struct Unsupported: LocalizedError {
            var errorDescription: String? { "Speech recognition is not available for this language" }
        }
    }
#endif
