import XCTest
import LinkedBilling
import LinkedBillingTesting

/// Pins the scripted month the demo app plays: the same `ScriptedMonth` the app
/// renders, run end to end through the real gateway and reconciler.
final class ScriptedMonthTests: XCTestCase {
    static func configuration() throws -> ScriptedMonth.Configuration {
        let opus: ModelID = "claude-opus-5-5"
        let haiku: ModelID = "claude-haiku-4-5"
        return ScriptedMonth.Configuration(
            policy: RoutingPolicy(subsidyPerMonth: .dollars(3)),
            plan: .subscription(includedPerMonth: .dollars(1)),
            profile: try XCTUnwrap(UserProfileID("uprof_acme_corp")),
            summarize: FeatureDescriptor(id: "summarize", displayName: "Summarize thread", model: opus,
                                         subsidyModel: SubsidyModel(haiku, costPercent: 20)),
            draft: FeatureDescriptor(id: "draft", displayName: "Draft reply", model: opus,
                                     subsidyModel: SubsidyModel(haiku, costPercent: 20)),
            analysis: FeatureDescriptor(id: "analysis", displayName: "Run analysis", model: opus, usesCodeExecution: true),
            safety: FeatureDescriptor(id: "safety", displayName: "Safety check", billing: .appOperational, model: haiku))
    }

    private func payers(_ step: ScriptedMonth.StepRecord) -> [String] {
        step.requests.map { request in
            switch request.result.outcome {
            case let .served(_, payer, _, _): return payer.isCustomer ? "customer" : "app"
            case .paused: return "paused"
            case .failed: return "failed"
            }
        }
    }

    func testTheWholeMonthProducesTheDocumentedNumbers() async throws {
        let month = ScriptedMonth(configuration: try Self.configuration())
        var steps: [ScriptedMonth.StepRecord] = []
        var snapshots: [ScriptedMonth.Snapshot] = []
        while let step = await month.runNextStep() {
            steps.append(step)
            snapshots.append(await month.snapshot())
        }
        XCTAssertEqual(steps.count, ScriptedMonth.stepCount)
        guard steps.count == 10, snapshots.count == 10 else { return XCTFail("expected 10 steps") }
        let isFinished = await month.isFinished
        XCTAssertTrue(isFinished)
        let afterEnd = await month.runNextStep()
        XCTAssertNil(afterEnd)

        // 1-2: allowance, then subsidy on the cheaper model.
        XCTAssertEqual(payers(steps[0]), ["app"])
        XCTAssertEqual(payers(steps[1]), ["app"])
        guard case .served(_, .app, "claude-haiku-4-5", MicroUSD(140_000)) = steps[1].requests.first?.result.outcome else {
            return XCTFail("\(steps[1].requests)")
        }
        // 3: forged callback rejected, real one accepted; warm-up retry, then customer.
        XCTAssertEqual(payers(steps[2]), ["customer"])
        XCTAssertEqual(steps[2].requests.first?.result.attempts.count, 2)
        XCTAssertTrue(steps[2].note?.contains("rejected (state mismatch)") ?? false)
        // 4: code execution and operational usage are app-paid.
        XCTAssertEqual(payers(steps[3]), ["app", "app"])
        // 5: three customer-billed, then the cap → subsidy in the same call.
        XCTAssertEqual(payers(steps[4]), ["customer", "customer", "customer", "app"])
        XCTAssertEqual(snapshots[4].thisMonth.customerBilled, MicroUSD(2_000_000))
        XCTAssertEqual(snapshots[4].thisMonth.appSubsidy, MicroUSD(540_000))
        // 6: the probe recovers the link.
        guard case .billCustomer(_, _, true)? = steps[5].requests.first?.result.attempts.first?.decision else {
            return XCTFail("\(steps[5].requests)")
        }
        XCTAssertEqual(steps[5].phaseAfter, .linked(.billable))
        // 7: 503 then retry to the same payer.
        XCTAssertEqual(payers(steps[6]), ["customer"])
        XCTAssertEqual(steps[6].requests.first?.result.attempts.count, 2)
        // 8: silent unlink detected by the reconciler.
        XCTAssertEqual(payers(steps[7]), ["app"])
        guard case .unlinked(.revokedByAdmin?, _) = steps[7].phaseAfter else { return XCTFail("\(steps[7].phaseAfter)") }
        // 9: concurrent burst: reservations let exactly three fit under $3.
        XCTAssertEqual(payers(steps[8]), ["app", "app", "app", "paused", "paused"])
        XCTAssertLessThanOrEqual(snapshots[8].thisMonth.appSubsidy, MicroUSD.dollars(3))

        // November totals, as shown in the demo's screenshots and README.
        let november = snapshots[9].months.first { $0.month.description == "2026-11" }?.totals
        XCTAssertEqual(november?.customerBilled, MicroUSD(2_700_000))  // 0.50 + 3×0.50 + 0.40 + 0.30
        XCTAssertEqual(november?.appIncluded, MicroUSD(800_000))
        // Subsidy: 0.14 + 0.30 (code execution) + 0.10 + 0.08 + 3×0.60
        XCTAssertEqual(november?.appSubsidy, MicroUSD(2_420_000))
        XCTAssertEqual(november?.appOperational, MicroUSD(50_000))
        // 10: new UTC month; the allowance pays again.
        XCTAssertEqual(snapshots[9].thisMonth.appIncluded, MicroUSD(400_000))
        XCTAssertTrue(steps[9].note?.contains("2026-11 closed: customer org $2.70") ?? false)
    }

    func testTheRouterMatrixMatchesThePrecedenceRules() throws {
        let configuration = try Self.configuration()
        let rows = ScriptedMonth.matrix(for: configuration)
        XCTAssertEqual(rows.map(\.feature.id), ["summarize", "draft", "analysis", "safety"])
        guard rows.count == 4 else { return }
        for row in rows {
            XCTAssertEqual(row.decisions.count, ScriptedMonth.MatrixColumn.allCases.count)
        }
        // Linked → customer; every other column → subsidy on haiku.
        guard let summarize = rows.first, summarize.decisions.count == 4 else { return }
        XCTAssertEqual(summarize.decisions[0].payer, .customer(configuration.profile))
        for decision in summarize.decisions.dropFirst() {
            guard case .billApp("claude-haiku-4-5", .subsidy, _, MicroUSD(80_000)) = decision else { return XCTFail("\(decision)") }
        }
        // Code execution and operational usage are app-paid in every column.
        for row in rows.suffix(2) {
            XCTAssertTrue(row.decisions.allSatisfy { $0.payer == .app }, row.feature.id)
        }
    }
}
