import Foundation

/// Local metadata only. Does not read or transmit field contents.
public struct FieldIdentity: Equatable {
    public let role: String
    public let identifier: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(role: String, identifier: String = "", x: Double, y: Double, width: Double, height: Double) {
        self.role = role; self.identifier = identifier
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public func matches(_ other: FieldIdentity) -> Bool {
        guard role == other.role, identifier == other.identifier,
              width > 0, height > 0, other.width > 0, other.height > 0 else { return false }
        return abs(x - other.x) <= 4 && abs(y - other.y) <= 4
            && abs(width - other.width) <= 4 && abs(height - other.height) <= 4
    }

    public static func accepts(role: String, subrole: String, editable: Bool?, selectedTextSettable: Bool) -> Bool {
        guard subrole != "AXSecureTextField", role != "AXSecureTextField", editable != false else { return false }
        let textRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXEditableText"]
        return textRoles.contains(role) || editable == true || selectedTextSettable
    }
}
