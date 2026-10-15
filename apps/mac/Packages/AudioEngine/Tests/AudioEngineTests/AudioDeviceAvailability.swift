import CoreAudio

/// Only a successful HAL query reporting no device disables hardware tests.
/// Query failures leave them enabled so unexpected audio failures are reported.
func hasAudioOutputDevice() -> Bool {
    var device = AudioDeviceID(kAudioObjectUnknown)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return status != noErr || device != kAudioObjectUnknown
}
