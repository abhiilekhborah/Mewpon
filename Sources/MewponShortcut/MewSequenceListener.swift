import AppKit
import SwiftUI
import Carbon
import CoreGraphics

/// Stores only a three-state prefix and time, never a key history or typed text.
public struct MewSequenceRecognizer {
    public init() {}
    public private(set) var prefix = 0
    private var lastTime: Double = 0
    private var commandHeld = false
    public mutating func reset() { prefix = 0; lastTime = 0; commandHeld = false }
    public mutating func letter(_ value: String?, modified: Bool, repeated: Bool, time: Double) {
        if time - lastTime > 1.5 { reset() }
        guard !modified, !repeated else { reset(); return }
        switch (prefix, value) {
        case (0, "m"), (1, "m"), (2, "m"), (3, "m"): prefix = 1
        case (1, "e"): prefix = 2
        case (2, "w"): prefix = 3
        default: reset()
        }
        lastTime = time
    }
    public mutating func command(down: Bool, otherModifiers: Bool, time: Double) -> Bool {
        defer { commandHeld = down }
        guard down, !commandHeld else { return false }
        let matched = prefix == 3 && time - lastTime <= 1.5 && !otherModifiers
        reset(); return matched
    }
}

@MainActor public final class MewSequenceListener: ObservableObject {
    private let displayName: String
    public init(displayName: String = "Mewpon") { self.displayName = displayName }
    @Published public private(set) var status = "Not checked" { didSet { statusChanged?(status) } }
    public var statusChanged: ((String) -> Void)?
    public var toggle: (() -> Void)?
    public var isListening: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    private var recognizer = MewSequenceRecognizer()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var generation = 0
    public func reset() { recognizer.reset() }
    public func refresh(enabled: Bool = true) {
        stop()
        guard enabled else { status = "Disabled"; return }
        guard CGPreflightListenEventAccess() else { status = "Enable Input Monitoring for \(displayName), then Refresh"; return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            // This source is installed exclusively on the main run loop.
            MainActor.assumeIsolated {
                Unmanaged<MewSequenceListener>.fromOpaque(pointer).takeUnretainedValue().receive(type, event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { status = "Keyboard listener unavailable. Check Input Monitoring and reopen Mewpon."; return }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
        status = "Ready · type mew, then press either Command key"
    }
    public func requestAccess() { _ = CGRequestListenEventAccess(); refresh() }
    public func openPermissionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    public func receive(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            recognizer.reset(); if let tap { CGEvent.tapEnable(tap: tap, enable: true) }; return
        }
        guard !IsSecureEventInputEnabled() else { recognizer.reset(); return }
        let flags = event.flags
        let forbidden = !flags.intersection([.maskControl, .maskAlternate, .maskSecondaryFn]).isEmpty
        let now = ProcessInfo.processInfo.systemUptime
        if type == .flagsChanged {
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            if key == 54 || key == 55 {
                if recognizer.command(down: flags.contains(.maskCommand), otherModifiers: forbidden || flags.contains(.maskShift), time: now) {
                    // Return from the event tap before activating apps or animating windows.
                    // Refresh/shutdown invalidates work queued by an old listener.
                    let current = generation
                    DispatchQueue.main.async { [weak self] in
                        guard let self, generation == current else { return }
                        toggle?()
                    }
                }
            } else if forbidden { recognizer.reset() }
        } else if type == .keyDown {
            let letter = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased()
            recognizer.letter(letter, modified: forbidden || flags.contains(.maskCommand), repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, time: now)
        }
    }
    private func stop() {
        generation &+= 1
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil; recognizer.reset()
    }
    public func shutdown() { stop() }
}

