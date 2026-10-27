import AppKit
import CoreAudio
import AudioToolbox
import CoreWLAN
import MewponCore

struct ApplicationControlTool: AssistantTool {
    let spec = ToolSpec("application_control", "Switch to, hide, or request a normal quit of one running app. Does not force quit. action: switch, hide, quit.", fields: ["application": "Exact running app name", "action": "switch, hide, quit"], capability: .systemControl)
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        let name = arguments["application"]!.string!, action = arguments["action"]!.string!
        guard ["switch", "hide", "quit"].contains(action) else { return ToolResult(false, "Unsupported app action.") }
        return await MainActor.run {
            let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier && ($0.localizedName?.caseInsensitiveCompare(name) == .orderedSame || $0.bundleIdentifier == OpenApplicationTool.bundleIdentifier(for: name)) }
            guard apps.count == 1, let app = apps.first else { return ToolResult(false, "Choose one exact running application. No app was changed.") }
            if action == "switch", app.isActive { return ToolResult(true, "Already active: \(app.localizedName ?? name).") }
            let accepted: Bool
            switch action {
            case "hide": accepted = app.hide()
            case "quit": accepted = app.terminate()
            default: accepted = app.activate(options: [])
            }
            return ToolResult(accepted, accepted ? (action == "quit" ? "Requested a normal quit. The app may ask you to save work or refuse to quit." : "Application action accepted by macOS.") : "Application declined the action.")
        }
    }
}

enum OutputVolume {
    static func device() -> AudioDeviceID? {
        var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }
    static func channels(_ id: AudioDeviceID) -> [UInt32] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(id, &address) { return [kAudioObjectPropertyElementMain] }
        return [UInt32(1), UInt32(2)].filter { channel in
            address.mElement = channel
            return AudioObjectHasProperty(id, &address)
        }
    }
    static func read() -> Float32? {
        guard let id = device() else { return nil }
        let values: [Float32] = channels(id).compactMap { channel in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: channel)
            var value: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Float32(values.count)
    }
    static func set(_ value: Float32) -> Bool {
        guard let id = device() else { return false }
        let channels = channels(id)
        guard !channels.isEmpty else { return false }
        for channel in channels {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: channel)
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { return false }
        }
        var succeeded = true
        for channel in channels {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: channel)
            var value = value
            succeeded = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr && succeeded
        }
        return succeeded
    }

}

struct VolumeTool: AssistantTool {
    let spec = ToolSpec("output_volume", "Read or set default output volume. level: read, up/down by ten percentage points, or an integer 0...100. Some output devices do not support software volume.", fields: ["level": "read, up, down, or 0...100"], capability: .systemControl)
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        let level = arguments["level"]!.string!
        return await Task.detached {
            if level == "read" {
                guard let value = OutputVolume.read() else { return ToolResult(false, "This output device does not expose public software volume. Open Sound settings.") }
                return ToolResult(true, "Output volume: \(Int((value * 100).rounded()))%")
            }
            let target: Int?
            if ["up", "down"].contains(level) {
                guard let current = OutputVolume.read() else { return ToolResult(false, "Current volume is unavailable; nothing changed.") }
                target = min(100, max(0, Int((current * 100).rounded()) + (level == "up" ? 10 : -10)))
            } else { target = Int(level) }
            guard let value = target, (0...100).contains(value) else { return ToolResult(false, "Choose a volume from 0 to 100.") }
            guard OutputVolume.set(Float32(value) / 100) else { return ToolResult(false, "Volume could not be fully applied. Check Sound settings or hardware controls; a channel already accepted by the device may have changed.") }
            guard let actual = OutputVolume.read() else { return ToolResult(false, "Volume change accepted; current value could not be verified.") }
            return ToolResult(true, "Output volume now \(Int((actual * 100).rounded()))%")
        }.value
    }
}

struct WiFiStatusTool: AssistantTool {
    let spec = ToolSpec("wifi_status", "Read Wi-Fi power and association status using CoreWLAN. Does not scan networks or request Location access.")
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        await Task.detached {
            guard let interface = CWWiFiClient.shared().interface() else { return ToolResult(false, "No Wi-Fi interface available.") }
            return ToolResult(true, "Wi-Fi: " + (interface.powerOn() ? "on" : "off") + "; link: " + (interface.serviceActive() ? "active" : "inactive") + ". Network identity is not collected.")
        }.value
    }
}

struct SystemSettingsTool: AssistantTool {
    static let panes = ["sound": "com.apple.Sound-Settings.extension", "display": "com.apple.Displays-Settings.extension", "focus": "com.apple.Focus-Settings.extension", "wifi": "com.apple.wifi-settings-extension", "keyboard": "com.apple.Keyboard-Settings.extension", "privacy": "com.apple.settings.PrivacySecurity.extension", "lock": "com.apple.Lock-Screen-Settings.extension", "bluetooth": "com.apple.BluetoothSettings", "battery": "com.apple.Battery-Settings.extension", "network": "com.apple.Network-Settings.extension", "wallpaper": "com.apple.Wallpaper-Settings.extension", "appearance": "com.apple.Appearance-Settings.extension"]
    let spec = ToolSpec("system_settings", "Open System Settings for sound, display, focus, wifi, keyboard, privacy, lock, bluetooth, battery, network, wallpaper, or appearance. Does not change the setting.", fields: ["pane": "sound, display, focus, wifi, keyboard, privacy, lock, bluetooth, battery, network, wallpaper, appearance"], capability: .systemControl)
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let pane = Self.panes[arguments["pane"]!.string!] else { return ToolResult(false, "Unsupported settings pane.") }
        return await MainActor.run {
            let success = NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:" + pane)!)
            return ToolResult(success, success ? "Requested System Settings. No setting was changed." : "Could not open System Settings.")
        }
    }
}
