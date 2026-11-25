import CoreAudio
import Foundation

/// The Mac's own output volume (the default output device's main volume, 0…1), for volume swipes and keys
/// that go on past the player's 100%. Public Core Audio only; devices without a settable volume do nothing.
enum SystemVolume {
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static var device: AudioDeviceID? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// 'vmvc': the volume the menu bar and the volume keys use (follows the device's own channels).
    private static let selector = AudioObjectPropertySelector(0x766D7663)

    static var level: Float? {
        guard let d = device else { return nil }
        var a = address(selector)
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(d, &a), AudioObjectGetPropertyData(d, &a, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    /// Moves the level by `delta` (clamped to 0…1) and returns the new level, or nil when it can't be set.
    @discardableResult
    static func change(by delta: Float) -> Float? {
        guard let d = device, let now = level else { return nil }
        var a = address(selector)
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(d, &a, &settable) == noErr, settable.boolValue else { return nil }
        var v = Float32(max(0, min(1, now + delta)))
        guard AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr else { return nil }
        return v
    }
}
