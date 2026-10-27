import Carbon

enum ShortcutEvent {
    static let signature: OSType = 0x4D455750
    static func action(_ event: EventRef) -> UInt32? {
        guard GetEventClass(event) == OSType(kEventClassKeyboard), GetEventKind(event) == UInt32(kEventHotKeyPressed) else { return nil }
        var identifier = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
              identifier.signature == signature, (1...5).contains(identifier.id) else { return nil }
        return identifier.id
    }
}
