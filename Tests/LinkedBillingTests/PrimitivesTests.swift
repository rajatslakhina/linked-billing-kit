import XCTest
@testable import LinkedBilling

final class PrimitivesTests: XCTestCase {
    func testSaturatingAddClampsInsteadOfTrapping() {
        XCTAssertEqual(Saturating.add(.max, 1), .max)
        XCTAssertEqual(Saturating.add(.min, -1), .min)
        XCTAssertEqual(Saturating.add(2, 3), 5)
    }

    func testSaturatingSubtractClampsBothDirections() {
        XCTAssertEqual(Saturating.subtract(.min, 1), .min)
        XCTAssertEqual(Saturating.subtract(.max, -1), .max)
        XCTAssertEqual(Saturating.subtract(5, 7), -2)
    }

    func testSaturatingMultiplyClampsBySign() {
        XCTAssertEqual(Saturating.multiply(.max, 2), .max)
        XCTAssertEqual(Saturating.multiply(.max, -2), .min)
        XCTAssertEqual(Saturating.multiply(.min, -1), .max)
        XCTAssertEqual(Saturating.multiply(-3, 4), -12)
    }

    func testMicroUSDNeverGoesNegativeAndDollarsSaturate() {
        XCTAssertEqual(MicroUSD(-5), .zero)
        XCTAssertEqual(MicroUSD(3) - MicroUSD(10), .zero)
        XCTAssertEqual(MicroUSD.dollars(.max).value, .max)
        XCTAssertEqual(MicroUSD(.max) + MicroUSD(1), MicroUSD(.max))
    }

    func testMicroUSDDescriptionRoundsDownToTheCent() {
        XCTAssertEqual(MicroUSD(1_234_567).description, "$1.23")
        XCTAssertEqual(MicroUSD(50_000).description, "$0.05")
        XCTAssertEqual(MicroUSD.zero.description, "$0.00")
    }

    func testUserProfileIDAcceptsOnlyTheDocumentedShape() {
        XCTAssertNotNil(UserProfileID("uprof_01HV9Z"))
        XCTAssertNotNil(UserProfileID("uprof_a-b_C9"))
        XCTAssertNil(UserProfileID("uprof_"))
        XCTAssertNil(UserProfileID("user_01HV9Z"))
        XCTAssertNil(UserProfileID("uprof_01 HV9Z"))
        XCTAssertNil(UserProfileID("uprof_01\nX-Injected: 1"))
        XCTAssertNil(UserProfileID("uprof_é"))
        XCTAssertNil(UserProfileID("uprof_" + String(repeating: "a", count: 129)))
        XCTAssertNotNil(UserProfileID("uprof_" + String(repeating: "a", count: 128)))
    }
}
