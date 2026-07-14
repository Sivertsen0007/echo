import AVFoundation
import AudioToolbox
import Cocoa

/// Records mono 16 kHz PCM to a temporary WAV file using AVAudioEngine.
/// Audio is captured at the input device's native rate and downsampled to
/// 16 kHz mono via AVAudioConverter before writing. Whisper-family models run
/// fine at 16 kHz, and the smaller file uploads roughly 3x faster than native
/// 48 kHz - which is the round-trip latency the user feels on every dictation.
///
/// An engine is prewarmed ahead of each recording (at launch, after every
/// stop, on wake, and on audio-configuration changes) so start() only has to
/// call engine.start(). Building the engine lazily on key-down cost
/// ~100-200ms and clipped the first word of short dictations. start() still
/// verifies the prewarmed engine points at the currently desired input device
/// and rebuilds when it doesn't, so device switches are honoured.
final class AudioRecorder {
    private var engine = AVAudioEngine()
    private var prepared: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var startedAt: Date?
    private let targetSampleRate: Double = 16000
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private(set) var isRecording = false
    /// Loudest level (0...1) seen during the current recording. Lets the host
    /// skip uploading silence, which the API would only hallucinate on.
    private var peakLevel: Float = 0

    /// Called on the main queue with a normalised input level (0...1) per audio
    /// buffer, for driving a live waveform. Set by the host.
    var onLevel: ((Float) -> Void)?

    // Note: no AVAudioEngineConfigurationChange observer here on purpose -
    // configuring a prewarmed engine fires that notification itself, so
    // rebuilding on it loops forever. Device changes are handled instead by
    // the device-match check in start() (and the wake-time prewarm).

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

    /// Build and prepare the next engine ahead of time, off the hot path.
    func prewarm() {
        guard !isRecording else { return }
        let e = AVAudioEngine()
        selectInputDevice(on: e.inputNode)
        _ = e.inputNode.outputFormat(forBus: 0) // force the IO unit to configure
        e.prepare()
        prepared = e
    }

    /// Returns false when recording could not start (no usable input device,
    /// file error, engine failure) so the host can show an error instead of
    /// pretending to listen.
    @discardableResult
    func start() -> Bool {
        // Use the prewarmed engine when its input still matches the desired
        // device; otherwise build fresh (the device changed since prewarm).
        let desired = desiredInputDevice()
        if let pre = prepared, currentDevice(of: pre.inputNode) == desired {
            engine = pre
        } else {
            engine = AVAudioEngine()
            selectInputDevice(on: engine.inputNode)
        }
        prepared = nil

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Target: 16 kHz mono float32 processing format. The converter handles
        // both the sample-rate drop and any channel down-mix from the input.
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: targetSampleRate,
                                         channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            NSLog("Failed to build 16 kHz converter from input format \(inputFormat)")
            return false
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
            cleanupAfterFailedStart()
            return false
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            startedAt = Date()
            peakLevel = 0
            isRecording = true
            NSLog("Recording to \(url.lastPathComponent) at \(Int(targetSampleRate)) Hz (input \(Int(inputFormat.sampleRate)) Hz)")
            return true
        } catch {
            NSLog("Engine start failed: \(error)")
            inputNode.removeTap(onBus: 0)
            cleanupAfterFailedStart()
            return false
        }
    }

    private func cleanupAfterFailedStart() {
        audioFile = nil
        converter = nil
        targetFormat = nil
        if let url = outputURL { try? FileManager.default.removeItem(at: url) }
        outputURL = nil
    }

    /// The device the user wants right now: their pinned choice if it is
    /// present, else the system default input.
    private func desiredInputDevice() -> AudioDeviceID? {
        if let uid = ConfigStore.shared.inputDeviceUID {
            return AudioDevices.device(forUID: uid) ?? AudioDevices.defaultInputDevice()
        }
        return AudioDevices.defaultInputDevice()
    }

    /// The device an engine's input node is currently bound to.
    private func currentDevice(of node: AVAudioInputNode) -> AudioDeviceID? {
        guard let unit = node.audioUnit else { return nil }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &id, &size)
        return status == noErr ? id : nil
    }

    /// Point the engine's input node at the user's chosen mic, or the current
    /// system default when none is chosen / the chosen one is unplugged. Must
    /// run before we read the input format or install the tap.
    private func selectInputDevice(on node: AVAudioInputNode) {
        guard let dev = desiredInputDevice(), let unit = node.audioUnit else { return }
        var id = dev
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            NSLog("Could not set input device (\(status)); using engine default")
        } else {
            NSLog("Input device: \(AudioDevices.name(for: dev) ?? "id \(dev)")")
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
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for i in 0..<count { let s = channel[i]; sum += s * s }
        let rms = (sum / Float(count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        let level = max(0, min(1, (db + 50) / 50))
        if level > peakLevel { peakLevel = level }
        if let onLevel = onLevel {
            DispatchQueue.main.async { onLevel(level) }
        }
    }

    /// Completion receives the file URL, the recorded duration, and the peak
    /// input level (0...1) so the caller can gate out silent recordings.
    func stop(_ completion: @escaping (URL?, TimeInterval, Float) -> Void) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let url = outputURL
        let peak = peakLevel

        // Nil the file first so AVAudioFile flushes and closes before we stat it.
        audioFile = nil
        converter = nil
        targetFormat = nil
        outputURL = nil
        startedAt = nil

        if let url = url,
           let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int {
            NSLog("Recorded \(String(format: "%.1f", Double(size) / 1024))KB over \(String(format: "%.1f", duration))s (peak \(String(format: "%.2f", peak)))")
        }

        completion(url, duration, peak)

        // Prepare the next engine now, off the hot path of the next key-down.
        DispatchQueue.main.async { [weak self] in self?.prewarm() }
    }
}
