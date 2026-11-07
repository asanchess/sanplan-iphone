import AVFoundation
import Foundation
import Speech

/// Live speech-to-text with Apple Speech (ru-RU, on the phone when the model is installed).
/// The words stream into `InputDrafts`; nothing is sent to ARNA's server. Money is recognised only on the phone.
@MainActor
public final class SpeechDictation: ObservableObject {
    @Published public private(set) var target: InputDrafts.Target?
    @Published public private(set) var level: Float = 0
    @Published public var errorMessage: String?

    private let drafts: InputDrafts
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    public init(drafts: InputDrafts) {
        self.drafts = drafts
    }

    public var isListening: Bool { target != nil }

    public func isListening(to target: InputDrafts.Target) -> Bool { self.target == target }

    /// Whether Apple Speech can be used at all; when it cannot, Plans falls back to the server recording.
    public var isSupported: Bool { recognizer?.isAvailable == true }

    /// Starts dictation into a field. Returns false when speech recognition is unavailable or not allowed.
    @discardableResult
    public func start(into target: InputDrafts.Target) async -> Bool {
        if self.target != nil { stop() }
        errorMessage = nil
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Распознавание речи сейчас недоступно."
            return false
        }
        // Amounts and merchants are private: they never go to Apple's servers either.
        if target == .money && !recognizer.supportsOnDeviceRecognition {
            errorMessage = "Голос в «Деньгах» распознаётся только на самом iPhone, а модели русской речи на нём пока нет. Сумму можно ввести с клавиатуры."
            return false
        }
        guard await Self.requestSpeechPermission() else {
            errorMessage = "Разреши распознавание речи в Настройках iPhone."
            return false
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Разреши доступ к микрофону в Настройках iPhone."
            return false
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition || target == .money {
            request.requiresOnDeviceRecognition = true
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                let level = Self.level(of: buffer)
                Task { @MainActor in self?.level = level }
            }
            engine.prepare()
            try engine.start()
        } catch {
            cleanUp()
            errorMessage = "Не удалось включить микрофон."
            return false
        }

        self.request = request
        self.target = target
        drafts.beginDictation(into: target)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in
                guard let self, self.target == target else { return }
                if let transcript {
                    self.drafts.applySpeech(transcript, to: target)
                }
                // The user may have typed into the field, which ends dictation there.
                if !self.drafts.isDictating(into: target) || isFinal || error != nil {
                    self.stop()
                }
            }
        }
        return true
    }

    /// Stops listening and keeps whatever was recognised in the field.
    public func stop() {
        if let target { drafts.endDictation(into: target) }
        task?.finish()
        cleanUp()
    }

    private func cleanUp() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task = nil
        target = nil
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func requestSpeechPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
    }

    nonisolated private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return min(1, rms * 12)
    }
}
