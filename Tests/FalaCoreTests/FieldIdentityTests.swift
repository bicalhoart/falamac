import Testing
@testable import FalaCore

struct FieldIdentityTests {
    @Test func acceptsRichEditorsWithoutAcceptingReadOnlyOrPasswordFields() {
        #expect(FieldIdentity.accepts(role: "AXTextArea", subrole: "", editable: nil, selectedTextSettable: false))
        #expect(FieldIdentity.accepts(role: "AXGroup", subrole: "", editable: true, selectedTextSettable: false))
        #expect(FieldIdentity.accepts(role: "AXGroup", subrole: "", editable: nil, selectedTextSettable: true))
        #expect(!FieldIdentity.accepts(role: "AXTextField", subrole: "AXSecureTextField", editable: true, selectedTextSettable: true))
        #expect(!FieldIdentity.accepts(role: "AXTextArea", subrole: "", editable: false, selectedTextSettable: true))
        #expect(!FieldIdentity.accepts(role: "AXWebArea", subrole: "", editable: nil, selectedTextSettable: false))
    }

    @Test func recreatedEditorMatchesWhileOtherFieldsDoNot() {
        let original = FieldIdentity(role: "AXTextArea", identifier: "editor", x: 20, y: 100, width: 400, height: 80)
        let recreated = FieldIdentity(role: "AXTextArea", identifier: "editor", x: 21, y: 100, width: 400, height: 81)
        let otherLocation = FieldIdentity(role: "AXTextArea", identifier: "editor", x: 20, y: 300, width: 400, height: 80)
        let otherID = FieldIdentity(role: "AXTextArea", identifier: "search", x: 20, y: 100, width: 400, height: 80)
        let zeroSize = FieldIdentity(role: "AXTextArea", identifier: "editor", x: 20, y: 100, width: 0, height: 0)
        #expect(original.matches(recreated))
        #expect(!original.matches(otherLocation))
        #expect(!original.matches(otherID))
        #expect(!zeroSize.matches(zeroSize))
    }
}
