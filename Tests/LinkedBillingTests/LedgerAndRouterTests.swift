import XCTest
@testable import LinkedBilling

final class SpendLedgerTests: XCTestCase {
    let now = BillingMonth.epochMillis(year: 2026, month: 11, day: 10)
    var month: BillingMonth { BillingMonth(containing: now) }

    func testReservationsCountAgainstTheBudgetBeforeAnythingIsSpent() {
        var ledger = SpendLedger()
        let limit = MicroUSD.dollars(1)
        XCTAssertNotNil(ledger.reserve(MicroUSD(600_000), from: .subsidy, limit: limit, at: now))
        // Nothing is spent yet, but a second $0.60 must not fit under $1.
        XCTAssertNil(ledger.reserve(MicroUSD(600_000), from: .subsidy, limit: limit, at: now))
        XCTAssertEqual(ledger.committed(.subsidy, in: month), MicroUSD(600_000))
        XCTAssertEqual(ledger.totals(for: month).appSubsidy, .zero)
    }

    func testReleasingAReservationReturnsTheBudget() throws {
        var ledger = SpendLedger()
        let id = try XCTUnwrap(ledger.reserve(MicroUSD(900_000), from: .subsidy, limit: .dollars(1), at: now))
        ledger.release(id)
        XCTAssertEqual(ledger.committed(.subsidy, in: month), .zero)
        XCTAssertNotNil(ledger.reserve(MicroUSD(900_000), from: .subsidy, limit: .dollars(1), at: now))
    }

    func testRecordingSettlesTheReservationAtTheActualCost() throws {
        var ledger = SpendLedger()
        let id = try XCTUnwrap(ledger.reserve(MicroUSD(500_000), from: .subsidy, limit: .dollars(1), at: now))
        ledger.record(featureID: "f", payer: .app, budget: .subsidy, model: "m", outcome: .billed(MicroUSD(420_000)),
                      reservation: id, at: now)
        XCTAssertEqual(ledger.reservationCount, 0)
        XCTAssertEqual(ledger.committed(.subsidy, in: month), MicroUSD(420_000))
    }

    func testAReservationMadeBeforeMidnightIsChargedToItsOwnMonth() throws {
        var ledger = SpendLedger()
        let lastMinute = BillingMonth.epochMillis(year: 2026, month: 11, day: 30, hour: 23, minute: 59)
        let id = try XCTUnwrap(ledger.reserve(MicroUSD(100), from: .subsidy, limit: .dollars(1), at: lastMinute))
        let afterMidnight = BillingMonth.epochMillis(year: 2026, month: 12, day: 1, hour: 0, minute: 1)
        ledger.record(featureID: "f", payer: .app, budget: .subsidy, model: "m", outcome: .billed(MicroUSD(100)),
                      reservation: id, at: afterMidnight)
        XCTAssertEqual(ledger.totals(for: BillingMonth(containing: lastMinute)).appSubsidy, MicroUSD(100))
        XCTAssertEqual(ledger.totals(for: BillingMonth(containing: afterMidnight)).appSubsidy, .zero)
    }

    func testRefusedAndUnknownOutcomesSpendNothingButUnknownIsCounted() {
        var ledger = SpendLedger()
        ledger.record(featureID: "f", payer: .app, budget: .subsidy, model: "m", outcome: .refused(.spendLimitReached),
                      reservation: nil, at: now)
        ledger.record(featureID: "f", payer: .app, budget: .subsidy, model: "m", outcome: .unknown,
                      reservation: nil, at: now)
        let totals = ledger.totals(for: month)
        XCTAssertEqual(totals.appSubsidy, .zero)
        XCTAssertEqual(totals.unknownOutcomes, 1)
    }

    func testCustomerSpendIsTrackedSeparatelyFromEveryAppBudget() throws {
        var ledger = SpendLedger()
        let profile = try XCTUnwrap(UserProfileID("uprof_1"))
        ledger.record(featureID: "f", payer: .customer(profile), budget: nil, model: "m", outcome: .billed(MicroUSD(7)),
                      reservation: nil, at: now)
        ledger.record(featureID: "f", payer: .app, budget: .included, model: "m", outcome: .billed(MicroUSD(5)),
                      reservation: nil, at: now)
        ledger.record(featureID: "f", payer: .app, budget: .operational, model: "m", outcome: .billed(MicroUSD(3)),
                      reservation: nil, at: now)
        let totals = ledger.totals(for: month)
        XCTAssertEqual(totals.customerBilled, MicroUSD(7))
        XCTAssertEqual(totals.appIncluded, MicroUSD(5))
        XCTAssertEqual(totals.appOperational, MicroUSD(3))
        XCTAssertEqual(totals.appSubsidy, .zero)
    }

    func testTheEntryLogIsABoundedRingNewestFirst() {
        var ledger = SpendLedger(entryCapacity: 3)
        for index in 0..<5 {
            ledger.record(featureID: "f\(index)", payer: .app, budget: .operational, model: "m",
                          outcome: .billed(MicroUSD(1)), reservation: nil, at: now)
        }
        XCTAssertEqual(ledger.recentEntries.map(\.featureID), ["f4", "f3", "f2"])
    }

    func testOldMonthsArePruned() {
        var ledger = SpendLedger(monthsRetained: 2)
        for monthIndex: Int64 in 1...5 {
            let at = BillingMonth.epochMillis(year: 2026, month: monthIndex, day: 2)
            ledger.record(featureID: "f", payer: .app, budget: .subsidy, model: "m", outcome: .billed(MicroUSD(1)),
                          reservation: nil, at: at)
        }
        XCTAssertEqual(ledger.totals(for: BillingMonth(containing: BillingMonth.epochMillis(year: 2026, month: 1, day: 2))).appSubsidy, .zero)
        XCTAssertEqual(ledger.totals(for: BillingMonth(containing: BillingMonth.epochMillis(year: 2026, month: 5, day: 2))).appSubsidy, MicroUSD(1))
        XCTAssertEqual(ledger.totals(for: BillingMonth(containing: BillingMonth.epochMillis(year: 2026, month: 4, day: 2))).appSubsidy, MicroUSD(1))
    }

    func testReservationsAreBounded() {
        var ledger = SpendLedger()
        for _ in 0..<SpendLedger.maxReservations {
            XCTAssertNotNil(ledger.reserve(.zero, from: .operational, limit: MicroUSD(.max), at: now))
        }
        XCTAssertNil(ledger.reserve(.zero, from: .operational, limit: MicroUSD(.max), at: now))
    }
}

final class BillingRouterTests: XCTestCase {
    let now = BillingMonth.epochMillis(year: 2026, month: 11, day: 10)
    let profile = UserProfileID("uprof_acme")
    let policy = RoutingPolicy(subsidyPerMonth: .dollars(3))
    let chat = FeatureDescriptor(id: "chat", displayName: "Chat", model: "big",
                                 subsidyModel: SubsidyModel("small", costPercent: 20))
    let ops = FeatureDescriptor(id: "ops", displayName: "Safety", billing: .appOperational, model: "small")
    let code = FeatureDescriptor(id: "code", displayName: "Analysis", model: "big", usesCodeExecution: true)
    let cents40 = MicroUSD(400_000)
    let subscriber = StorePlan.subscription(includedPerMonth: .dollars(1))

    private func route(_ feature: FeatureDescriptor, _ admission: CustomerAdmission, plan: StorePlan,
                       ledger: SpendLedger = SpendLedger(), profile: UserProfileID?? = nil,
                       policy: RoutingPolicy? = nil) -> RouteDecision {
        BillingRouter.route(feature: feature, estimate: cents40, profile: profile ?? self.profile,
                            admission: admission, plan: plan, policy: policy ?? self.policy, ledger: ledger, at: now)
    }

    private func spentLedger(included: MicroUSD = .zero, subsidy: MicroUSD = .zero) -> SpendLedger {
        var ledger = SpendLedger()
        ledger.record(featureID: "x", payer: .app, budget: .included, model: "m", outcome: .billed(included), reservation: nil, at: now)
        ledger.record(featureID: "x", payer: .app, budget: .subsidy, model: "m", outcome: .billed(subsidy), reservation: nil, at: now)
        return ledger
    }

    func testOperationalUsageIsNeverBilledToTheCustomer() {
        XCTAssertEqual(route(ops, .admit, plan: .noSubscription),
                       .billApp(model: "small", budget: .operational, reason: .operational, estimate: cents40))
    }

    func testIncludedAllowanceIsUsedBeforeTheCustomerIsBilled() {
        XCTAssertEqual(route(chat, .admit, plan: subscriber),
                       .billApp(model: "big", budget: .included, reason: .includedInSubscription, estimate: cents40))
    }

    func testOnceTheAllowanceIsUsedTheLinkedOrgPays() throws {
        let profile = try XCTUnwrap(self.profile)
        XCTAssertEqual(route(chat, .admit, plan: subscriber, ledger: spentLedger(included: .dollars(1))),
                       .billCustomer(profile, model: "big", isProbe: false))
        XCTAssertEqual(route(chat, .probe, plan: .noSubscription),
                       .billCustomer(profile, model: "big", isProbe: true))
    }

    func testCodeExecutionIsNeverBilledToTheCustomerEvenWhenAdmitted() {
        let decision = route(code, .admit, plan: subscriber, ledger: spentLedger(included: .dollars(1)))
        XCTAssertEqual(decision, .billApp(model: "big", budget: .subsidy, reason: .codeExecutionNotCustomerBillable, estimate: cents40))
        XCTAssertEqual(route(code, .admit, plan: .noSubscription), .pause(.codeExecutionUnfunded))
    }

    func testCodeExecutionKeepsTheFeaturesOwnModel() {
        let codeWithCheaper = FeatureDescriptor(id: "c", displayName: "C", model: "big",
                                                subsidyModel: SubsidyModel("small", costPercent: 20), usesCodeExecution: true)
        XCTAssertEqual(route(codeWithCheaper, .admit, plan: subscriber, ledger: spentLedger(included: .dollars(1))),
                       .billApp(model: "big", budget: .subsidy, reason: .codeExecutionNotCustomerBillable, estimate: cents40))
    }

    func testARefusedCustomerIsSubsidisedOnTheCheaperModel() {
        let denial = CustomerDenial.spendLimitReached(resetsAt: 1)
        XCTAssertEqual(route(chat, .deny(denial), plan: subscriber, ledger: spentLedger(included: .dollars(1))),
                       .billApp(model: "small", budget: .subsidy, reason: .subsidy(denial), estimate: MicroUSD(80_000)))
    }

    func testSubsidyRequiresASubscriptionByDefault() {
        XCTAssertEqual(route(chat, .deny(.notBillable), plan: .noSubscription), .pause(.customerUnavailable(.notBillable)))
        let open = RoutingPolicy(subsidyPerMonth: .dollars(3), subsidyRequiresSubscription: false)
        guard case .billApp(_, .subsidy, _, _) = route(chat, .deny(.notBillable), plan: .noSubscription, policy: open) else {
            return XCTFail("subsidy should apply when the policy allows free users")
        }
    }

    func testSubsidyStopsAtTheMonthlyBudgetIncludingTheLastCent() {
        let cost = MicroUSD(80_000)
        let atEdge = spentLedger(included: .dollars(1), subsidy: MicroUSD.dollars(3) - cost)
        guard case .billApp = route(chat, .deny(.notBillable), plan: subscriber, ledger: atEdge) else {
            return XCTFail("exactly filling the budget is allowed")
        }
        let over = spentLedger(included: .dollars(1), subsidy: MicroUSD.dollars(3) - cost + MicroUSD(1))
        XCTAssertEqual(route(chat, .deny(.notBillable), plan: subscriber, ledger: over),
                       .pause(.subsidyBudgetExhausted(.notBillable)))
    }

    func testIneligibleFeaturesPauseInsteadOfBeingSubsidised() {
        let premium = FeatureDescriptor(id: "p", displayName: "P", model: "big", subsidyEligible: false)
        XCTAssertEqual(route(premium, .deny(.unlinked(.revokedByAdmin)), plan: subscriber, ledger: spentLedger(included: .dollars(1))),
                       .pause(.subsidyNotEligible(.unlinked(.revokedByAdmin))))
    }

    func testNoProfileMeansNotLinkedWhateverTheAdmission() {
        XCTAssertEqual(route(chat, .admit, plan: .noSubscription, profile: .some(nil)),
                       .pause(.customerUnavailable(.notLinked)))
    }

    func testSubsidyCostScalesAndNeverRoundsToFree() {
        let tiny = FeatureDescriptor(id: "t", displayName: "T", model: "big", subsidyModel: SubsidyModel("small", costPercent: 1))
        XCTAssertEqual(BillingRouter.subsidyChoice(feature: tiny, estimate: MicroUSD(10)).1, MicroUSD(1))
        XCTAssertEqual(BillingRouter.subsidyChoice(feature: tiny, estimate: .zero).1, .zero)
        XCTAssertEqual(BillingRouter.subsidyChoice(feature: chat, estimate: MicroUSD(.max)).1, MicroUSD(.max / 100))
        XCTAssertEqual(SubsidyModel("s", costPercent: 900).costPercent, 100)
        XCTAssertEqual(SubsidyModel("s", costPercent: -3).costPercent, 1)
    }
}
