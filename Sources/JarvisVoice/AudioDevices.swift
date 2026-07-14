import CoreAudio
import Foundation

/// One selectable audio input device.
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String   // stable across reconnects; what we persist
    let name: String
    /// Opening a Bluetooth mic forces the headset from A2DP (music quality)
    /// into HFP (call quality) - the picker warns about these.
    let isBluetooth: Bool
}

/// Thin CoreAudio wrapper to enumerate input devices and resolve the current
/// system default, so Echo can record from a chosen mic (or follow default).
enum AudioDevices {
    /// All devices that expose at least one input channel.
    static func inputDevices() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasInput(id),
                  let name = stringProperty(id, kAudioObjectPropertyName),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name, isBluetooth: isBluetooth(id))
        }
    }

    /// Resolve a persisted UID to a live device id (nil if unplugged).
    static func device(forUID uid: String) -> AudioDeviceID? {
        inputDevices().first { $0.uid == uid }?.id
    }

    /// The device name for a UID, for display/logging.
    static func name(forUID uid: String) -> String? {
        inputDevices().first { $0.uid == uid }?.name
    }

    /// The current system default input device.
    static func defaultInputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    static func name(for id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioObjectPropertyName)
    }

    /// The persistable CoreAudio UID for a device id. Also matches
    /// AVCaptureDevice.uniqueID for the same device on macOS.
    static func uid(for id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    /// True for Bluetooth (classic or LE) devices. Recording from one forces
    /// the headset out of A2DP into HFP, degrading its output to call quality.
    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        guard let transport = transportType(id) else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The Mac's built-in microphone, if this machine has one.
    static func builtInInputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { hasInput($0) && transportType($0) == kAudioDeviceTransportTypeBuiltIn }
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    // MARK: - Helpers

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        let s = value as String
        return s.isEmpty ? nil : s
    }
}
