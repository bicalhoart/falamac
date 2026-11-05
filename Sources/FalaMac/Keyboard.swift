import AppKit
import Carbon

@MainActor
final class Keyboard {
    var toggle: (() -> Void)?
    var fnChanged: ((Bool) -> Void)?
    var cancel: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var global: Any?
    private var local: Any?
    private var fnDown = false
    private var escapeHotKey: EventHotKeyRef?
    private var escapeGlobal: Any?
    private var escapeLocal: Any?

    func start() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let keyboard = Unmanaged<Keyboard>.fromOpaque(context).takeUnretainedValue()
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr else { return OSStatus(eventNotHandledErr) }
            let identifier = id.id
            Task { @MainActor in
                if identifier == 1 { keyboard.toggle?() }
                else if identifier == 2 { keyboard.cancel?() }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: 0x46414c41, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id,
                                        GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { registrationFailed = true }
    }
    private(set) var registrationFailed = false

    func enableFn(_ enabled: Bool) {
        if let global { NSEvent.removeMonitor(global) }; global = nil
        if let local { NSEvent.removeMonitor(local) }; local = nil
        fnDown = false
        guard enabled else { return }
        global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.flags(event) }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.flags(event) }
            return event
        }
    }

    private func flags(_ event: NSEvent) {
        guard event.keyCode == 63 else { return }
        let down = event.modifierFlags.contains(.function)
        guard down != fnDown else { return }
        fnDown = down; fnChanged?(down)
    }

    func setCancellationActive(_ active: Bool) {
        if let escapeHotKey { UnregisterEventHotKey(escapeHotKey) }; escapeHotKey = nil
        if let escapeGlobal { NSEvent.removeMonitor(escapeGlobal) }; escapeGlobal = nil
        if let escapeLocal { NSEvent.removeMonitor(escapeLocal) }; escapeLocal = nil
        guard active else { return }
        let id = EventHotKeyID(signature: 0x46414c41, id: 2)
        RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &escapeHotKey)
        // Also recognize Escape while Fn is held, and when the Carbon key is unavailable.
        escapeGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { MainActor.assumeIsolated { self?.cancel?() } }
        }
        escapeLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.cancel?() }; return nil
        }
    }

    func stop() {
        setCancellationActive(false)
        enableFn(false)
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}
