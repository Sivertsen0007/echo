import AVFoundation
import Cocoa
import CoreMedia

/// Records mono 16 kHz PCM to a temporary WAV file using AVCaptureSession.
///
/// Why AVCaptureSession and not AVAudioEngine: the engine's inputNode is
/// hard-bound to the system default input device on macOS. Setting
/// kAudioOutputUnitProperty_CurrentDevice on its audio unit reports success
/// but does not stick (observed on macOS 26: with a Bluetooth headset as the
/// default input, the node stayed on the headset and delivered pure silence
/// while the headset was playing music). AVCaptureSession takes the device as
/// an explicit input, so recording from the built-in mic while a headset is
/// the default actually works - which is what keeps the headset in A2DP
/// (music quality) during dictation instead of collapsing into call mode.
///
/// The output resamples to 16 kHz mono for us, so the on-disk WAV uploads
/// ~3x faster than native 48 kHz - the round-trip latency the user feels.
final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let targetSampleRate: Double = 16000
    private var session: AVCaptureSession?
    private var sessionDeviceUID: String?
    private var sessionDeviceName: String = "?"
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var startedAt: Date?
    private let captureQueue = DispatchQueue(label: "echo.audio.capture")
    private(set) var isRecording = false
    /// Loudest level (0...1) seen during the current recording. Lets the host
    /// skip uploading silence, which the API would only hallucinate on.
    private var peakLevel: Float = 0

    /// Called on the main queue with a normalised input level (0...1) per
    /// audio buffer, for driving a live waveform. Set by the host.
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

    /// Build the capture session ahead of time, off the hot path of the next
    /// key-down. The device only opens at startRunning(), so this neither
    /// shows the mic indicator nor touches a Bluetooth headset's profile.
    func prewarm() {
        guard !isRecording else { return }
        _ = preparedSession()
    }

    /// Returns false when recording could not start (no usable input device,
    /// file error, session failure) so the host can show an error instead of
    /// pretending to listen.
    @discardableResult
    func start() -> Bool {
        guard let session = preparedSession() else { return false }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-voice-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatInt16, interleaved: false)
        } catch {
            NSLog("Failed to open audio file: \(error)")
            return false
        }
        captureQueue.sync {
            self.audioFile = file
            self.peakLevel = 0
        }
        outputURL = url

        session.startRunning()
        guard session.isRunning else {
            NSLog("Capture session failed to start (input: \(sessionDeviceName))")
            captureQueue.sync { self.audioFile = nil }
            try? FileManager.default.removeItem(at: url)
            outputURL = nil
            return false
        }
        startedAt = Date()
        isRecording = true
        NSLog("Recording to \(url.lastPathComponent) at \(Int(targetSampleRate)) Hz (input: \(sessionDeviceName))")
        return true
    }

    /// Completion receives the file URL, the recorded duration, and the peak
    /// input level (0...1) so the caller can gate out silent recordings.
    func stop(_ completion: @escaping (URL?, TimeInterval, Float) -> Void) {
        session?.stopRunning()
        isRecording = false
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let url = outputURL
        var peak: Float = 0
        // Close the file on the capture queue so no late buffer writes after
        // it, and AVAudioFile flushes before we stat/upload it.
        captureQueue.sync {
            self.audioFile = nil
            peak = self.peakLevel
        }
        outputURL = nil
        startedAt = nil

        if let url = url,
           let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int {
            NSLog("Recorded \(String(format: "%.1f", Double(size) / 1024))KB over \(String(format: "%.1f", duration))s (peak \(String(format: "%.2f", peak)))")
        }

        completion(url, duration, peak)

        DispatchQueue.main.async { [weak self] in self?.prewarm() }
    }

    // MARK: - Session plumbing

    /// The session for the currently desired device, rebuilt when the desired
    /// device has changed since it was prepared.
    private func preparedSession() -> AVCaptureSession? {
        let uid = desiredInputUID()
        if let existing = session, sessionDeviceUID == uid { return existing }
        session = nil

        guard let device = captureDevice(forUID: uid) else {
            NSLog("No usable capture device found")
            return nil
        }
        let s = AVCaptureSession()
        s.beginConfiguration()
        guard let input = try? AVCaptureDeviceInput(device: device), s.canAddInput(input) else {
            NSLog("Could not create capture input for \(device.localizedName)")
            s.commitConfiguration()
            return nil
        }
        s.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard s.canAddOutput(output) else {
            NSLog("Could not add audio output to capture session")
            s.commitConfiguration()
            return nil
        }
        s.addOutput(output)
        s.commitConfiguration()

        session = s
        sessionDeviceUID = uid
        sessionDeviceName = device.localizedName
        NSLog("Capture session ready (input: \(device.localizedName))")
        return s
    }

    /// UID of the device Echo should record from: the pinned choice if it is
    /// present, else the system default input - EXCEPT that "follow default"
    /// never resolves to a Bluetooth mic. Opening a Bluetooth mic forces the
    /// headset from A2DP (music quality) into HFP (call quality), so music
    /// degrades the moment recording starts. macOS makes a connected headset
    /// the default input, so without this guard every dictation would trigger
    /// that switch. Users who truly want the headset mic can still pin it
    /// explicitly in Settings.
    private func desiredInputUID() -> String? {
        if let uid = ConfigStore.shared.inputDeviceUID,
           AudioDevices.device(forUID: uid) != nil {
            return uid
        }
        guard let def = AudioDevices.defaultInputDevice() else { return nil }
        if AudioDevices.isBluetooth(def),
           let builtIn = AudioDevices.builtInInputDevice(),
           let builtInUID = AudioDevices.uid(for: builtIn) {
            NSLog("Default input is Bluetooth (\(AudioDevices.name(for: def) ?? "?")) - using built-in mic so the headset stays in music mode")
            return builtInUID
        }
        return AudioDevices.uid(for: def)
    }

    /// AVCaptureDevice.uniqueID matches the CoreAudio device UID on macOS.
    private func captureDevice(forUID uid: String?) -> AVCaptureDevice? {
        if let uid = uid, let device = AVCaptureDevice(uniqueID: uid) { return device }
        return AVCaptureDevice.default(for: .audio)
    }

    // MARK: - Buffer handling (capture queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let file = audioFile else { return }
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let format = AVAudioFormat(streamDescription: asbd),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }

        emitLevel(from: pcm)
        do {
            try file.write(from: pcm)
        } catch {
            NSLog("Audio write error: \(error)")
        }
    }

    /// RMS of the buffer mapped to a 0...1 level (roughly -50 dB..0 dB) for
    /// the waveform. Cheap enough to run per buffer on the capture queue.
    private func emitLevel(from buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.int16ChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for i in 0..<count {
            let s = Float(channel[i]) / 32768.0
            sum += s * s
        }
        let rms = (sum / Float(count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        let level = max(0, min(1, (db + 50) / 50))
        if level > peakLevel { peakLevel = level }
        if let onLevel = onLevel {
            DispatchQueue.main.async { onLevel(level) }
        }
    }
}
