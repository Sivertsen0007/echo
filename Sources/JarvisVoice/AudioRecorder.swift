import AVFoundation
import AudioToolbox
import Cocoa

/// Records mono 16 kHz PCM to a temporary WAV file using AVAudioEngine.
/// Audio is captured at the input device's native rate and downsampled to
/// 16 kHz mono via AVAudioConverter before writing. Whisper-family models run
/// fine at 16 kHz, and the smaller file uploads roughly 3x faster than native
/// 48 kHz - which is the round-trip latency the user feels on every dictation.
///
/// A fresh AVAudioEngine is built for each recording so device changes are
/// honoured: without this the engine stays pinned to whatever input device was
/// default when the app launched (e.g. AirPods), ignoring later switches.
final class AudioRecorder {
    private var engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var startedAt: Date?
    private let targetSampleRate: Double = 16000
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    /// Called on the main queue with a normalised input level (0...1) per audio
    /// buffer, for driving a live waveform. Set by the host.
    var onLevel: ((Float) -> Void)?

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
        // Fresh engine each time so it picks up the current input device.
        engine = AVAudioEngine()
        let inputNode = engine.inputNode
        selectInputDevice(on: inputNode)
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Target: 16 kHz mono float32 processing format. The converter handles
        // both the sample-rate drop and any channel down-mix from the input.
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: targetSampleRate,
                                         channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            NSLog("Failed to build 16 kHz converter from input format \(inputFormat)")
            return
        }
        targetFormat = target
        self.converter = converter

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-voice-\(UUID().uuidString).wav")
        outputURL = url

        // On-disk WAV is 16 kHz mono 16-bit PCM. Processing buffers we hand to
        // write(from:) are float32 (commonFormat below); AVAudioFile converts.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
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
            self?.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            startedAt = Date()
            NSLog("Recording to \(url.lastPathComponent) at \(Int(targetSampleRate)) Hz (input \(Int(inputFormat.sampleRate)) Hz)")
        } catch {
            NSLog("Engine start failed: \(error)")
        }
    }

    /// Point the engine's input node at the user's chosen mic, or the current
    /// system default when none is chosen / the chosen one is unplugged. Must
    /// run before we read the input format or install the tap.
    private func selectInputDevice(on node: AVAudioInputNode) {
        let deviceID: AudioDeviceID?
        if let uid = ConfigStore.shared.inputDeviceUID {
            deviceID = AudioDevices.device(forUID: uid) ?? AudioDevices.defaultInputDevice()
        } else {
            deviceID = AudioDevices.defaultInputDevice()
        }
        guard let dev = deviceID, let unit = node.audioUnit else { return }
        var id = dev
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            NSLog("Could not set input device (\(status)); using engine default")
        } else {
            NSLog("Recording from input device: \(AudioDevices.name(for: dev) ?? "id \(dev)")")
        }
    }

    /// Downsample one native tap buffer to 16 kHz mono and append to the file.
    /// The converter keeps internal resampler state across calls, so feeding it
    /// buffer-by-buffer produces a continuous 16 kHz stream.
    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter,
              let targetFormat = targetFormat,
              let audioFile = audioFile else { return }

        emitLevel(from: buffer)

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, inStatus in
            if consumed {
                inStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            NSLog("Audio convert error: \(error)")
            return
        }
        guard status != .error, outBuffer.frameLength > 0 else { return }

        do {
            try audioFile.write(from: outBuffer)
        } catch {
            NSLog("Audio write error: \(error)")
        }
    }

    /// RMS of the buffer mapped to a 0...1 level (roughly -50 dB..0 dB) for the
    /// waveform. Cheap enough to run per buffer on the audio thread.
    private func emitLevel(from buffer: AVAudioPCMBuffer) {
        guard let onLevel = onLevel,
              let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for i in 0..<count { let s = channel[i]; sum += s * s }
        let rms = (sum / Float(count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        let level = max(0, min(1, (db + 50) / 50))
        DispatchQueue.main.async { onLevel(level) }
    }

    func stop(_ completion: @escaping (URL?, TimeInterval) -> Void) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let url = outputURL

        // Nil the file first so AVAudioFile flushes and closes before we stat it.
        audioFile = nil
        converter = nil
        targetFormat = nil
        outputURL = nil
        startedAt = nil

        if let url = url,
           let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int {
            NSLog("Recorded \(String(format: "%.1f", Double(size) / 1024))KB over \(String(format: "%.1f", duration))s")
        }

        completion(url, duration)
    }
}
