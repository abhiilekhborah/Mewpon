import AppKit
import CoreAudio
import CoreBluetooth
import IOBluetooth
import IOKit.pwr_mgt
import MewponCore

struct AudioControlTool: AssistantTool {
    let spec = ToolSpec("audio_control", "List output devices, mute/unmute, or switch to one exact output device. Never select an ambiguous device.", fields: ["action": "list, mute, unmute, switch", "device": "Exact device name or default"], capability: .systemControl)
    static func devices() -> [(AudioDeviceID, String)] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var count: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &count) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(count)/MemoryLayout<AudioDeviceID>.size)
        guard ids.withUnsafeMutableBytes({ AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &count, $0.baseAddress!) }) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &size) == noErr, size > 0 else { return nil }
            var name: Unmanaged<CFString>?; size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var key = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &key, 0, nil, &size, &name) == noErr, let name else { return nil }
            return (id, name.takeRetainedValue() as String)
        }
    }
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        let action = arguments["action"]!.string!, name = arguments["device"]!.string!
        return await Task.detached {
            let devices = Self.devices()
            if action == "list" { return ToolResult(true, devices.map { ($0.0 == OutputVolume.device() ? "Active: " : "") + $0.1 }.joined(separator: "\n")) }
            if action == "switch" {
                let choices = devices.filter { $0.1.caseInsensitiveCompare(name) == .orderedSame }
                guard choices.count == 1, let choice = choices.first else { return ToolResult(false, "Choose one exact output device: " + devices.map(\.1).joined(separator: ", ")) }
                var id = choice.0
                var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                let ok = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr && OutputVolume.device() == id
                return ToolResult(ok, ok ? "Output: " + choice.1 : "The output device did not accept the switch.")
            }
            guard ["mute", "unmute"].contains(action), let id = OutputVolume.device() else { return ToolResult(false, "Unsupported audio action.") }
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(id, &a, &settable) == noErr, settable.boolValue else { return ToolResult(false, "This device does not expose public mute control. Open Sound settings.") }
            var value: UInt32 = action == "mute" ? 1 : 0
            let ok = AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
            var actual: UInt32 = 99, size = UInt32(MemoryLayout<UInt32>.size)
            let verified = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &actual) == noErr && actual == value
            return ToolResult(ok && verified, ok && verified ? (action == "mute" ? "Muted." : "Unmuted.") : "Mute state could not be verified.")
        }.value
    }
}
struct DisplayControlTool: AssistantTool {
    let spec = ToolSpec("display_control", "List actual connected display resolutions. Brightness is unavailable through this release's supported public interfaces; report that accurately.", fields: ["action": "status or brightness", "value": "read or percentage"])
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard arguments["action"]?.string == "status" else { return ToolResult(false, "Brightness was not changed: this display has no implemented public brightness interface. Ask ‘open display settings’, or configure a trusted macOS Shortcut for brightness.") }
        return await MainActor.run {
            ToolResult(true, NSScreen.screens.map { "\($0.localizedName): \(Int($0.frame.width * $0.backingScaleFactor)) × \(Int($0.frame.height * $0.backingScaleFactor)) pixels; \(Int($0.frame.width)) × \(Int($0.frame.height)) points" }.joined(separator: "\n"))
        }
    }
}
struct BluetoothStatusTool: AssistantTool {
    let spec = ToolSpec("bluetooth_status", "Read the public Bluetooth controller power state. Does not pair, scan, or change protections.")
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard CBManager.authorization == .allowedAlways else { return ToolResult(false, "Bluetooth status needs separate macOS Bluetooth access. No scan or permission request was started. Ask to open Bluetooth settings for the current status.") }
        guard let controller = IOBluetoothHostController.default() else { return ToolResult(false, "Bluetooth controller status unavailable. Ask to open Bluetooth settings.") }
        return ToolResult(true, "Bluetooth power: " + (controller.powerState == kBluetoothHCIPowerStateON ? "on" : "off") + ". Pairing and power changes use Bluetooth settings.")
    }
}
struct SystemAppearanceTool: AssistantTool {
    let spec = ToolSpec("system_appearance", "Change macOS light/dark appearance using System Events' supported appearance preferences. macOS may request Automation access.", fields: ["mode": "light or dark"], capability: .appearance)
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let mode = arguments["mode"]?.string, ["light", "dark"].contains(mode) else { return ToolResult(false, "Choose light or dark.") }
        return await MainActor.run {
            let value = mode == "dark" ? "true" : "false"
            let source = "tell application \"System Events\" to tell appearance preferences\nset dark mode to \(value)\nreturn dark mode\nend tell"
            var error: NSDictionary?
            guard let script = NSAppleScript(source: "with timeout of 5 seconds\n" + source + "\nend timeout") else { return ToolResult(false, "Appearance automation unavailable.") }
            let reply = script.executeAndReturnError(&error)
            guard error == nil else { return ToolResult(false, "macOS appearance was not verified. Allow Mewpon → System Events in Privacy & Security → Automation, or use Appearance settings.") }
            let ok = reply.booleanValue == (mode == "dark")
            return ToolResult(ok, ok ? "macOS appearance: \(mode)." : "macOS appearance did not match the request.")
        }
    }
}
struct PowerControlTool: AssistantTool {
    let spec = ToolSpec("power_control", "Request sleep only when explicitly asked. Lock has no implemented public direct interface and returns a keyboard alternative.", fields: ["action": "sleep or lock"], capability: .systemControl)
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        if arguments["action"]?.string == "lock" { return ToolResult(false, "Press Control–Command–Q to lock immediately. No private lock API or synthetic credential interaction is used.") }
        guard arguments["action"]?.string == "sleep" else { return ToolResult(false, "Unsupported power action.") }
        let connection = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard connection != 0 else { return ToolResult(false, "Sleep request unavailable.") }
        defer { IOServiceClose(connection) }
        let accepted = IOPMSleepSystem(connection) == kIOReturnSuccess
        return ToolResult(accepted, accepted ? "macOS accepted the sleep request." : "macOS declined sleep. Use the Apple menu → Sleep.")
    }
}

struct MediaControlTool: AssistantTool {
    let spec = ToolSpec("media_control", "Use supported Music or Spotify automation for play, pause, next, previous. Never controls an unknown target.", fields: ["application": "Music or Spotify", "action": "play, pause, next, previous"], capability: .systemControl)
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        let targets = ["music": "com.apple.Music", "spotify": "com.spotify.client"]
        let verbs = ["play": "play", "pause": "pause", "next": "next track", "previous": "previous track"]
        guard let id = targets[arguments["application"]!.string!.lowercased()], let action = verbs[arguments["action"]!.string!] else { return ToolResult(false, "Choose Music or Spotify and a supported playback action.") }
        return await MainActor.run {
            guard NSRunningApplication.runningApplications(withBundleIdentifier: id).count == 1 else { return ToolResult(false, "Open the requested media application first.") }
            var error: NSDictionary?
            _ = NSAppleScript(source: "with timeout of 5 seconds\n" + "tell application id \"\(id)\" to \(action)" + "\nend timeout")?.executeAndReturnError(&error)
            return ToolResult(error == nil, error == nil ? "\(action.capitalized) request accepted by the media app." : "Media automation was declined. Check Privacy & Security → Automation.")
        }
    }
}
