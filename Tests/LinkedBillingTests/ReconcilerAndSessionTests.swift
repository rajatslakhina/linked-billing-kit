import Foundation
import XCTest
@testable import LinkedBilling
import LinkedBillingTesting

/// A status source whose reads suspend until the test releases them.
actor ControlledStatusSource: ConnectionStatusSource {
    private var waiting: [CheckedContinuation<ConnectionStatus, Error>] = []
    private(set) var reads = 0

    func fetchStatus(for profile: UserProfileID) async throws -> ConnectionStatus {
        reads += 1
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }

    var waitingCount: Int { waiting.count }

    func release(_ status: ConnectionStatus) {
        let all = waiting
        waiting.removeAll()
        for continuation in all { continuation.resume(returning: status) }
    }
}

final class ConnectionReconcilerTests: XCTestCase {
    let start = BillingMonth.epochMillis(year: 2026, month: 11, day: 10, hour: 9)
    let profile = UserProfileID("uprof_acme")

    private func gateway(link: LinkState = LinkState(), clock: ManualClock) -> LinkedBillingGateway {
        LinkedBillingGateway(profile: profile, link: link, policy: RoutingPolicy(subsidyPerMonth: .zero),
                             transport: ScriptedTransport([]), clock: clock, sleeper: AdvancingSleeper(clock: clock))
    }

    func testConcurrentReconcilesShareOneRead() async {
        let clock = ManualClock(start)
        let source = ControlledStatusSource()
        let reconciler = ConnectionReconciler(gateway: gateway(clock: clock), source: source)
        let a = Task { await reconciler.reconcileNow() }
        await waitUntil { await source.waitingCount == 1 }
        let b = Task { await reconciler.reconcileNow() }
        let c = Task { await reconciler.reconcileNow() }
        await settle()
        await source.release(.connected)
        // If single-flight were broken, a late duplicate read could still be waiting;
        // release again so the test fails on its assertions instead of hanging.
        await settle()
        await source.release(.connected)
        let results = [await a.value, await b.value, await c.value]
        let reads = await source.reads
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(Set(results), [.observed(.connected, phaseChanged: true)])
    }

    func testAFreshReconcileWaitsOutAnOlderReadAndReadsAgain() async {
        let clock = ManualClock(start)
        let source = ControlledStatusSource()
        let reconciler = ConnectionReconciler(gateway: gateway(clock: clock), source: source)
        let older = Task { await reconciler.reconcileNow() }
        await waitUntil { await source.waitingCount == 1 }
        let fresh = Task { await reconciler.reconcileNow(fresh: true) }
        await settle()
        await source.release(.notConnected)             // the older read lands
        await waitUntil { await source.waitingCount == 1 } // the fresh one starts its own read
        await source.release(.connected)
        let olderResult = await older.value
        let freshResult = await fresh.value
        XCTAssertEqual(olderResult, .observed(.notConnected, phaseChanged: false))
        XCTAssertEqual(freshResult, .observed(.connected, phaseChanged: true))
        let reads = await source.reads
        XCTAssertEqual(reads, 2)
    }

    func testAReadThatStartedBeforeTheUserLinkedCannotRevertTheLink() async {
        let clock = ManualClock(start)
        let source = ControlledStatusSource()
        let gw = gateway(clock: clock)
        let reconciler = ConnectionReconciler(gateway: gw, source: source)
        await gw.apply(.linkStarted)
        let read = Task { await reconciler.reconcileNow() }
        await waitUntil { await source.waitingCount == 1 }  // read is in flight
        await gw.apply(.linkCompleted)                       // user finishes OAuth meanwhile
        await source.release(.notConnected)                  // the old answer lands
        let readResult = await read.value
        XCTAssertEqual(readResult, .observed(.notConnected, phaseChanged: false))
        guard case .linked = await gw.link.phase else { return XCTFail("stale read reverted the new link") }
    }

    func testTheFirstReadAfterAnAbandonedFlowCounts() async {
        // The customer finished linking elsewhere, but this app never applied
        // `.linkCompleted`. The flow expires; the next read must still link the profile.
        let clock = ManualClock(start)
        let org = SimulatedClaudeOrg(clock: clock)
        await org.link()
        let gw = gateway(clock: clock)
        let reconciler = ConnectionReconciler(gateway: gw, source: org)
        await gw.apply(.linkStarted)
        clock.advance(by: 11 * 60_000)
        let result = await reconciler.reconcileNow()
        XCTAssertEqual(result, .observed(.connected, phaseChanged: true))
        let phase = await gw.currentPhase()
        XCTAssertEqual(phase, .linked(.billable))
    }

    func testThePollingDelayWakesAtAPendingFlowsExpiry() async {
        let clock = ManualClock(start)
        let gw = gateway(clock: clock)
        let reconciler = ConnectionReconciler(gateway: gw, source: ControlledStatusSource())
        await gw.apply(.linkStarted)
        clock.advance(by: 4 * 60_000)
        let pending = await reconciler.nextDelay(jitterDraw: 0)
        XCTAssertEqual(pending, 6 * 60_000 + 1_000) // not the 24 h pending cadence
        clock.advance(by: 6 * 60_000)
        let expired = await reconciler.nextDelay(jitterDraw: 0)
        XCTAssertGreaterThan(expired, 20 * 3_600_000) // expired: back to the idle cadence
    }

    func testLinkCancelledTakesAFreshReadAfterTheCancel() async {
        // A `connected` read issued before the flow started is stale once the flow
        // starts; `linkCancelled()` replaces it with a read issued after the cancel.
        let clock = ManualClock(start)
        let source = ControlledStatusSource()
        let gw = gateway(clock: clock)
        let reconciler = ConnectionReconciler(gateway: gw, source: source)
        let early = Task { await reconciler.reconcileNow() }
        await waitUntil { await source.waitingCount == 1 }
        await gw.apply(.linkStarted)
        await source.release(.connected)                      // stale: issued before the start
        _ = await early.value
        let cancelled = Task { await reconciler.linkCancelled() }
        await waitUntil { await source.waitingCount == 1 }    // the fresh read
        await source.release(.connected)
        let result = await cancelled.value
        XCTAssertEqual(result, .observed(.connected, phaseChanged: true))
        let phase = await gw.currentPhase()
        XCTAssertEqual(phase, .linked(.billable))
    }

    func testAnUnlinkWithNoWebhookIsDiscoveredByTheRead() async throws {
        let clock = ManualClock(start)
        let org = SimulatedClaudeOrg(clock: clock)
        await org.link()
        var linked = LinkState()
        linked.apply(.linkCompleted, at: start - 60_000)
        let gw = gateway(link: linked, clock: clock)
        let reconciler = ConnectionReconciler(gateway: gw, source: org)
        await org.unlink(reason: .revokedByAdmin)
        let result = await reconciler.reconcileNow()
        XCTAssertEqual(result, .observed(.disconnected(revokedAt: nil, reason: .revokedByAdmin), phaseChanged: true))
        let phaseAfterRead = await gw.link.phase
        XCTAssertEqual(phaseAfterRead, .unlinked(reason: .revokedByAdmin, detectedAt: start))
    }

    func testFailedReadsCountUpAndResetOnSuccess() async {
        let clock = ManualClock(start)
        let org = SimulatedClaudeOrg(clock: clock)
        await org.configure { $0.failStatusReads = 2 }
        let reconciler = ConnectionReconciler(gateway: gateway(clock: clock), source: org)
        let first = await reconciler.reconcileNow()
        let second = await reconciler.reconcileNow()
        XCTAssertEqual(first, .failed(consecutiveFailures: 1))
        XCTAssertEqual(second, .failed(consecutiveFailures: 2))
        let delay = await reconciler.nextDelay(jitterDraw: 0)
        XCTAssertEqual(delay, 60_000 - 6_000) // 30 s × 2, minus 10% jitter at draw 0
        _ = await reconciler.reconcileNow()
        let failures = await reconciler.consecutiveFailures
        XCTAssertEqual(failures, 0)
    }

    func testNoProfileMeansNothingToReconcile() async {
        let clock = ManualClock(start)
        let gw = LinkedBillingGateway(profile: nil, policy: RoutingPolicy(subsidyPerMonth: .zero),
                                      transport: ScriptedTransport([]), clock: clock, sleeper: AdvancingSleeper(clock: clock))
        let source = ControlledStatusSource()
        let result = await ConnectionReconciler(gateway: gw, source: source).reconcileNow()
        XCTAssertEqual(result, .notLinkable)
        let reads = await source.reads
        XCTAssertEqual(reads, 0)
    }
}

final class PollScheduleTests: XCTestCase {
    let schedule = PollSchedule()

    func testCadenceFollowsThePhase() {
        func band(_ phase: LinkPhase) -> ClosedRange<Int64> {
            let base: Int64
            switch phase {
            case .linkPending: base = 86_400_000
            case .linked(.notBillable): base = 300_000
            case .linked: base = 21_600_000
            case .notLinked, .unlinked: base = 86_400_000
            }
            return (base - base / 10)...(base + base / 10)
        }
        let phases: [LinkPhase] = [.linkPending(startedAt: 0), .linked(.notBillable(nextProbeAt: 0)),
                                   .linked(.billable), .linked(.spendLimitReached(resetsAt: 0, nextProbeAt: 0)),
                                   .notLinked, .unlinked(reason: nil, detectedAt: 0)]
        for phase in phases {
            for draw in [UInt64(0), 1, .max, 123_456_789] {
                XCTAssertTrue(band(phase).contains(schedule.delay(for: phase, consecutiveFailures: 0, jitterDraw: draw)), "\(phase)")
            }
        }
    }

    func testJitterSpreadsAFleetAcrossTheBand() {
        let delays = Set((0..<200).map { schedule.delay(for: .linked(.billable), consecutiveFailures: 0, jitterDraw: UInt64($0) &* 2_654_435_761) })
        XCTAssertGreaterThan(delays.count, 150)
    }

    func testFailureBackoffDoublesAndCaps() {
        let noJitter = { (failures: Int) in
            // Draw = span gives offset 0 for this base.
            let base = min(Int64(30_000) << Int64(min(failures - 1, 20)), 3_600_000)
            return self.schedule.delay(for: .linked(.billable), consecutiveFailures: failures, jitterDraw: UInt64(base / 10))
        }
        XCTAssertEqual(noJitter(1), 30_000)
        XCTAssertEqual(noJitter(2), 60_000)
        XCTAssertEqual(noJitter(3), 120_000)
        XCTAssertEqual(noJitter(20), 3_600_000)
        XCTAssertEqual(noJitter(1_000), 3_600_000)
    }

    func testHostileConfigurationDoesNotTrap() {
        var hostile = PollSchedule()
        hostile.linkedMillis = .max
        hostile.idleMillis = .min
        hostile.failureBaseMillis = .max
        hostile.failureMaxMillis = .max
        XCTAssertGreaterThan(hostile.delay(for: .linked(.billable), consecutiveFailures: 0, jitterDraw: .max), 0)
        XCTAssertEqual(hostile.delay(for: .notLinked, consecutiveFailures: 0, jitterDraw: .max), 1)
        XCTAssertGreaterThan(hostile.delay(for: .notLinked, consecutiveFailures: .max, jitterDraw: .max), 0)
    }
}

final class LinkSessionTests: XCTestCase {
    let state = "s_" + String(repeating: "Ab3x", count: 6)
    let redirect = LinkSession.Redirect(scheme: "https", host: "app.example.com", path: "/claude/billing/callback")
    let authorize = URL(string: "https://auth.claude.com/oauth/authorize?request_uri=urn:x")

    private func session(at createdAt: EpochMillis = 1_000) throws -> LinkSession {
        try LinkSession(authorizeURL: XCTUnwrap(authorize), state: state, redirect: redirect, createdAt: createdAt)
    }

    private func callback(_ query: String) throws -> URL {
        try XCTUnwrap(URL(string: "https://app.example.com/claude/billing/callback?\(query)"))
    }

    func testTheAuthorizeURLMustBeHTTPSOnAnAllowedHost() throws {
        XCTAssertThrowsError(try LinkSession(authorizeURL: XCTUnwrap(URL(string: "http://auth.claude.com/x")),
                                             state: state, redirect: redirect, createdAt: 0)) {
            XCTAssertEqual($0 as? LinkSession.StartError, .insecureScheme)
        }
        XCTAssertThrowsError(try LinkSession(authorizeURL: XCTUnwrap(URL(string: "https://auth.claude.com.evil.example/x")),
                                             state: state, redirect: redirect, createdAt: 0)) {
            XCTAssertEqual($0 as? LinkSession.StartError, .hostNotAllowed("auth.claude.com.evil.example"))
        }
        XCTAssertThrowsError(try LinkSession(authorizeURL: XCTUnwrap(authorize), state: "short",
                                             redirect: redirect, createdAt: 0)) {
            XCTAssertEqual($0 as? LinkSession.StartError, .stateTooShort)
        }
    }

    func testAValidCallbackYieldsTheCodeExactlyOnce() throws {
        let session = try session()
        XCTAssertEqual(session.handleCallback(try callback("code=abc&state=\(state)"), at: 2_000), .code("abc"))
        XCTAssertEqual(session.handleCallback(try callback("code=abc&state=\(state)"), at: 2_001), .rejected(.alreadyUsed))
    }

    func testAForgedStateIsRejectedWithoutCancellingTheRealFlow() throws {
        let session = try session()
        XCTAssertEqual(session.handleCallback(try callback("code=evil&state=s_wrong"), at: 2_000), .rejected(.stateMismatch))
        XCTAssertEqual(session.handleCallback(try callback("code=good&state=\(state)"), at: 2_001), .code("good"))
    }

    func testDuplicateParametersAreRejected() throws {
        let session = try session()
        XCTAssertEqual(session.handleCallback(try callback("code=a&state=\(state)&state=\(state)"), at: 2_000),
                       .rejected(.duplicateParameter))
        XCTAssertEqual(session.handleCallback(try callback("code=a&code=b&state=\(state)"), at: 2_001),
                       .rejected(.duplicateParameter))
        XCTAssertEqual(session.handleCallback(try callback("error=x&error=y&state=\(state)"), at: 2_002),
                       .rejected(.duplicateParameter))
        // None of those consumed the session.
        XCTAssertEqual(session.handleCallback(try callback("code=ok&state=\(state)"), at: 2_003), .code("ok"))
    }

    func testAnExpiredCallbackIsRejectedAndConsumesTheSession() throws {
        let session = try session(at: 1_000)
        XCTAssertEqual(session.handleCallback(try callback("code=a&state=\(state)"), at: 1_000 + 10 * 60_000 + 1),
                       .rejected(.expired))
        XCTAssertEqual(session.handleCallback(try callback("code=a&state=\(state)"), at: 2_000), .rejected(.alreadyUsed))
        // Earlier than createdAt by more than the 60 s skew tolerance.
        let early = try self.session(at: 100_000)
        XCTAssertEqual(early.handleCallback(try callback("code=a&state=\(state)"), at: 100_000 - 60_001), .rejected(.expired))
    }

    func testASmallClockAdjustmentIsTolerated() throws {
        let session = try session(at: 100_000)
        XCTAssertEqual(session.handleCallback(try callback("code=a&state=\(state)"), at: 100_000 - 59_000), .code("a"))
    }

    func testAForgedCallbackDuringClockSkewDoesNotBurnTheSession() throws {
        let session = try session(at: 5_000)
        // The device clock reads earlier than the session's creation time.
        XCTAssertEqual(session.handleCallback(try callback("code=evil&state=s_wrong"), at: 4_000), .rejected(.stateMismatch))
        XCTAssertEqual(session.handleCallback(try callback("code=good&state=\(state)"), at: 6_000), .code("good"))
    }

    func testCancelAndRedirectMismatchAreReported() throws {
        let session = try session()
        let other = try XCTUnwrap(URL(string: "https://evil.example/claude/billing/callback?code=a&state=\(state)"))
        XCTAssertEqual(session.handleCallback(other, at: 2_000), .rejected(.redirectMismatch))
        XCTAssertEqual(session.handleCallback(try callback("error=access_denied&state=\(state)"), at: 2_000),
                       .denied(error: "access_denied"))
    }

    func testAMissingCodeIsRejected() throws {
        let session = try session()
        XCTAssertEqual(session.handleCallback(try callback("state=\(state)"), at: 2_000), .rejected(.missingCode))
    }

    func testConstantTimeEqualsComparesWholeStrings() {
        XCTAssertTrue(LinkSession.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(LinkSession.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(LinkSession.constantTimeEquals("abc", "xbc"))
        XCTAssertFalse(LinkSession.constantTimeEquals("abc", "abcd"))
        XCTAssertTrue(LinkSession.constantTimeEquals("", ""))
    }
}
