import XCTest
@testable import KitchenManager

@MainActor
final class AuthFormModelTests: XCTestCase {
    func test_emptyEmail_isInvalid() {
        let form = AuthFormModel()
        form.password = "secret1"
        XCTAssertFalse(form.validate())
    }

    func test_shortPassword_isInvalid() {
        let form = AuthFormModel()
        form.email = "cook@example.com"
        form.password = "123"
        XCTAssertFalse(form.validate())
    }

    func test_emptyPassword_isInvalid() {
        let form = AuthFormModel()
        form.email = "cook@example.com"
        XCTAssertFalse(form.validate())
    }

    func test_signupPasswordMismatch_isInvalid() {
        let form = AuthFormModel()
        form.mode = .signUp
        form.email = "cook@example.com"
        form.password = "secret1"
        form.passwordConfirmation = "secret2"
        XCTAssertFalse(form.validate())
    }

    func test_validEmailIsTrimmedAndLowercased() {
        let form = AuthFormModel()
        form.email = "  COOK@Example.COM "
        form.password = "secret1"
        XCTAssertTrue(form.validate())
        XCTAssertEqual(form.normalizedEmail, "cook@example.com")
    }
}
