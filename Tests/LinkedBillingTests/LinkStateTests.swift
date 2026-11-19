import XCTest
@testable import LinkedBilling

final class LinkStateTests: XCTestCase {
    let t0: EpochMillis = BillingMonth.epochMillis(year: 2026, month: 11, day: 10, hour: 12)

    /// A link that finished warming up and is billable at `t0`.
    private func billableLink(policy: LinkPolicy = LinkPolicy()) -> LinkState {
        var state = LinkState(policy: policy)
        state.apply(.linkStarted, at: t0 - 60_000)
        state.apply(.linkCompleted, at: t0 - 50_000)
        let ticket = state.issueTicket()
        state.apply(.customerBilled(ticket: ticket), at: t0 - 40_000)
        XCTAssertEqual(state.phase, .linked(.billable))
        return state
    }

    // MARK: Lifecycle

    func testLinkCompletionStartsTheWarmUpWindowAndAdmitsTheCustomer() {
        var state = LinkState()
        XCTAssertEqual(state.admission(at: t0), .deny(.notLinked))
        state.apply(.linkStarted, at: t0)
        XCTAssertEqual(state.admission(at: t0), .deny(.linkInProgress))
        state.apply(.linkCompleted, at: t0)
        XCTAssertEqual(state.phase, .linked(.warmingUp(until: t0 + 10_000)))
        XCTAssertEqual(state.admission(at: t0), .admit)
    }

    func testCancellingAFirstLinkReturnsToNotLinkedButARelinkReturnsToUnlinked() {
        var fresh = LinkState()
        fresh.apply(.linkStarted, at: t0)
        fresh.apply(.linkCancelled, at: t0)
        XCTAssertEqual(fresh.phase, .notLinked)

        var relink = billableLink()
        relink.apply(.unlinkedByApp, at: t0)
        relink.apply(.linkStarted, at: t0 + 1)
        relink.apply(.linkCancelled, at: t0 + 2)
        XCTAssertEqual(relink.phase, .unlinked(reason: nil, detectedAt: t0 + 2))
    }

    func testStartingALinkWhileLinkedChangesNothing() {
        var state = billableLink()
        XCTAssertFalse(state.apply(.linkStarted, at: t0))
        XCTAssertEqual(state.phase, .linked(.billable))
    }

    // MARK: Invariant 1: stale results never cross a link/unlink action

    func testAStatusReadIssuedBeforeTheLinkCompletedCannotRevertIt() {
        var state = LinkState()
        state.apply(.linkStarted, at: t0)
        let read = state.issueTicket()          // poll starts while the user is in OAuth
        state.apply(.linkCompleted, at: t0 + 5) // user finishes; read still in flight
        state.apply(.statusObserved(.notConnected, ticket: read), at: t0 + 6)
        XCTAssertEqual(state.phase, .linked(.warmingUp(until: t0 + 5 + 10_000)))
    }

    func testAStatusReadIssuedAfterTheLinkIsApplied() {
        var state = billableLink()
        let read = state.issueTicket()
        state.apply(.statusObserved(.disconnected(revokedAt: nil, reason: .revokedByAdmin), ticket: read), at: t0)
        XCTAssertEqual(state.phase, .unlinked(reason: .revokedByAdmin, detectedAt: t0))
    }

    func testARefusalIssuedBeforeARelinkIsIgnored() {
        var state = billableLink()
        let oldRequest = state.issueTicket()
        state.apply(.unlinkedByApp, at: t0)
        state.apply(.linkCompleted, at: t0 + 1)
        let reWarm = state.phase
        state.apply(.customerRefused(.spendLimitReached, ticket: oldRequest), at: t0 + 2)
        XCTAssertEqual(state.phase, reWarm)
    }

    func testASuccessIssuedBeforeARelinkIsIgnored() {
        var state = billableLink()
        let oldRequest = state.issueTicket()
        state.apply(.unlinkedByApp, at: t0)
        state.apply(.linkCompleted, at: t0 + 1)              // relinked: warming up again
        state.apply(.customerBilled(ticket: oldRequest), at: t0 + 2)
        // The old success says nothing about the new connection's propagation.
        XCTAssertEqual(state.phase, .linked(.warmingUp(until: t0 + 1 + 10_000)))
    }

    // MARK: Invariant 2: the later-issued outcome wins

    func testALateSuccessFromBeforeTheRefusalDoesNotClearIt() {
        var state = billableLink()
        let early = state.issueTicket()
        let late = state.issueTicket()
        state.apply(.customerRefused(.spendLimitReached, ticket: late), at: t0)
        guard case .linked(.spendLimitReached) = state.phase else { return XCTFail("\(state.phase)") }
        state.apply(.customerBilled(ticket: early), at: t0 + 1)
        guard case .linked(.spendLimitReached) = state.phase else {
            return XCTFail("a success issued before the refusal un-degraded the link: \(state.phase)")
        }
    }

    func testALateRefusalFromBeforeARecoveryDoesNotReDegrade() {
        var state = billableLink()
        let first = state.issueTicket()
        state.apply(.customerRefused(.billingUnavailable, ticket: first), at: t0)
        let straggler = state.issueTicket()  // sent while degraded (e.g. by another path)
        let probe = state.issueTicket()
        XCTAssertTrue(state.beginProbe(ticket: probe, at: t0 + 31 * 60_000))
        state.apply(.customerBilled(ticket: probe), at: t0 + 31 * 60_000)
        XCTAssertEqual(state.phase, .linked(.billable))
        state.apply(.customerRefused(.billingUnavailable, ticket: straggler), at: t0 + 32 * 60_000)
        XCTAssertEqual(state.phase, .linked(.billable))
    }

    // MARK: Invariant 3: one probe at a time, and a lost probe expires

    func testOnlyOneProbeIsAdmittedAtATime() {
        var state = billableLink()
        state.apply(.customerRefused(.billingUnavailable, ticket: state.issueTicket()), at: t0)
        let due = t0 + 30 * 60_000
        XCTAssertEqual(state.admission(at: due - 1), .deny(.billingUnavailable))
        XCTAssertEqual(state.admission(at: due), .probe)
        let first = state.issueTicket()
        XCTAssertTrue(state.beginProbe(ticket: first, at: due))
        XCTAssertEqual(state.admission(at: due + 1), .deny(.billingUnavailable))
        XCTAssertFalse(state.beginProbe(ticket: state.issueTicket(), at: due + 1))
    }

    func testALostProbeStopsBlockingAfterTheTimeout() {
        var state = billableLink()
        state.apply(.customerRefused(.notBillable, ticket: state.issueTicket()), at: t0)
        let due = t0 + 30 * 60_000
        XCTAssertTrue(state.beginProbe(ticket: state.issueTicket(), at: due))
        XCTAssertEqual(state.admission(at: due + 10 * 60_000 - 1), .deny(.notBillable))
        XCTAssertEqual(state.admission(at: due + 10 * 60_000), .probe)
    }

    func testAStragglerRefusalDoesNotCancelTheProbeInFlight() {
        var state = billableLink()
        let first = state.issueTicket()
        let straggler = state.issueTicket()        // sent before the degradation
        state.apply(.customerRefused(.spendLimitReached, ticket: first), at: t0)
        let due = t0 + 15 * 60_000
        let probe = state.issueTicket()
        XCTAssertTrue(state.beginProbe(ticket: probe, at: due))
        state.apply(.customerRefused(.spendLimitReached, ticket: straggler), at: due + 1)
        XCTAssertTrue(state.probeInFlight)
        XCTAssertEqual(state.admission(at: due + 2).isProbe, false)
        // The probe's own refusal still counts toward the backoff (30 min, not 15).
        state.apply(.customerRefused(.spendLimitReached, ticket: probe), at: due + 3)
        guard case let .linked(.spendLimitReached(_, next)) = state.phase else { return XCTFail("\(state.phase)") }
        XCTAssertEqual(next, due + 3 + 30 * 60_000)
    }

    func testAnAbandonedProbeFreesTheSlotImmediately() {
        var state = billableLink()
        state.apply(.customerRefused(.notBillable, ticket: state.issueTicket()), at: t0)
        let due = t0 + 30 * 60_000
        let probe = state.issueTicket()
        XCTAssertTrue(state.beginProbe(ticket: probe, at: due))
        state.apply(.probeAbandoned(ticket: probe), at: due + 1)
        XCTAssertEqual(state.admission(at: due + 1), .probe)
    }

    func testAnOverloadedProbeAnswersNothingAndFreesTheSlot() {
        var state = billableLink()
        state.apply(.customerRefused(.notBillable, ticket: state.issueTicket()), at: t0)
        let due = t0 + 30 * 60_000
        let probe = state.issueTicket()
        XCTAssertTrue(state.beginProbe(ticket: probe, at: due))
        state.apply(.customerRefused(.overloaded(retryAfterSeconds: 1), ticket: probe), at: due + 1)
        guard case .linked(.notBillable) = state.phase else { return XCTFail("\(state.phase)") }
        XCTAssertEqual(state.admission(at: due + 1), .probe)
    }

    func testFailedProbesBackOffExponentiallyUpToTheCeiling() {
        var state = billableLink()
        var now = t0
        state.apply(.customerRefused(.billingUnavailable, ticket: state.issueTicket()), at: now)
        var intervals: [Int64] = []
        for _ in 0..<6 {
            guard case let .linked(.billingUnavailable(next)) = state.phase else { return XCTFail("\(state.phase)") }
            intervals.append(next - now)
            now = next
            let probe = state.issueTicket()
            XCTAssertTrue(state.beginProbe(ticket: probe, at: now))
            state.apply(.customerRefused(.billingUnavailable, ticket: probe), at: now)
        }
        let m: Int64 = 60_000
        XCTAssertEqual(intervals, [30 * m, 60 * m, 120 * m, 240 * m, 360 * m, 360 * m])
    }

    func testASuccessfulProbeResetsTheBackoff() {
        var state = billableLink()
        state.apply(.customerRefused(.billingUnavailable, ticket: state.issueTicket()), at: t0)
        let firstDue = t0 + 30 * 60_000
        let failed = state.issueTicket()
        XCTAssertTrue(state.beginProbe(ticket: failed, at: firstDue))
        state.apply(.customerRefused(.billingUnavailable, ticket: failed), at: firstDue)
        let secondDue = firstDue + 60 * 60_000
        let ok = state.issueTicket()
        XCTAssertTrue(state.beginProbe(ticket: ok, at: secondDue))
        state.apply(.customerBilled(ticket: ok), at: secondDue)
        state.apply(.customerRefused(.billingUnavailable, ticket: state.issueTicket()), at: secondDue + 1)
        XCTAssertEqual(state.phase, .linked(.billingUnavailable(nextProbeAt: secondDue + 1 + 30 * 60_000)))
    }

    // MARK: Invariant 4: spend-limit probing respects the UTC month boundary

    func testSpendLimitProbeIsNeverLaterThanTheMonthReset() {
        var state = billableLink()
        let lateOnTheLastDay = BillingMonth.epochMillis(year: 2026, month: 11, day: 30, hour: 23, minute: 55)
        state.apply(.customerRefused(.spendLimitReached, ticket: state.issueTicket()), at: lateOnTheLastDay)
        let reset = BillingMonth.epochMillis(year: 2026, month: 12, day: 1)
        XCTAssertEqual(state.phase, .linked(.spendLimitReached(resetsAt: reset, nextProbeAt: reset)))
        XCTAssertEqual(state.admission(at: reset - 1), .deny(.spendLimitReached(resetsAt: reset)))
        XCTAssertEqual(state.admission(at: reset), .probe)
    }

    func testASpendLimitSentBeforeMidnightResetsAtThatMidnight() {
        var state = billableLink()
        let sent = BillingMonth.epochMillis(year: 2026, month: 11, day: 30, hour: 23, minute: 59)
        let arrived = BillingMonth.epochMillis(year: 2026, month: 12, day: 1, hour: 0, minute: 1)
        state.apply(.customerRefused(.spendLimitReached, ticket: state.issueTicket(), sentAt: sent), at: arrived)
        let november = BillingMonth.epochMillis(year: 2026, month: 12, day: 1)
        XCTAssertEqual(state.phase, .linked(.spendLimitReached(resetsAt: november, nextProbeAt: november)))
        XCTAssertEqual(state.admission(at: arrived), .probe) // that cap already reset
    }

    func testSpendLimitProbesEarlyBecauseACapCanBeRaisedSilently() {
        var state = billableLink()
        state.apply(.customerRefused(.spendLimitReached, ticket: state.issueTicket()), at: t0)
        XCTAssertEqual(state.admission(at: t0 + 15 * 60_000), .probe)
    }

    // MARK: Invariant 5: status reads can't override request evidence

    func testUnknownStatusNeverChangesState() {
        for start in [LinkState(), billableLink()] {
            var state = start
            let before = state.phase
            XCTAssertFalse(state.apply(.statusObserved(.unknown, ticket: state.issueTicket()), at: t0))
            XCTAssertEqual(state.phase, before)
        }
    }

    func testConnectedDoesNotClearASpendLimit() {
        var state = billableLink()
        state.apply(.customerRefused(.spendLimitReached, ticket: state.issueTicket()), at: t0)
        let before = state.phase
        state.apply(.statusObserved(.connected, ticket: state.issueTicket()), at: t0 + 1)
        XCTAssertEqual(state.phase, before)
    }

    func testConnectedWhileUnlinkedMeansLinkedElsewhere() {
        var state = billableLink()
        state.apply(.unlinkedByApp, at: t0)
        state.apply(.statusObserved(.connected, ticket: state.issueTicket()), at: t0 + 1)
        XCTAssertEqual(state.phase, .linked(.billable))
    }

    func testDisconnectedDuringANewLinkFlowIsIgnored() {
        var state = billableLink()
        state.apply(.unlinkedByApp, at: t0)
        state.apply(.linkStarted, at: t0 + 1)
        state.apply(.statusObserved(.disconnected(revokedAt: nil, reason: .revokedByAppOwner), ticket: state.issueTicket()), at: t0 + 2)
        XCTAssertEqual(state.phase, .linkPending(startedAt: t0 + 1))
    }

    func testANegativeReadIssuedBeforeASuccessDoesNotUnlink() {
        var state = billableLink()
        let read = state.issueTicket()             // read starts
        let request = state.issueTicket()          // a request starts after it…
        state.apply(.customerBilled(ticket: request), at: t0)  // …and the org pays for it
        state.apply(.statusObserved(.disconnected(revokedAt: nil, reason: .other), ticket: read), at: t0 + 1)
        XCTAssertEqual(state.phase, .linked(.billable))
        state.apply(.statusObserved(.notConnected, ticket: read), at: t0 + 2)
        XCTAssertEqual(state.phase, .linked(.billable))
    }

    func testANegativeReadOlderThanA402DoesNotUnlink() {
        var state = billableLink()
        let read = state.issueTicket()
        let request = state.issueTicket()
        // The API checks the connection before the cap, so this 402 proves it was alive.
        state.apply(.customerRefused(.spendLimitReached, ticket: request), at: t0)
        state.apply(.statusObserved(.disconnected(revokedAt: nil, reason: .other), ticket: read), at: t0 + 1)
        guard case .linked(.spendLimitReached) = state.phase else { return XCTFail("\(state.phase)") }
    }

    func testANewerSuccessRestoresALinkThatAnOlderReadEnded() {
        var state = billableLink()
        let read = state.issueTicket()
        let request = state.issueTicket()
        // This time the stale read lands first…
        state.apply(.statusObserved(.disconnected(revokedAt: nil, reason: .other), ticket: read), at: t0)
        guard case .unlinked = state.phase else { return XCTFail("\(state.phase)") }
        // …and the newer request's success proves the connection was alive after it.
        state.apply(.customerBilled(ticket: request), at: t0 + 1)
        XCTAssertEqual(state.phase, .linked(.billable))
    }

    func testANewer402RestoresALinkThatAnOlderReadEndedThenApplies() {
        var state = billableLink()
        let read = state.issueTicket()
        let request = state.issueTicket()
        state.apply(.statusObserved(.notConnected, ticket: read), at: t0)
        XCTAssertEqual(state.phase, .notLinked)
        state.apply(.customerRefused(.spendLimitReached, ticket: request), at: t0 + 1)
        guard case .linked(.spendLimitReached) = state.phase else { return XCTFail("\(state.phase)") }
    }

    func testAStaleOutcomeThatDisprovesAnOlderReadKeepsANewerNotBillable() {
        // Read R, then requests A and B. Arrival: B (403), R (disconnected), A (success).
        var state = billableLink()
        let read = state.issueTicket()
        let a = state.issueTicket()
        let b = state.issueTicket()
        state.apply(.customerRefused(.notBillable, ticket: b), at: t0)
        state.apply(.statusObserved(.disconnected(revokedAt: nil, reason: .other), ticket: read), at: t0 + 1)
        state.apply(.customerBilled(ticket: a), at: t0 + 2)
        guard case .linked(.notBillable) = state.phase else { return XCTFail("\(state.phase)") }
    }

    func testTheSameThreeResultsInAnotherOrderEndTheSame() {
        // Arrival: B (403), A (success), R (disconnected).
        var state = billableLink()
        let read = state.issueTicket()
        let a = state.issueTicket()
        let b = state.issueTicket()
        state.apply(.customerRefused(.notBillable, ticket: b), at: t0)
        state.apply(.customerBilled(ticket: a), at: t0 + 1)
        state.apply(.statusObserved(.disconnected(revokedAt: nil, reason: .other), ticket: read), at: t0 + 2)
        guard case .linked(.notBillable) = state.phase else { return XCTFail("\(state.phase)") }
    }

    func testANewerNotBillableThatLandsWhileUnlinkedStillWinsOverAStaleSuccess() {
        // Read R, then requests A and B. Arrival: R (disconnected), B (403), A (success).
        var state = billableLink()
        let read = state.issueTicket()
        let a = state.issueTicket()
        let b = state.issueTicket()
        state.apply(.statusObserved(.disconnected(revokedAt: nil, reason: .other), ticket: read), at: t0)
        state.apply(.customerRefused(.notBillable, ticket: b), at: t0 + 1)
        state.apply(.customerBilled(ticket: a), at: t0 + 2)
        guard case .linked(.notBillable) = state.phase else { return XCTFail("\(state.phase)") }
    }

    func testANewerNegativeReadIsNotUndoneByAnOlderSuccess() {
        // Read R1, slow request S, polling read R2. Arrival: R1, R2, S, then R1, S, R2.
        for order in 0..<2 {
            var state = billableLink()
            let r1 = state.issueTicket()
            let slow = state.issueTicket()
            let r2 = state.issueTicket()
            let disconnected = ConnectionStatus.disconnected(revokedAt: nil, reason: .revokedByAdmin)
            state.apply(.statusObserved(disconnected, ticket: r1), at: t0)
            if order == 0 {
                state.apply(.statusObserved(disconnected, ticket: r2), at: t0 + 1)
                state.apply(.customerBilled(ticket: slow), at: t0 + 2)
            } else {
                state.apply(.customerBilled(ticket: slow), at: t0 + 1)
                state.apply(.statusObserved(disconnected, ticket: r2), at: t0 + 2)
            }
            guard case .unlinked(.revokedByAdmin?, _) = state.phase else { return XCTFail("order \(order): \(state.phase)") }
        }
    }

    func testAnOlderNegativeReadLandingLateDoesNotReplaceANewerOne() {
        // R1 < S < R2 by issue order. Arrival: R2, R1, S. The newest evidence is R2.
        var state = billableLink()
        let r1 = state.issueTicket()
        let slow = state.issueTicket()
        let r2 = state.issueTicket()
        state.apply(.statusObserved(.disconnected(revokedAt: nil, reason: .revokedByAdmin), ticket: r2), at: t0)
        state.apply(.statusObserved(.disconnected(revokedAt: nil, reason: .other), ticket: r1), at: t0 + 1)
        state.apply(.customerBilled(ticket: slow), at: t0 + 2)
        XCTAssertEqual(state.phase, .unlinked(reason: .revokedByAdmin, detectedAt: t0))
    }

    func testANewerConnectedReadOutvotesAnOlderNegativeRead() {
        var state = billableLink()
        let negative = state.issueTicket()
        let positive = state.issueTicket()
        state.apply(.statusObserved(.connected, ticket: positive), at: t0)
        state.apply(.statusObserved(.notConnected, ticket: negative), at: t0 + 1)
        XCTAssertEqual(state.phase, .linked(.billable))
    }

    func testAnOutcomeOlderThanTheReadDoesNotRestore() {
        var state = billableLink()
        let request = state.issueTicket()
        let read = state.issueTicket()
        state.apply(.statusObserved(.disconnected(revokedAt: nil, reason: .revokedByAdmin), ticket: read), at: t0)
        state.apply(.customerBilled(ticket: request), at: t0 + 1)
        XCTAssertEqual(state.phase, .unlinked(reason: .revokedByAdmin, detectedAt: t0))
    }

    func testAReadInFlightDuringALinkFlowIsStaleWhetherItLandsBeforeOrAfterCancel() {
        for status in [ConnectionStatus.connected, .disconnected(revokedAt: nil, reason: .other)] {
            var phases: [LinkPhase] = []
            for readFirst in [true, false] {
                var state = LinkState()
                state.apply(.linkStarted, at: t0)
                let read = state.issueTicket()
                if readFirst { state.apply(.statusObserved(status, ticket: read), at: t0 + 1) }
                state.apply(.linkCancelled, at: t0 + 2)
                if !readFirst { state.apply(.statusObserved(status, ticket: read), at: t0 + 3) }
                phases.append(state.phase)
            }
            // The read never changes base or health. A `disconnected` one still records
            // (in either order) that the profile was once linked, so the cancelled
            // flow reads as unlinked rather than never-linked.
            let expected: LinkPhase = status == .connected ? .notLinked : .unlinked(reason: nil, detectedAt: t0 + 2)
            XCTAssertEqual(phases, [expected, expected], "\(status)")
        }
    }

    func testPhaseAtNowShowsAnAbandonedFlowWithoutAnEvent() {
        var state = LinkState()
        state.apply(.linkStarted, at: t0)
        XCTAssertEqual(state.phase(at: t0 + 10 * 60_000 - 1), .linkPending(startedAt: t0))
        XCTAssertEqual(state.phase(at: t0 + 10 * 60_000), .notLinked)
        XCTAssertEqual(state.phase, .linkPending(startedAt: t0)) // unchanged until an event
    }

    func testAReadIssuedAfterAFlowExpiredCounts() {
        // The expiry is folded (and takes its ticket) before the read's ticket is issued,
        // so the first read after an abandoned flow is never thrown away.
        var state = LinkState()
        state.apply(.linkStarted, at: t0)
        let later = t0 + 11 * 60_000
        let read = state.issueTicket(at: later)
        XCTAssertTrue(state.apply(.statusObserved(.connected, ticket: read), at: later + 500))
        XCTAssertEqual(state.phase, .linked(.billable))
    }

    func testAReadIssuedBeforeAFlowExpiredIsStaleWheneverItLands() {
        for settledFirst in [false, true] {
            var state = LinkState()
            state.apply(.linkStarted, at: t0)
            let read = state.issueTicket(at: t0 + 60_000) // during the flow
            if settledFirst { state.settle(at: t0 + 10 * 60_000) }
            state.apply(.statusObserved(.connected, ticket: read), at: t0 + 10 * 60_000 + 1)
            XCTAssertEqual(state.phase, .notLinked, "settledFirst \(settledFirst)")
        }
    }

    func testRelinkingAfterAReadDetectedUnlinkStartsAPendingFlow() {
        // The unlink was found by a status read, so `base` is still linked; the relink
        // must not read as billable before the code exchange.
        let negative = ConnectionStatus.disconnected(revokedAt: nil, reason: .revokedByAdmin)
        var state = billableLink()
        state.apply(.statusObserved(negative, ticket: state.issueTicket()), at: t0)
        XCTAssertEqual(state.phase, .unlinked(reason: .revokedByAdmin, detectedAt: t0))
        state.apply(.linkStarted, at: t0 + 1)
        XCTAssertEqual(state.phase, .linkPending(startedAt: t0 + 1))
        XCTAssertEqual(state.admission(at: t0 + 1), .deny(.linkInProgress))

        var cancelled = state
        cancelled.apply(.linkCancelled, at: t0 + 2)
        XCTAssertEqual(cancelled.phase, .unlinked(reason: nil, detectedAt: t0 + 2))

        state.apply(.linkCompleted, at: t0 + 3)
        XCTAssertEqual(state.phase, .linked(.warmingUp(until: t0 + 3 + 10_000)))
    }

    func testANegativeReadInFlightAtAReapprovalNeverLeavesTheCustomerBilled() {
        // The read was issued before the user re-approved a link that read as linked.
        // Landing first, it unlinks and the start begins a flow; landing after, the start
        // leaves the link in place and the read unlinks it. Both deny the customer, and
        // completing, or cancelling and then reading afresh, gives one state.
        let cases: [(ConnectionStatus, LinkPhase)] = [
            (.disconnected(revokedAt: nil, reason: .revokedByAdmin), .unlinked(reason: .revokedByAdmin, detectedAt: t0 + 5)),
            (.notConnected, .notLinked),
        ]
        for (negative, settled) in cases {
            var completed: [LinkPhase] = []
            var reconciled: [LinkPhase] = []
            for readFirst in [true, false] {
                var state = billableLink()
                let read = state.issueTicket()
                if readFirst { state.apply(.statusObserved(negative, ticket: read), at: t0) }
                state.apply(.linkStarted, at: t0 + 1)
                if !readFirst { state.apply(.statusObserved(negative, ticket: read), at: t0) }
                guard case .deny = state.admission(at: t0 + 2) else {
                    return XCTFail("\(negative) readFirst \(readFirst): customer still admitted: \(state.phase)")
                }
                var done = state
                done.apply(.linkCompleted, at: t0 + 3)
                completed.append(done.phase)
                state.apply(.linkCancelled, at: t0 + 3)
                state.apply(.statusObserved(negative, ticket: state.issueTicket(at: t0 + 4)), at: t0 + 5)
                reconciled.append(state.phase)
            }
            XCTAssertEqual(completed, Array(repeating: .linked(.warmingUp(until: t0 + 3 + 10_000)), count: 2), "\(negative)")
            XCTAssertEqual(reconciled, [settled, settled], "\(negative)")
        }
    }

    func testAProbeRefusedInsideTheWarmUpFreesTheProbeSlot() {
        // Allowed by the policy clamps: a 1 s cap probe falls inside the 10 s warm-up.
        var state = LinkState(policy: LinkPolicy(capProbeMillis: 1_000))
        state.apply(.linkStarted, at: t0)
        state.apply(.linkCompleted, at: t0)
        state.apply(.customerRefused(.spendLimitReached, ticket: state.issueTicket(), sentAt: t0 + 1_000), at: t0 + 1_000)
        let probe = state.issueTicket()
        XCTAssertTrue(state.beginProbe(ticket: probe, at: t0 + 2_000))
        state.apply(.customerRefused(.notBillable, ticket: probe, sentAt: t0 + 2_000), at: t0 + 2_100)
        XCTAssertFalse(state.probeInFlight)
        XCTAssertEqual(state.admission(at: t0 + 2_100), .probe) // not blocked for probeTimeoutMillis
    }

    func testAConnectedReadAfterAReadDetectedUnlinkStartsTheNewConnectionFresh() {
        // A 403 reveals the unlink, a read confirms it, and the customer relinks somewhere
        // this state never sees; a later read says connected. Every arrival order must
        // give a billable link with no stale probe or backoff. `d` is a second 403 sent
        // between the two reads (the link was still down).
        let disconnected = ConnectionStatus.disconnected(revokedAt: nil, reason: .revokedByAdmin)
        let orders: [[Int]] = [[0, 1, 2, 3], [0, 1, 3, 2], [0, 3, 2, 1], [1, 2, 0, 3], [2, 1, 3, 0],
                               [3, 2, 1, 0], [2, 3, 0, 1], [1, 3, 0, 2]]
        for order in orders {
            var state = billableLink()
            let a = state.issueTicket(), b = state.issueTicket(), d = state.issueTicket(), c = state.issueTicket()
            let events: [LinkEvent] = [
                .customerRefused(.notBillable, ticket: a, sentAt: t0),
                .statusObserved(disconnected, ticket: b),
                .statusObserved(.connected, ticket: c),
                .customerRefused(.notBillable, ticket: d, sentAt: t0 + 1),
            ]
            for (offset, index) in order.enumerated() { state.apply(events[index], at: t0 + 10 + Int64(offset)) }
            XCTAssertEqual(state.phase, .linked(.billable), "order \(order)")
            XCTAssertEqual(state.admission(at: t0 + 20), .admit, "order \(order)")
            XCTAssertFalse(state.probeInFlight, "order \(order)")
            // The new connection's own outcomes still count, with a fresh backoff.
            state.apply(.customerRefused(.spendLimitReached, ticket: state.issueTicket()), at: t0 + 30)
            XCTAssertEqual(state.phase, .linked(.spendLimitReached(resetsAt: BillingMonth(containing: t0 + 30).end,
                                                                   nextProbeAt: t0 + 30 + 15 * 60_000)), "order \(order)")
        }
    }

    func testAConnectedReadWithoutANegativeReadKeepsRequestObservedHealth() {
        var state = billableLink()
        state.apply(.customerRefused(.notBillable, ticket: state.issueTicket()), at: t0)
        state.apply(.statusObserved(.connected, ticket: state.issueTicket()), at: t0 + 1)
        guard case .linked(.notBillable) = state.phase else { return XCTFail("\(state.phase)") }
    }

    func testAReapprovalDoesNotMakeInFlightRequestOutcomesStale() {
        var state = billableLink()
        let request = state.issueTicket()
        state.apply(.linkStarted, at: t0)                 // re-approval of a linked link: stays
        state.apply(.customerRefused(.spendLimitReached, ticket: request), at: t0 + 1)
        guard case .linked(.spendLimitReached) = state.phase else { return XCTFail("\(state.phase)") }
    }

    func testCancellingAfterADisconnectedReadGivesTheSameStateInAnyArrivalOrder() {
        // Read D (`disconnected`) is issued before the user taps Link, then Cancel.
        let negative = ConnectionStatus.disconnected(revokedAt: nil, reason: .revokedByAdmin)
        var phases: [LinkPhase] = []
        for landing in 0..<3 { // 0: before the start, 1: during the flow, 2: after the cancel
            var state = LinkState()
            let read = state.issueTicket()
            if landing == 0 { state.apply(.statusObserved(negative, ticket: read), at: t0) }
            state.apply(.linkStarted, at: t0 + 1)
            if landing == 1 { state.apply(.statusObserved(negative, ticket: read), at: t0 + 2) }
            state.apply(.linkCancelled, at: t0 + 3)
            if landing == 2 { state.apply(.statusObserved(negative, ticket: read), at: t0 + 4) }
            phases.append(state.phase)
        }
        XCTAssertEqual(phases, Array(repeating: .unlinked(reason: nil, detectedAt: t0 + 3), count: 3))
    }

    func testAnExpiredFlowAfterADisconnectedReadGivesTheSameStateInEitherOrder() {
        let negative = ConnectionStatus.disconnected(revokedAt: nil, reason: .other)
        let expiry = t0 + 1 + 10 * 60_000
        var phases: [LinkPhase] = []
        for readFirst in [true, false] {
            var state = LinkState()
            let read = state.issueTicket()
            state.apply(.linkStarted, at: t0 + 1)
            if readFirst { state.apply(.statusObserved(negative, ticket: read), at: t0 + 2) }
            state.settle(at: expiry + 5)
            if !readFirst { state.apply(.statusObserved(negative, ticket: read), at: expiry + 6) }
            phases.append(state.phase)
        }
        XCTAssertEqual(phases, [.unlinked(reason: nil, detectedAt: expiry), .unlinked(reason: nil, detectedAt: expiry)])
    }

    func testTheWarmUpEndsInPhaseAtNowWithoutAnEvent() {
        var state = LinkState()
        state.apply(.linkStarted, at: t0)
        state.apply(.linkCompleted, at: t0)
        XCTAssertEqual(state.phase(at: t0 + 9_999), .linked(.warmingUp(until: t0 + 10_000)))
        XCTAssertTrue(state.isWarmingUp(at: t0 + 9_999))
        XCTAssertEqual(state.phase(at: t0 + 10_000), .linked(.billable))
        XCTAssertFalse(state.isWarmingUp(at: t0 + 3_600_000))
    }

    func testAnAbandonedLinkFlowExpires() {
        var state = LinkState()
        state.apply(.linkStarted, at: t0)
        XCTAssertEqual(state.admission(at: t0 + 10 * 60_000 - 1), .deny(.linkInProgress))
        XCTAssertEqual(state.admission(at: t0 + 10 * 60_000), .deny(.notLinked))
        state.apply(.statusObserved(.unknown, ticket: state.issueTicket()), at: t0 + 10 * 60_000)
        XCTAssertEqual(state.phase, .notLinked)
    }

    func testNotConnectedAfterTheLinkMeansTheServerNeverSawIt() {
        var state = billableLink()
        state.apply(.statusObserved(.notConnected, ticket: state.issueTicket()), at: t0)
        XCTAssertEqual(state.phase, .notLinked)
    }

    // MARK: Warm-up

    func testNotBillableInsideTheWarmUpWindowDoesNotDegrade() {
        var state = LinkState()
        state.apply(.linkCompleted, at: t0)
        state.apply(.customerRefused(.notBillable, ticket: state.issueTicket()), at: t0 + 9_999)
        XCTAssertEqual(state.phase, .linked(.warmingUp(until: t0 + 10_000)))
        state.apply(.customerRefused(.notBillable, ticket: state.issueTicket()), at: t0 + 10_000)
        XCTAssertEqual(state.phase, .linked(.notBillable(nextProbeAt: t0 + 10_000 + 30 * 60_000)))
    }

    func testTheWarmUpWindowIsJudgedBySendTimeNotArrivalTime() {
        var state = LinkState()
        state.apply(.linkCompleted, at: t0)
        // Sent at 9.5 s, refused at 10.5 s: still inside the window that matters.
        state.apply(.customerRefused(.notBillable, ticket: state.issueTicket(), sentAt: t0 + 9_500), at: t0 + 10_500)
        XCTAssertEqual(state.phase, .linked(.warmingUp(until: t0 + 10_000)))
    }

    func testAWarmUpRefusalIsJudgedTheSameWhicheverOutcomeLandsFirst() {
        // Two requests inside the window: Q1 (issued first) and Q2 (403 not_billable).
        for q1 in [LinkEvent.customerBilled(ticket: Ticket(sequence: 0)), .customerRefused(.spendLimitReached, ticket: Ticket(sequence: 0))] {
            var phases: [LinkPhase] = []
            for q1First in [true, false] {
                var state = LinkState()
                state.apply(.linkCompleted, at: t0)
                let first = state.issueTicket()
                let second = state.issueTicket()
                let firstEvent: LinkEvent
                switch q1 {
                case .customerBilled: firstEvent = .customerBilled(ticket: first)
                default: firstEvent = .customerRefused(.spendLimitReached, ticket: first, sentAt: t0 + 1)
                }
                let secondEvent = LinkEvent.customerRefused(.notBillable, ticket: second, sentAt: t0 + 2)
                if q1First {
                    state.apply(firstEvent, at: t0 + 3); state.apply(secondEvent, at: t0 + 4)
                } else {
                    state.apply(secondEvent, at: t0 + 3); state.apply(firstEvent, at: t0 + 4)
                }
                phases.append(state.phase)
            }
            XCTAssertEqual(phases.count, 2)
            guard phases.count == 2 else { return }
            switch (phases[0], phases[1]) {
            case (.linked(.billable), .linked(.billable)), (.linked(.spendLimitReached), .linked(.spendLimitReached)):
                break
            default:
                XCTFail("arrival order changed the result: \(phases)")
            }
        }
    }

    func testOtherRefusalsDegradeEvenDuringWarmUp() {
        var state = LinkState()
        state.apply(.linkCompleted, at: t0)
        state.apply(.customerRefused(.spendLimitReached, ticket: state.issueTicket()), at: t0 + 1)
        guard case .linked(.spendLimitReached) = state.phase else { return XCTFail("\(state.phase)") }
    }

    func testCallerBugsAndUnknownErrorsNeverChangeLinkHealth() {
        var state = billableLink()
        for refusal: BillingRefusal in [.userProfileRequired, .invalidRequest(code: nil),
                                        .other(status: 403, type: "permission_error", code: nil),
                                        .overloaded(retryAfterSeconds: nil)] {
            state.apply(.customerRefused(refusal, ticket: state.issueTicket()), at: t0)
            XCTAssertEqual(state.phase, .linked(.billable), "\(refusal)")
        }
    }

    func testRequestOutcomesAreIgnoredWhenNotLinked() {
        var state = LinkState()
        XCTAssertFalse(state.apply(.customerBilled(ticket: state.issueTicket()), at: t0))
        XCTAssertFalse(state.apply(.customerRefused(.notBillable, ticket: state.issueTicket()), at: t0))
        XCTAssertEqual(state.phase, .notLinked)
    }

    func testPolicyAndRetryLimitsClampValuesSetAfterInit() {
        var policy = LinkPolicy()
        policy.warmupMillis = -1
        policy.capProbeMillis = .min
        policy.probeTimeoutMillis = 0
        XCTAssertEqual(policy.warmupMillis, 0)
        XCTAssertEqual(policy.capProbeMillis, 1_000)
        XCTAssertEqual(policy.probeTimeoutMillis, 1_000)
        var limits = RetryLimits()
        limits.maxAttempts = -1          // would make `0..<maxAttempts` trap
        limits.maxRetryWaitMillis = .max
        XCTAssertEqual(limits.maxAttempts, 1)
        XCTAssertEqual(limits.maxRetryWaitMillis, 3_600_000)
    }

    func testLoweringTheProbeCeilingAfterInitNeverProbesSoonerThanTheFirstInterval() {
        var policy = LinkPolicy()
        policy.maxProbeMillis = 1_000
        var state = billableLink(policy: policy)
        state.apply(.customerRefused(.spendLimitReached, ticket: state.issueTicket()), at: t0)
        guard case let .linked(.spendLimitReached(_, next)) = state.phase else { return XCTFail("\(state.phase)") }
        XCTAssertEqual(next, t0 + 15 * 60_000)
    }

    func testPolicyClampsHostileValues() {
        let policy = LinkPolicy(warmupMillis: -5, capProbeMillis: 0, refusalProbeMillis: .min,
                                maxProbeMillis: .min, probeTimeoutMillis: -1)
        XCTAssertEqual(policy.warmupMillis, 0)
        XCTAssertEqual(policy.capProbeMillis, 1_000)
        XCTAssertGreaterThanOrEqual(policy.maxProbeMillis, policy.refusalProbeMillis)
        let huge = LinkPolicy(capProbeMillis: .max, maxProbeMillis: .max)
        var state = billableLink(policy: huge)
        state.apply(.customerRefused(.billingUnavailable, ticket: state.issueTicket()), at: .max - 5)
        guard case let .linked(.billingUnavailable(next)) = state.phase else { return XCTFail("\(state.phase)") }
        XCTAssertEqual(next, .max) // saturated, not wrapped
    }
}

private extension CustomerAdmission {
    var isProbe: Bool { self == .probe }
}
