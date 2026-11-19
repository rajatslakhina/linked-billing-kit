import Foundation
import XCTest
@testable import LinkedBilling

final class BillingMonthTests: XCTestCase {
    func testKnownInstantsLandInTheirUTCMonth() {
        // 2026-11-19T08:00:00Z = 1795075200000
        let month = BillingMonth(containing: 1_795_075_200_000)
        XCTAssertEqual(month.description, "2026-11")
        XCTAssertEqual(month.start, BillingMonth.epochMillis(year: 2026, month: 11, day: 1))
        XCTAssertEqual(month.end, BillingMonth.epochMillis(year: 2026, month: 12, day: 1))
        XCTAssertEqual(BillingMonth.epochMillis(year: 1970, month: 1, day: 1), 0)
    }

    func testTheBoundaryIsExactToTheMillisecond() {
        let december = BillingMonth.epochMillis(year: 2026, month: 12, day: 1)
        XCTAssertEqual(BillingMonth(containing: december - 1).description, "2026-11")
        XCTAssertEqual(BillingMonth(containing: december).description, "2026-12")
    }

    func testDecemberRollsIntoJanuaryOfTheNextYear() {
        let month = BillingMonth(containing: BillingMonth.epochMillis(year: 2026, month: 12, day: 31, hour: 23, minute: 59))
        XCTAssertEqual(month.next.description, "2027-01")
        XCTAssertEqual(month.end, BillingMonth.epochMillis(year: 2027, month: 1, day: 1))
    }

    func testLeapYearsFollowTheGregorianRules() {
        // 2028 is a leap year, 2100 is not, 2000 was.
        for (year, feb29Exists) in [(2028, true), (2100, false), (2000, true)] as [(Int64, Bool)] {
            let march1 = BillingMonth.epochMillis(year: year, month: 3, day: 1)
            let feb28 = BillingMonth.epochMillis(year: year, month: 2, day: 28)
            let daysBetween = (march1 - feb28) / 86_400_000
            XCTAssertEqual(daysBetween, feb29Exists ? 2 : 1, "year \(year)")
        }
    }

    func testInstantsBeforeTheEpochUseFloorDivision() {
        // One millisecond before 1970 is 31 Dec 1969, not January 1970.
        XCTAssertEqual(BillingMonth(containing: -1).description, "1969-12")
        XCTAssertEqual(BillingMonth(containing: -86_400_000).description, "1969-12")
    }

    func testExtremeInstantsDoNotTrap() {
        let low = BillingMonth(containing: .min)
        let high = BillingMonth(containing: .max)
        XCTAssertLessThan(low, high)
        XCTAssertTrue((1...12).contains(low.month))
        XCTAssertTrue((1...12).contains(high.month))
        _ = high.end // saturates rather than trapping
        _ = low.start
        XCTAssertEqual(BillingMonth.epochMillis(year: .max, month: 99, day: -4, hour: 99, minute: -1),
                       BillingMonth.epochMillis(year: 1_000_000, month: 12, day: 1, hour: 23, minute: 0))
    }
}

final class WireProtocolTests: XCTestCase {
    private func body(_ type: String, _ code: String?) -> Data {
        let details = code.map { #","details":{"error_code":"\#($0)"}"# } ?? ""
        return Data(#"{"type":"error","error":{"type":"\#(type)","message":"m"\#(details)}}"#.utf8)
    }

    func testEachDocumentedRefusalDecodes() {
        XCTAssertEqual(BillingRefusal.decode(status: 403, body: body("permission_error", "user_profile_not_billable")), .notBillable)
        XCTAssertEqual(BillingRefusal.decode(status: 402, body: body("billing_error", "linked_organization_billing_unavailable")), .billingUnavailable)
        XCTAssertEqual(BillingRefusal.decode(status: 402, body: body("billing_error", "linked_organization_spend_limit_reached")), .spendLimitReached)
        XCTAssertEqual(BillingRefusal.decode(status: 400, body: body("invalid_request_error", "user_profile_required")), .userProfileRequired)
        XCTAssertEqual(BillingRefusal.decode(status: 400, body: body("invalid_request_error", nil)), .invalidRequest(code: nil))
        XCTAssertEqual(BillingRefusal.decode(status: 503, body: body("overloaded_error", nil), retryAfterHeader: "7"),
                       .overloaded(retryAfterSeconds: 7))
    }

    func testOnlyAnthropicsOverloadedErrorCountsAsUnbilled() {
        // A 503 from a proxy, or without the error body, may have taken effect.
        XCTAssertEqual(BillingRefusal.decode(status: 503, body: Data("<html>Service Unavailable</html>".utf8), retryAfterHeader: "5"),
                       .other(status: 503, type: nil, code: nil))
        XCTAssertEqual(BillingRefusal.decode(status: 503, body: body("api_error", nil)),
                       .other(status: 503, type: "api_error", code: nil))
    }

    func testABare403IsNotMistakenForAnUnlinkedCustomer() {
        // Same status and type, no billing code: an auth problem, not a link signal.
        let refusal = BillingRefusal.decode(status: 403, body: body("permission_error", nil))
        XCTAssertEqual(refusal, .other(status: 403, type: "permission_error", code: nil))
        XCTAssertFalse(refusal.isCustomerBillingSignal)
    }

    func testTheCodeMustMatchItsStatusAndType() {
        // A billing code on the wrong status, or with the wrong type, is not trusted.
        XCTAssertFalse(BillingRefusal.decode(status: 402, body: body("billing_error", "user_profile_not_billable")).isCustomerBillingSignal)
        XCTAssertFalse(BillingRefusal.decode(status: 403, body: body("billing_error", "linked_organization_spend_limit_reached")).isCustomerBillingSignal)
        XCTAssertFalse(BillingRefusal.decode(status: 402, body: body("billing_error", "something_new")).isCustomerBillingSignal)
    }

    func testMalformedBodiesDecodeAsOther() {
        XCTAssertEqual(BillingRefusal.decode(status: 402, body: Data("not json".utf8)), .other(status: 402, type: nil, code: nil))
        XCTAssertEqual(BillingRefusal.decode(status: 500, body: Data()), .other(status: 500, type: nil, code: nil))
    }

    func testRetryAfterAcceptsOnlyDeltaSecondsAndClamps() {
        XCTAssertEqual(BillingRefusal.parseRetryAfter("30"), 30)
        XCTAssertEqual(BillingRefusal.parseRetryAfter(" 2 "), 2)
        XCTAssertEqual(BillingRefusal.parseRetryAfter("999999"), 3600)
        XCTAssertEqual(BillingRefusal.parseRetryAfter("99999999999999999999"), 3600) // too long: clamped, no trap
        XCTAssertEqual(BillingRefusal.parseRetryAfter("99999999999"), 3600)          // 11 digits: still a delay
        XCTAssertEqual(BillingRefusal.parseRetryAfter("9999999999"), 3600)           // 10 digits parse
        XCTAssertEqual(BillingRefusal.parseRetryAfter("00000000005"), 5)              // leading zeros carry no value
        XCTAssertEqual(BillingRefusal.parseRetryAfter("000"), 0)
        XCTAssertNil(BillingRefusal.parseRetryAfter("-5"))
        XCTAssertNil(BillingRefusal.parseRetryAfter("Wed, 21 Oct 2026 07:28:00 GMT"))
        XCTAssertNil(BillingRefusal.parseRetryAfter(""))
        XCTAssertNil(BillingRefusal.parseRetryAfter(nil))
    }

    func testConnectionStatusDecodesEveryDocumentedShape() {
        func decode(_ json: String) -> ConnectionStatus { ConnectionStatus.decode(userProfileBody: Data(json.utf8)) }
        XCTAssertEqual(decode(#"{"id":"uprof_1","connection_status":{"type":"connected"}}"#), .connected)
        XCTAssertEqual(decode(#"{"connection_status":{"type":"not_connected"}}"#), .notConnected)
        XCTAssertEqual(decode(#"{"connection_status":{"type":"disconnected","last_revoked_at":"2026-11-18T10:00:00Z","last_revoked_reason":{"type":"revoked_by_admin"}}}"#),
                       .disconnected(revokedAt: "2026-11-18T10:00:00Z", reason: .revokedByAdmin))
        XCTAssertEqual(decode(#"{"connection_status":{"type":"disconnected","last_revoked_reason":{"type":"revoked_by_app_owner"}}}"#),
                       .disconnected(revokedAt: nil, reason: .revokedByAppOwner))
    }

    func testUnknownOrNullStatusIsUnknownAndUnknownReasonIsOther() {
        func decode(_ json: String) -> ConnectionStatus { ConnectionStatus.decode(userProfileBody: Data(json.utf8)) }
        XCTAssertEqual(decode(#"{"connection_status":null}"#), .unknown)
        XCTAssertEqual(decode(#"{"connection_status":{"type":"suspended"}}"#), .unknown)
        XCTAssertEqual(decode(#"{}"#), .unknown)
        XCTAssertEqual(decode("garbage"), .unknown)
        XCTAssertEqual(decode(#"{"connection_status":{"type":"disconnected","last_revoked_reason":{"type":"revoked_by_robot"}}}"#),
                       .disconnected(revokedAt: nil, reason: .other))
    }

    func testEnvelopeAttributesEveryCallForALinkedCustomer() throws {
        let profile = try XCTUnwrap(UserProfileID("uprof_01HV9Z"))
        let customer = BillingEnvelope(payer: .customer(profile), betaHeaderValue: "beta-x")
        XCTAssertEqual(customer.headers["anthropic-user-profile-id"], "uprof_01HV9Z")
        XCTAssertEqual(customer.headers["anthropic-beta"], "beta-x")
        XCTAssertEqual(customer.billingPolicy, ["type": "billing_policy", "bill_to": "user_profile"])

        // App-paid, but for a linked customer: still attributed to their profile.
        let app = BillingEnvelope(payer: .app, profile: profile, betaHeaderValue: "beta-x")
        XCTAssertEqual(app.headers["anthropic-user-profile-id"], "uprof_01HV9Z")
        XCTAssertEqual(app.billingPolicy["bill_to"], "self")
        // No customer at all (e.g. the app's own evals): no profile header.
        let own = BillingEnvelope(payer: .app)
        XCTAssertNil(own.headers["anthropic-user-profile-id"])
    }

    func testOtherBetasAreMergedNotOverwritten() {
        let envelope = BillingEnvelope(payer: .app, additionalBetas: ["tool-x", BillingEnvelope.billingBeta, "tool-x"])
        XCTAssertEqual(envelope.headers["anthropic-beta"], "user-profiles-billing-2026-10-01,tool-x")
    }
}
