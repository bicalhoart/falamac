import AppKit
import Carbon

@MainActor
final class Keyboard {
    var toggle: (() -> Void)?
    var fnChanged: ((Bool) -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var global: Any?
    private var local: Any?
    private var fnDown = false

    func start() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let keyboard = Unmanaged<Keyboard>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in keyboard.toggle?() }
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

    func stop() {
        enableFn(false)
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}
