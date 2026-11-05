import Foundation
import AVFoundation
import UIKit

@MainActor
public final class VoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    public enum State: Equatable {
        case idle
        case starting
        case recording
        case paused
        case stopping
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var elapsedTime: TimeInterval = 0
    @Published public private(set) var normalizedLevel: Float = 0
    @Published public private(set) var errorMessage: String? = nil

    public static let maxRecordingDuration: TimeInterval = 60.0 // 1 minute cap as per web UI

    private var audioRecorder: AVAudioRecorder?
    private var tempFileURL: URL?
    private var timer: Timer?

    public override init() {
        super.init()
    }

    public var isRecordingOrPaused: Bool {
        state == .recording || state == .paused
    }

    public func start() async {
        guard state == .idle else { return }
        errorMessage = nil
        state = .starting

        let hasPermission = await checkOrRequestPermission()
        guard hasPermission else {
            state = .idle
            errorMessage = "Нет доступа к микрофону. Разреши доступ в Настройках iPhone, чтобы диктовать планы."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            let tempDir = FileManager.default.temporaryDirectory
            let fileName = "arna_dictation_\(UUID().uuidString).m4a"
            let url = tempDir.appendingPathComponent(fileName)
            self.tempFileURL = url

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 22050.0,
                AVNumberOfChannelsKey: 1,
                // Speech stays clear at this rate, and ten minutes fit the server's 4 MB limit.
                AVEncoderBitRateKey: 32000
            ]

            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                state = .idle
                errorMessage = "Не удалось начать запись аудио."
                return
            }

            self.audioRecorder = recorder
            self.elapsedTime = 0
            self.normalizedLevel = 0
            self.state = .recording
            startMeteringTimer()
        } catch {
            cleanupTempFile()
            state = .idle
            errorMessage = "Ошибка аудиосессии: \(error.localizedDescription)"
        }
    }

    public func pause() {
        guard state == .recording, let recorder = audioRecorder else { return }
        recorder.pause()
        state = .paused
        normalizedLevel = 0
    }

    public func resume() {
        guard state == .paused, let recorder = audioRecorder else { return }
        recorder.record()
        state = .recording
    }

    public func cancel() {
        stopMeteringTimer()
        audioRecorder?.stop()
        audioRecorder = nil
        cleanupTempFile()
        state = .idle
        elapsedTime = 0
        normalizedLevel = 0
    }

    public func finish() -> (data: Data, mimeType: String)? {
        guard isRecordingOrPaused, let recorder = audioRecorder, let fileURL = tempFileURL else {
            cancel()
            return nil
        }

        state = .stopping
        stopMeteringTimer()
        recorder.stop()
        self.audioRecorder = nil

        defer {
            cleanupTempFile()
            state = .idle
            elapsedTime = 0
            normalizedLevel = 0
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return (data: data, mimeType: "audio/mp4")
        } catch {
            errorMessage = "Не удалось прочитать файл записи."
            return nil
        }
    }

    private func checkOrRequestPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return true
            case .denied:
                return false
            case .undetermined:
                return await AVAudioApplication.requestRecordPermission()
            @unknown default:
                return false
            }
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func startMeteringTimer() {
        stopMeteringTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.updateMetering()
            }
        }
    }

    private func stopMeteringTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateMetering() {
        guard state == .recording, let recorder = audioRecorder else { return }
        recorder.updateMeters()
        elapsedTime = recorder.currentTime

        if elapsedTime >= Self.maxRecordingDuration {
            _ = finish()
            return
        }

        let power = recorder.averagePower(forChannel: 0)
        // dB range -60...0 -> normalized 0.0...1.0
        let clamped = max(-60.0, min(0.0, power))
        let normalized = (clamped + 60.0) / 60.0
        self.normalizedLevel = normalized
    }

    private func cleanupTempFile() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
    }

    public func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            errorMessage = "Запись завершилась с ошибкой."
            cancel()
        }
    }
}
