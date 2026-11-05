import AppKit
import ApplicationServices

@MainActor
struct InsertionTarget {
    let pid: pid_t
    let element: AXUIElement

    static func capture() -> InsertionTarget? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var role: CFTypeRef?; var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard (subrole as? String) != "AXSecureTextField",
              ["AXTextField", "AXTextArea", "AXComboBox"].contains(role as? String ?? "") else { return nil }
        // Explicit read-only fields must never receive a simulated paste.
        var editable: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable) == .success,
           let value = editable as? Bool, !value { return nil }
        return InsertionTarget(pid: app.processIdentifier, element: element)
    }

    func insert(_ text: String) -> Bool {
        guard let current = Self.capture(), current.pid == pid, CFEqual(current.element, element) else { return false }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue,
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
            return true
        }
        // Paste fallback only for the same editable field, preserving the clipboard.
        let board = NSPasteboard.general
        let previous = board.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        board.clearContents(); board.setString(text, forType: .string)
        let change = board.changeCount
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            // A user copy performed in the meantime wins.
            guard board.changeCount == change else { return }
            board.clearContents(); board.writeObjects(previous)
        }
        return true // Key event dispatched; apps do not acknowledge simulated paste.
    }
}
