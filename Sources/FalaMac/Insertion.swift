import AppKit
import ApplicationServices
import FalaCore

@MainActor
struct InsertionTarget {
    let pid: pid_t
    let element: AXUIElement
    let window: AXUIElement?
    let identity: FieldIdentity?

    enum CaptureFailure: String {
        case permission = "Autorize o FalaMac em Ajustes do Sistema → Privacidade e Segurança → Acessibilidade para inserir o texto automaticamente."
        case noField = "Não foi encontrado um campo de texto editável. O resultado está disponível para copiar."
        case ownWindow = "A gravação começou na janela do FalaMac. Selecione o campo de outro app antes de gravar."
    }

    static func prepare() async -> (InsertionTarget?, CaptureFailure?) {
        guard AXIsProcessTrusted() else { return (nil, .permission) }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return (nil, .ownWindow) }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.3)
        // https://www.electronjs.org/docs/latest/tutorial/accessibility
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        for attempt in 0..<4 {
            if let result = capture(), result.pid == app.processIdentifier { return (result, nil) }
            guard !Task.isCancelled else { return (nil, .noField) }
            if attempt < 3 { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        return (nil, .noField)
    }

    static func capture() -> InsertionTarget? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.3)
        guard let focused = elementAttribute(application, kAXFocusedUIElementAttribute), !protectedField(focused) else { return nil }
        var field: AXUIElement? = accepts(focused) ? focused : nil
        var ancestor = focused
        for _ in 0..<3 where field == nil {
            guard let parent = elementAttribute(ancestor, kAXParentAttribute), !protectedField(parent) else { break }
            if accepts(parent) { field = parent }
            ancestor = parent
        }
        if field == nil {
            let children = attribute(focused, kAXChildrenAttribute) as? [AXUIElement] ?? []
            let candidates = children.prefix(24).filter { !protectedField($0) && accepts($0) }
            if candidates.count == 1 { field = candidates.first }
        }
        guard let field, !protectedField(field) else { return nil }
        let window = elementAttribute(field, kAXWindowAttribute) ?? elementAttribute(application, kAXFocusedWindowAttribute)
        return InsertionTarget(pid: app.processIdentifier, element: field, window: window, identity: geometry(field))
    }

    func insert(_ text: String) async -> Bool {
        // Wait for Fn/Option release to avoid turning Command+V into another shortcut.
        let modifiers: CGEventFlags = [.maskSecondaryFn, .maskControl, .maskAlternate, .maskCommand, .maskShift]
        for _ in 0..<15 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty { break }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        guard let current = Self.capture(), matches(current),
              CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty else { return false }
        // Paste produces the input/change events required by web and Electron editors.
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        let board = NSPasteboard.general
        let previous = board.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        board.clearContents()
        guard board.setString(text, forType: .string) else { board.writeObjects(previous); return false }
        let change = board.changeCount
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        try? await Task.sleep(nanoseconds: 25_000_000)
        up.post(tap: .cgSessionEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard board.changeCount == change else { return }
            board.clearContents(); board.writeObjects(previous)
        }
        return true // Dispatch confirmed; the destination does not acknowledge paste.
    }

    private func matches(_ other: InsertionTarget) -> Bool {
        guard other.pid == pid else { return false }
        if CFEqual(other.element, element) { return true }
        // Electron can recreate the AX object while the same editor stays focused.
        guard let window, let otherWindow = other.window, CFEqual(window, otherWindow),
              let identity, let otherIdentity = other.identity else { return false }
        return identity.matches(otherIdentity)
    }

    private static func accepts(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        return FieldIdentity.accepts(role: attribute(element, kAXRoleAttribute) as? String ?? "",
                                     subrole: attribute(element, kAXSubroleAttribute) as? String ?? "",
                                     editable: attribute(element, "AXEditable") as? Bool,
                                     selectedTextSettable: settable.boolValue)
    }

    private static func protectedField(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<5 {
            guard let node = current else { break }
            if attribute(node, kAXSubroleAttribute) as? String == "AXSecureTextField"
                || attribute(node, kAXRoleAttribute) as? String == "AXSecureTextField"
                || attribute(node, "AXProtectedContent") as? Bool == true { return true }
            current = elementAttribute(node, kAXParentAttribute)
        }
        return false
    }

    private static func geometry(_ element: AXUIElement) -> FieldIdentity? {
        guard let pos = attribute(element, kAXPositionAttribute), CFGetTypeID(pos) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var dimensions = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return FieldIdentity(role: attribute(element, kAXRoleAttribute) as? String ?? "",
                             identifier: attribute(element, kAXIdentifierAttribute) as? String ?? "",
                             x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
