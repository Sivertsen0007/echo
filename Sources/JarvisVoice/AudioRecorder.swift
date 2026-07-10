import AVFoundation
import Cocoa

/// Records 16kHz mono PCM to a temporary WAV file using AVAudioEngine.
/// Writes via AVAudioFile (Core Audio handles WAV/CAF headers).
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var startedAt: Date?
    private let targetSampleRate: Double = 16000

    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default: completion(false)
        }
    }

    func start() {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // We'll write at the input's native sample rate to keep things simple,
        // then let the API resample. Whisper accepts wide range of rates.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-voice-\(UUID().uuidString).wav")
        outputURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            audioFile = try AVAudioFile(forWriting: url, settings: settings,
                                        commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            NSLog("Failed to open audio file: \(error)")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            do {
                try self?.audioFile?.write(from: buffer)
            } catch {
                NSLog("Audio write error: \(error)")
            }
        }

        do {
            engine.prepare()
            try engine.start()
            startedAt = Date()
            NSLog("Recording to \(url.lastPathComponent)")
        } catch {
            NSLog("Engine start failed: \(error)")
        }
    }

    func stop(_ completion: @escaping (URL?, TimeInterval) -> Void) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let url = outputURL
        audioFile = nil
        outputURL = nil
        startedAt = nil
        completion(url, duration)
    }
}
