import XCTest
@testable import LinkedBilling

/// One customer's month, end to end, through the real gateway and reconciler against
/// the simulated API. This is the same script the demo app's Timeline runs, so the
/// numbers in the demo README are pinned here.
final class EndToEndMonthTests: XCTestCase {
    func testAMonthOfLinkedBilling() async throws {
        let start = BillingMonth.epochMillis(year: 2026, month: 11, day: 3, hour: 9)
        let clock = ManualClock(start)
        let org = SimulatedClaudeOrg(clock: clock)
        let profile = try XCTUnwrap(UserProfileID("uprof_acme_corp"))
        let summarize = FeatureDescriptor(id: "summarize", displayName: "Summarize thread", model: "claude-opus-5-5",
                                          subsidyModel: SubsidyModel("claude-haiku-4-5", costPercent: 20))
        let draft = FeatureDescriptor(id: "draft", displayName: "Draft reply", model: "claude-opus-5-5",
                                      subsidyModel: SubsidyModel("claude-haiku-4-5", costPercent: 20))
        let analysis = FeatureDescriptor(id: "analysis", displayName: "Run analysis", model: "claude-opus-5-5",
                                         usesCodeExecution: true)
        let safety = FeatureDescriptor(id: "safety", displayName: "Safety check", billing: .appOperational,
                                       model: "claude-haiku-4-5")
        let gateway = LinkedBillingGateway(
            profile: profile, plan: .subscription(includedPerMonth: .dollars(1)),
            policy: RoutingPolicy(subsidyPerMonth: .dollars(3)),
            transport: org, clock: clock, sleeper: AdvancingSleeper(clock: clock))
        let reconciler = ConnectionReconciler(gateway: gateway, source: org)

        func send(_ feature: FeatureDescriptor, cents: Int64) async -> GatewayResult {
            let result = await gateway.send(InferenceRequest(feature: feature, estimate: MicroUSD(cents * 10_000), prompt: "p"))
            clock.advance(by: 30_000)
            return result
        }
        func payer(_ result: GatewayResult) -> String {
            switch result.outcome {
            case let .served(_, payer, _, _): return payer.isCustomer ? "customer" : "app"
            case .paused: return "paused"
            case .failed: return "failed"
            }
        }

        // 1-2. Not linked: included allowance, then subsidy on the cheaper model.
        let firstRequest = await send(summarize, cents: 80)
        XCTAssertEqual(payer(firstRequest), "app")
        clock.advance(by: 30 * 60_000)
        let second = await send(summarize, cents: 70)
        guard case .served(_, .app, "claude-haiku-4-5", MicroUSD(140_000)) = second.outcome else { return XCTFail("\(second.outcome)") }

        // 3. Link with a $2 cap; first request retried inside the propagation window.
        clock.advance(by: 60 * 60_000)
        await gateway.apply(.linkStarted)
        await org.configure { $0.propagationMillis = 1_500; $0.spendCap = .dollars(2) }
        await org.link()
        await gateway.apply(.linkCompleted)
        let firstLinked = await send(draft, cents: 50)
        XCTAssertEqual(payer(firstLinked), "customer")
        XCTAssertEqual(firstLinked.attempts.count, 2)

        // 4. Code execution and operational work are app-paid.
        clock.advance(by: 10 * 60_000)
        let code = await send(analysis, cents: 30)
        XCTAssertEqual(code.attempts.first?.decision,
                       .billApp(model: "claude-opus-5-5", budget: .subsidy, reason: .codeExecutionNotCustomerBillable, estimate: MicroUSD(300_000)))
        let ops = await send(safety, cents: 5)
        guard case .billApp(_, .operational, _, _)? = ops.attempts.first?.decision else { return XCTFail() }

        // 5. Burst: three customer-billed, then the cap → subsidy.
        clock.advance(by: 5 * 60_000)
        var burst: [String] = []
        for _ in 0..<4 { burst.append(payer(await send(draft, cents: 50))) }
        XCTAssertEqual(burst, ["customer", "customer", "customer", "app"])
        guard case .linked(.spendLimitReached) = await gateway.link.phase else { return XCTFail() }

        // 6. The cap is raised silently; the probe after 15+ minutes recovers.
        await org.configure { $0.spendCap = .dollars(10) }
        clock.advance(by: 16 * 60_000)
        let probe = await send(summarize, cents: 40)
        guard case .billCustomer(_, _, true)? = probe.attempts.first?.decision else { return XCTFail("\(probe.attempts)") }
        let phaseAfterProbe = await gateway.link.phase
        XCTAssertEqual(phaseAfterProbe, .linked(.billable))

        // 7. Overloaded once, retried after retry-after.
        clock.advance(by: 20 * 60_000)
        await org.configure { $0.overloadNext = 1 }
        let overloadedRequest = await send(draft, cents: 30)
        XCTAssertEqual(payer(overloadedRequest), "customer")

        // 8. Unlinked in the Console: refusal → subsidy → status read → unlinked.
        clock.advance(by: 45 * 60_000)
        await org.unlink(reason: .revokedByAdmin)
        clock.advance(by: 5 * 60_000)
        let afterUnlink = await send(summarize, cents: 40)
        XCTAssertEqual(payer(afterUnlink), "app")
        XCTAssertTrue(afterUnlink.statusCheckRecommended)
        _ = await reconciler.reconcileNow()
        guard case .unlinked(.revokedByAdmin?, _) = await gateway.link.phase else { return XCTFail() }

        // 9. Subsidy budget ($3) runs out: three more fit, two pause.
        clock.advance(by: 30 * 60_000)
        var tail: [String] = []
        for _ in 0..<5 { tail.append(payer(await send(summarize, cents: 300))) }
        XCTAssertEqual(tail, ["app", "app", "app", "paused", "paused"])

        let ledger = await gateway.ledger
        let november = ledger.totals(for: BillingMonth(containing: start))
        XCTAssertEqual(november.customerBilled, MicroUSD(2_700_000))   // 0.50 + 3×0.50 + 0.40 + 0.30
        // 0.14 + 0.30 (code) + 0.10 + 0.08 + 3×0.60
        XCTAssertEqual(november.appIncluded, MicroUSD(800_000))
        XCTAssertEqual(november.appSubsidy, MicroUSD(2_420_000))
        XCTAssertEqual(november.appOperational, MicroUSD(50_000))
        XCTAssertLessThanOrEqual(november.appSubsidy, MicroUSD.dollars(3))

        // 10. New UTC month: the allowance covers usage again.
        clock.set(BillingMonth.epochMillis(year: 2026, month: 12, day: 1))
        let december = await send(summarize, cents: 40)
        guard case .billApp(_, .included, _, _)? = december.attempts.first?.decision else { return XCTFail() }
    }
}
