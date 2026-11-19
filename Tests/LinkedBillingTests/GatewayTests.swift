import XCTest
@testable import LinkedBilling
import LinkedBillingTesting

/// A transport whose calls suspend until the test resolves them, so tests can force
/// any interleaving of concurrent `send` calls across the actor's suspension points.
actor ControlledTransport: MessagesTransport {
    struct Call: Sendable {
        let payer: Payer
        let model: ModelID
    }
    private var pending: [(call: Call, continuation: CheckedContinuation<TransportResult, Error>)] = []
    private(set) var calls: [Call] = []

    func send(_ request: InferenceRequest, payer: Payer, model: ModelID) async throws -> TransportResult {
        try await withCheckedThrowingContinuation { continuation in
            let call = Call(payer: payer, model: model)
            calls.append(call)
            pending.append((call, continuation))
        }
    }

    var pendingCount: Int { pending.count }

    /// Resolve the oldest pending call whose payer matches. If none matches, the
    /// interleaving the test expected didn't happen: fail every pending call so the
    /// test finishes (and fails on its assertions) instead of hanging.
    func resolve(customer: Bool, with result: TransportResult) -> Bool {
        guard let index = pending.firstIndex(where: { $0.call.payer.isCustomer == customer }) else {
            drain()
            return false
        }
        let item = pending.remove(at: index) // index came from firstIndex on this array
        item.continuation.resume(returning: result)
        return true
    }

    /// Fail every pending call with a transport error.
    func drain() {
        let all = pending
        pending.removeAll()
        for item in all { item.continuation.resume(throwing: Drained()) }
    }

    struct Drained: Error {}
}

/// Resolve a pending call, failing the test (and draining the transport so nothing
/// hangs) if no call with that payer is pending.
func expectResolved(_ transport: ControlledTransport, customer: Bool, with result: TransportResult,
                    newest: Bool = false, file: StaticString = #filePath, line: UInt = #line) async {
    let resolved = newest
        ? await transport.resolveNewest(customer: customer, with: result)
        : await transport.resolve(customer: customer, with: result)
    if !resolved { XCTFail("no pending \(customer ? "customer" : "app") call to resolve", file: file, line: line) }
}

/// Wait until `count` calls are pending. On timeout, fail and drain the transport so
/// the test can't hang on a continuation nobody will resume.
func waitForPending(_ transport: ControlledTransport, _ count: Int,
                    file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<2_000 {
        if await transport.pendingCount == count { return }
        await Task.yield()
    }
    let actual = await transport.pendingCount
    XCTFail("expected \(count) pending calls, found \(actual)", file: file, line: line)
    await transport.drain()
}

func waitUntil(_ condition: @Sendable () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<2_000 {
        if await condition() { return }
        await Task.yield()
    }
    XCTFail("condition never became true", file: file, line: line)
}

final class GatewayTests: XCTestCase {
    let start = BillingMonth.epochMillis(year: 2026, month: 11, day: 10, hour: 9)
    let profile = UserProfileID("uprof_acme")
    let chat = FeatureDescriptor(id: "chat", displayName: "Chat", model: "big",
                                 subsidyModel: SubsidyModel("small", costPercent: 20))
    let subscriberNoAllowance = StorePlan.subscription(includedPerMonth: .zero)

    private func linkedState(at now: EpochMillis) -> LinkState {
        var state = LinkState()
        state.apply(.linkCompleted, at: now - 60_000)
        state.apply(.customerBilled(ticket: state.issueTicket()), at: now - 50_000)
        return state
    }

    /// Pass the same `clock` the `org` was built with, so retry sleeps move the
    /// simulated API's time too.
    private func make(clock: ManualClock? = nil, org: SimulatedClaudeOrg? = nil, link: LinkState? = nil, plan: StorePlan? = nil,
                      policy: RoutingPolicy = RoutingPolicy(subsidyPerMonth: .dollars(3)),
                      transport: (any MessagesTransport)? = nil)
        -> (LinkedBillingGateway, SimulatedClaudeOrg, ManualClock, AdvancingSleeper) {
        let clock = clock ?? ManualClock(start)
        let org = org ?? SimulatedClaudeOrg(clock: clock)
        let sleeper = AdvancingSleeper(clock: clock)
        let gateway = LinkedBillingGateway(profile: profile, link: link ?? linkedState(at: start),
                                           plan: plan ?? subscriberNoAllowance, policy: policy,
                                           transport: transport ?? org, clock: clock, sleeper: sleeper)
        return (gateway, org, clock, sleeper)
    }

    private func request(_ cents: Int64 = 50) -> InferenceRequest {
        InferenceRequest(feature: chat, estimate: MicroUSD(cents * 10_000), prompt: "p")
    }

    // MARK: Happy path and fallbacks

    func testAHealthyLinkBillsTheCustomer() async throws {
        let clock = ManualClock(start)
        let org = SimulatedClaudeOrg(clock: clock)
        await org.link()
        let (gateway, _, _, _) = make(clock: clock, org: org)
        let result = await gateway.send(request())
        let profile = try XCTUnwrap(self.profile)
        XCTAssertEqual(result.outcome, .served(text: "[big] Chat: done", payer: .customer(profile), model: "big", cost: MicroUSD(500_000)))
        let totals = await gateway.ledger.totals(for: BillingMonth(containing: start))
        XCTAssertEqual(totals.customerBilled, MicroUSD(500_000))
    }

    func testSpendLimitFallsBackToSubsidyOnTheCheaperModelInTheSameCall() async {
        let clock = ManualClock(start)
        let org = SimulatedClaudeOrg(clock: clock)
        await org.link()
        await org.configure { $0.spendCap = .zero }
        let (gateway, _, _, _) = make(clock: clock, org: org)
        let result = await gateway.send(request())
        XCTAssertEqual(result.outcome, .served(text: "[small] Chat: done", payer: .app, model: "small", cost: MicroUSD(100_000)))
        XCTAssertEqual(result.attempts.map(\.result), [.refused(.spendLimitReached, discardedPartialReply: false),
                                                     .served(cost: MicroUSD(100_000))])
        guard case .linked(.spendLimitReached) = await gateway.link.phase else { return XCTFail() }
        // While capped (and before the probe is due) the customer isn't tried again.
        let second = await gateway.send(request())
        XCTAssertEqual(second.attempts.count, 1)
        XCTAssertEqual(second.attempts.first?.decision.payer, .app)
    }

    func testNotBillableInsideWarmUpIsRetriedOnceAndThenSucceeds() async throws {
        let clock = ManualClock(start)
        let org = SimulatedClaudeOrg(clock: clock)
        await org.configure { $0.propagationMillis = 1_500 }
        await org.link()
        var fresh = LinkState()
        fresh.apply(.linkCompleted, at: start)
        let (gateway, _, _, sleeper) = make(clock: clock, org: org, link: fresh)
        let result = await gateway.send(request())
        let profile = try XCTUnwrap(self.profile)
        guard case .served(_, .customer(profile), _, _) = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(sleeper.requestedWaits, [2_000])
        XCTAssertEqual(result.attempts.count, 2)
    }

    func testASecondWarmUpRefusalStopsTryingTheCustomerForThatRequest() async {
        let clock = ManualClock(start)
        let org = SimulatedClaudeOrg(clock: clock)
        await org.configure { $0.propagationMillis = 9_000 }
        await org.link()
        var fresh = LinkState()
        fresh.apply(.linkCompleted, at: start)
        let (gateway, _, _, _) = make(clock: clock, org: org, link: fresh)
        let result = await gateway.send(request())
        XCTAssertEqual(result.attempts.map { $0.decision.payer?.isCustomer }, [true, true, false])
        guard case .served(_, .app, _, _) = result.outcome else { return XCTFail("\(result.outcome)") }
        // The shared state is still warming up: the next request tries the customer again.
        guard case .linked(.warmingUp) = await gateway.link.phase else { return XCTFail() }
    }

    func testAProbeLostToATransportErrorFreesTheSlot() async {
        var degraded = linkedState(at: start)
        degraded.apply(.customerRefused(.billingUnavailable, ticket: degraded.issueTicket()), at: start - 31 * 60_000)
        let (gateway, _, clock, _) = make(link: degraded, transport: ScriptedTransport([]))
        XCTAssertEqual(degraded.admission(at: clock.now()), .probe)
        let result = await gateway.send(request())
        XCTAssertEqual(result.outcome, .failed(.transportFailed))
        // Without the abandon event the lost probe would block the next one for 2 min.
        let link = await gateway.link
        XCTAssertEqual(link.admission(at: clock.now()), .probe)
    }

    func testOverloadedHonoursRetryAfterAndRetriesTheSamePayer() async {
        let clock = ManualClock(start)
        let org = SimulatedClaudeOrg(clock: clock)
        await org.link()
        await org.configure { $0.overloadNext = 1; $0.overloadRetryAfterSeconds = 3 }
        let (gateway, _, _, sleeper) = make(clock: clock, org: org)
        let result = await gateway.send(request())
        XCTAssertEqual(sleeper.requestedWaits, [3_000])
        XCTAssertEqual(result.attempts.map { $0.decision.payer?.isCustomer }, [true, true])
        guard case .served(_, .customer, _, _) = result.outcome else { return XCTFail("\(result.outcome)") }
    }

    func testOverloadWithoutRetryAfterBacksOffAndGivesUp() async {
        let clock = ManualClock(start)
        let org = SimulatedClaudeOrg(clock: clock)
        await org.link()
        await org.configure { $0.overloadNext = 10; $0.overloadRetryAfterSeconds = nil }
        let (gateway, _, _, sleeper) = make(clock: clock, org: org)
        let result = await gateway.send(request())
        XCTAssertEqual(result.outcome, .failed(.overloaded))
        XCTAssertEqual(sleeper.requestedWaits, [500, 1_000])
        let received = await org.received.count
        XCTAssertEqual(received, 3)
    }

    func testACallerBugIsNotMaskedByFallingBackToTheApp() async {
        let transport = ScriptedTransport([.refused(.userProfileRequired, partialReply: nil)])
        let (gateway, _, _, _) = make(transport: transport)
        let result = await gateway.send(request())
        XCTAssertEqual(result.outcome, .failed(.rejected(.userProfileRequired)))
        let calls = await transport.callCount
        XCTAssertEqual(calls, 1)
        let phaseNow = await gateway.link.phase
        XCTAssertEqual(phaseNow, .linked(.billable))
    }

    func testATransportFailureIsNotRetriedAndIsRecordedAsUnknown() async {
        let transport = ScriptedTransport([])
        let (gateway, _, _, _) = make(transport: transport)
        let result = await gateway.send(request())
        XCTAssertEqual(result.outcome, .failed(.transportFailed))
        let calls = await transport.callCount
        XCTAssertEqual(calls, 1)
        let totals = await gateway.ledger.totals(for: BillingMonth(containing: start))
        XCTAssertEqual(totals.unknownOutcomes, 1)
        XCTAssertEqual(totals.customerBilled, .zero)
    }

    func testAMidReplyBillingFailureDiscardsThePartialAndRestartsOnTheApp() async {
        let clock = ManualClock(start)
        let org = SimulatedClaudeOrg(clock: clock)
        await org.link()
        await org.configure { $0.failNextMidReply = true }
        let (gateway, _, _, _) = make(clock: clock, org: org)
        let result = await gateway.send(request())
        XCTAssertEqual(result.attempts.first?.result, .refused(.billingUnavailable, discardedPartialReply: true))
        guard case .served(_, .app, "small", _) = result.outcome else { return XCTFail("\(result.outcome)") }
    }

    func testAnAppSideRefusalNeverTouchesTheCustomersLink() async {
        let clock = ManualClock(start)
        let org = SimulatedClaudeOrg(clock: clock)
        await org.link()
        await org.configure { $0.appRefusal = .spendLimitReached }
        // A healthy link, and an app-operational feature: the app pays, and its own
        // org refuses. That says nothing about the customer.
        let (gateway, _, _, _) = make(clock: clock, org: org)
        let ops = FeatureDescriptor(id: "ops", displayName: "Ops", billing: .appOperational, model: "small")
        let result = await gateway.send(InferenceRequest(feature: ops, estimate: MicroUSD(10_000), prompt: "p"))
        XCTAssertEqual(result.outcome, .failed(.rejected(.spendLimitReached)))
        let phaseNow = await gateway.link.phase
        XCTAssertEqual(phaseNow, .linked(.billable))
        let reserved = await gateway.ledger.reservationCount
        XCTAssertEqual(reserved, 0)
    }

    func testAWarmUpRefusalDoesNotRecommendAStatusRead() async {
        let clock = ManualClock(start)
        let org = SimulatedClaudeOrg(clock: clock)
        await org.configure { $0.propagationMillis = 1_500 }
        await org.link()
        var fresh = LinkState()
        fresh.apply(.linkCompleted, at: start)
        let (gateway, _, _, _) = make(clock: clock, org: org, link: fresh)
        let result = await gateway.send(request())
        XCTAssertEqual(result.attempts.first?.result, .refused(.notBillable, discardedPartialReply: false))
        XCTAssertFalse(result.statusCheckRecommended)
    }

    func testNotBillableRecommendsAStatusRead() async {
        let clock = ManualClock(start)
        let org = SimulatedClaudeOrg(clock: clock) // never linked on the server side
        let (gateway, _, _, _) = make(clock: clock, org: org)
        let result = await gateway.send(request())
        XCTAssertTrue(result.statusCheckRecommended)
        guard case .linked(.notBillable) = await gateway.link.phase else { return XCTFail() }
    }

    func testPausedRequestsAreNeverSent() async {
        let clock = ManualClock(start)
        let org = SimulatedClaudeOrg(clock: clock)
        let (gateway, _, _, _) = make(clock: clock, org: org, link: LinkState(), plan: .noSubscription)
        let result = await gateway.send(request())
        XCTAssertEqual(result.outcome, .paused(.customerUnavailable(.notLinked)))
        let received = await org.received.count
        XCTAssertEqual(received, 0)
    }

    func testACancelledTaskStopsBeforeSending() async {
        let clock = ManualClock(start)
        let org = SimulatedClaudeOrg(clock: clock)
        let (gateway, _, _, _) = make(clock: clock, org: org)
        let task = Task { [req = request()] () -> GatewayResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return await gateway.send(req)
        }
        let result = await task.value
        XCTAssertEqual(result.outcome, .failed(.cancelled))
        let received = await org.received.count
        XCTAssertEqual(received, 0)
    }

    // MARK: Reentrancy across the transport suspension point

    func testAStaleRefusalArrivingAfterANewerSuccessIsIgnored() async throws {
        let transport = ControlledTransport()
        let (gateway, _, _, _) = make(transport: transport)

        let older = Task { [req = request()] in await gateway.send(req) }
        await waitForPending(transport, 1)
        let newer = Task { [req = request()] in await gateway.send(req) }
        await waitForPending(transport, 2)

        // The newer call succeeds first.
        await expectResolved(transport, customer: true, with: .success(cost: MicroUSD(1), text: "ok"), newest: true)
        _ = await newer.value

        // The older call's refusal lands afterwards. It was issued before the success,
        // so it is stale evidence and must not degrade the link.
        await expectResolved(transport, customer: true, with: .refused(.spendLimitReached, partialReply: nil))
        // The older request re-routes (still to the customer) and completes.
        await waitForPending(transport, 1)
        await expectResolved(transport, customer: true, with: .success(cost: MicroUSD(1), text: "ok"))
        _ = await older.value
        let phaseNow = await gateway.link.phase
        XCTAssertEqual(phaseNow, .linked(.billable))
    }

    func testAStaleSuccessArrivingAfterANewerRefusalIsIgnored() async throws {
        let transport = ControlledTransport()
        let (gateway, _, _, _) = make(transport: transport)

        let older = Task { [req = request()] in await gateway.send(req) }
        await waitForPending(transport, 1)
        let newer = Task { [req = request()] in await gateway.send(req) }
        await waitForPending(transport, 2)

        // The newer call is refused first and degrades the link.
        await expectResolved(transport, customer: true, with: .refused(.spendLimitReached, partialReply: nil), newest: true)
        await waitForPending(transport, 2) // newer re-routed to app
        await expectResolved(transport, customer: false, with: .success(cost: MicroUSD(1), text: "ok"))
        _ = await newer.value
        guard case .linked(.spendLimitReached) = await gateway.link.phase else { return XCTFail() }

        // Now the OLDER call's success lands. It was issued before the refusal.
        await expectResolved(transport, customer: true, with: .success(cost: MicroUSD(1), text: "ok"))
        _ = await older.value
        guard case .linked(.spendLimitReached) = await gateway.link.phase else {
            return XCTFail("a stale success un-degraded the link")
        }
    }

    func testConcurrentSubsidyRequestsCannotOvershootTheBudget() async {
        let transport = ControlledTransport()
        // Budget fits exactly one $0.10 subsidised request.
        let (gateway, _, _, _) = make(link: LinkState(), policy: RoutingPolicy(subsidyPerMonth: MicroUSD(100_000)),
                                      transport: transport)
        let first = Task { [req = request()] in await gateway.send(req) }
        await waitForPending(transport, 1)
        // The first request is in flight: nothing spent yet, but its reservation is held.
        let second = Task { [req = request()] in await gateway.send(req) }
        for _ in 0..<500 { await Task.yield() }
        let inFlight = await transport.pendingCount
        XCTAssertEqual(inFlight, 1, "the second request must pause, not reach the transport")
        await expectResolved(transport, customer: false, with: .success(cost: MicroUSD(100_000), text: "ok"))
        if inFlight > 1 { await transport.drain() }
        let secondResult = await second.value
        XCTAssertEqual(secondResult.outcome, .paused(.subsidyBudgetExhausted(.notLinked)))
        guard case .served = await first.value.outcome else { return XCTFail() }
    }

    func testOnlyOneConcurrentRequestBecomesTheProbe() async {
        let transport = ControlledTransport()
        var degraded = linkedState(at: start)
        degraded.apply(.customerRefused(.billingUnavailable, ticket: degraded.issueTicket()), at: start - 31 * 60_000)
        let (gateway, _, _, _) = make(link: degraded, transport: transport)
        let probe = Task { [req = request()] in await gateway.send(req) }
        await waitForPending(transport, 1)
        let other = Task { [req = request()] in await gateway.send(req) }
        await waitForPending(transport, 2)
        let calls = await transport.calls
        XCTAssertEqual(calls.map { $0.payer.isCustomer }, [true, false]) // second one subsidised
        await expectResolved(transport, customer: true, with: .success(cost: MicroUSD(1), text: "ok"))
        await expectResolved(transport, customer: false, with: .success(cost: MicroUSD(1), text: "ok"))
        _ = await probe.value
        _ = await other.value
        let phaseNow = await gateway.link.phase
        XCTAssertEqual(phaseNow, .linked(.billable))
    }
}

extension ControlledTransport {
    /// Resolve the newest pending call whose payer matches.
    func resolveNewest(customer: Bool, with result: TransportResult) -> Bool {
        guard let index = pending.lastIndex(where: { $0.call.payer.isCustomer == customer }) else {
            drain()
            return false
        }
        let item = pending.remove(at: index)
        item.continuation.resume(returning: result)
        return true
    }
}

/// Returns scripted results in order; throws once the script runs out.
actor ScriptedTransport: MessagesTransport {
    private var script: [TransportResult]
    private(set) var callCount = 0
    struct Exhausted: Error {}

    init(_ script: [TransportResult]) { self.script = script }

    func send(_ request: InferenceRequest, payer: Payer, model: ModelID) async throws -> TransportResult {
        callCount += 1
        guard !script.isEmpty else { throw Exhausted() }
        return script.removeFirst()
    }
}
