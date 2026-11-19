#!/usr/bin/env bash
# Each mutant re-introduces a specific bug that the README says the design prevents.
# A mutant "survives" if the test suite still passes with it applied, which means the
# claim is untested. The script fails if any mutant survives, if a mutant doesn't
# compile, if a pattern isn't found exactly once, or if the unmutated suite fails.
# Runs on macOS and Linux (the core library has no Apple-only code).
set -u
cd "$(dirname "$0")/.."
S=Sources/LinkedBilling
# file | exact text to replace (must occur exactly once; \n is a newline) | replacement | the claim it breaks
MUTANTS=(
  '$S/LinkState.swift|            guard ticket > authoritative else { break } // read began before a link/unlink|            // stale-read guard removed|a status read issued before a link/unlink can'"'"'t revert it'
  '$S/LinkState.swift|            if case .disconnected = status { everLinked = true }\n            guard ticket > authoritative else { break } // read began before a link/unlink|            guard ticket > authoritative else { break } // read began before a link/unlink\n            if case .disconnected = status { everLinked = true }|a stale disconnected read still records that the profile was once linked'
  '$S/LinkState.swift|            if case .linked = phase { break }|            if case .linked = base { break }|relinking after a read-detected unlink starts a pending flow, not a billable link'
  '$S/ConnectionReconciler.swift|        return min(delay, Saturating.add(remaining, 1_000))|        return delay + 0 * remaining|the polling delay wakes at a pending flow'"'"'s expiry'
  '$S/LinkState.swift|            // it didn'"'"'t answer the question, so it frees the slot.\n            if probe?.ticket == ticket { clearProbe(resetFailures: false) }\n            return|            // it didn'"'"'t answer the question, so it frees the slot.\n            return|a probe refused inside the warm-up frees the probe slot'
  '$S/LinkState.swift|                case .notConnected: return .notLinked\n|                case .notConnected: break\n|a not_connected read after a cancelled flow reads as not linked, in either order'
  '$S/WireProtocol.swift|        let significant = raw.drop(while: { $0 == "0" })|        let significant = Substring(raw)|leading zeros in retry-after carry no value'
  '$S/LinkState.swift|            base = .abandoned(at: now)|            base = everLinked ? .unlinked(reason: nil, at: now) : .notLinked|a cancelled flow reads the same whenever a disconnected read lands'
  '$S/LinkState.swift|        if case let .linked(.warmingUp(until)) = current, now >= until { return .linked(.billable) }|        if case let .linked(.warmingUp(until)) = current, false, now >= until { return .linked(.billable) }|the warm-up window ends in phase(at:) without an event'
  '$S/LinkedBillingGateway.swift|    public func beginStatusRead() -> Ticket { link.issueTicket(at: clock.now()) }|    public func beginStatusRead() -> Ticket { link.issueTicket() }|the first status read after an abandoned flow counts'
  '$S/ConnectionReconciler.swift|        await gateway.apply(.linkCancelled)\n        return await reconcileNow(fresh: true)|        await gateway.apply(.linkCancelled)\n        return .notLinkable|linkCancelled takes a fresh read after the cancel'
  '$S/WireProtocol.swift|        guard significant.utf8.count <= 10, let seconds = Int64(significant) else { return 3600 }|        guard significant.utf8.count <= 10, let seconds = Int64(significant) else { return nil }|an over-long retry-after clamps to an hour instead of being dropped'
  '$S/LinkState.swift|        guard ticket > authoritative, case .linked = base else { return }\n        guard refusal.isCustomerBillingSignal|        guard case .linked = base else { return }\n        guard refusal.isCustomerBillingSignal|a refusal issued before a relink is ignored'
  '$S/LinkState.swift|        // Invariant 2: an outcome older than the newest applied one is stale.\n        guard ticket > latestOutcome else {|        // Invariant 2: an outcome older than the newest applied one is stale.\n        guard true else {|a refusal issued before a recovering success can'"'"'t re-degrade'
  '$S/LinkState.swift|        // (A stale success from before a degrading refusal is not evidence of recovery.)\n        guard ticket > latestOutcome else {|        // (A stale success from before a degrading refusal is not evidence of recovery.)\n        guard true else {|a success issued before the degrading refusal can'"'"'t clear it'
  '$S/LinkState.swift|            guard now >= Saturating.add(probe.startedAt, policy.probeTimeoutMillis) else {|            guard true else {|only one probe is in flight at a time'
  '$S/LinkState.swift|            guard now >= Saturating.add(probe.startedAt, policy.probeTimeoutMillis) else {|            guard false else {|a lost probe stops blocking after the timeout'
  '$S/LinkState.swift|        guard admission(at: now) == .probe else { return false }|        _ = admission(at: now)|beginProbe refuses a second concurrent probe'
  '$S/LinkState.swift|            let next = min(Saturating.add(now, backoff(policy.capProbeMillis)), resetsAt)|            let next = Saturating.add(now, backoff(policy.capProbeMillis))|spend-limit probes are never later than 00:00 UTC on the 1st'
  '$S/LinkState.swift|        if refusal == .notBillable, isInWarmup(sentAt: sentAt) {|        if false, refusal == .notBillable, isInWarmup(sentAt: sentAt) {|not_billable inside the ~10 s window doesn'"'"'t degrade the link'
  '$S/LinkState.swift|        if refusal == .notBillable, isInWarmup(sentAt: sentAt) {|        if refusal == .notBillable, case let .warmingUp(until) = health, sentAt < until {|the warm-up window doesn'"'"'t depend on which outcome landed first'
  '$S/LinkState.swift|            guard case .pending = base else { break }\n            endUserLevelChange()|            guard case .pending = base else { break }|a read issued during a link flow is stale after a cancel, whenever it lands'
  '$S/LinkState.swift|        case .unknown:\n            return\n        case .connected:|        case .unknown:\n            negativeRead = (ticket, .notConnected, now)\n        case .connected:|connection_status unknown never changes state'
  '$S/LinkState.swift|                return // a pending OAuth flow is still the user'"'"'s to finish or cancel|                health = .billable; return|connected never overrides request-observed health'
  '$S/LinkState.swift|            applyRefusal(refusal, ticket: ticket, sentAt: sentAt ?? now, now: now)|            applyRefusal(refusal, ticket: ticket, sentAt: now, now: now)|the warm-up window is judged by send time'
  '$S/LinkedBillingGateway.swift|                    link.apply(.customerRefused(refusal, ticket: ticket, sentAt: now), at: after)|                    link.apply(.customerRefused(refusal, ticket: ticket), at: after)|the gateway reports a refusal'"'"'s send time'
  '$S/LinkedBillingGateway.swift|                    result = try await transport.send(request, payer: .app, profile: attributed, model: model)|                    result = try await transport.send(request, payer: .app, profile: nil, model: model)|app-paid calls still carry the customer'"'"'s profile'
  '$S/WireProtocol.swift|            if let profile { headers["anthropic-user-profile-id"] = profile.rawValue }|            _ = profile|the envelope attributes app-paid calls to the customer'
  '$S/LinkState.swift|            if let current = negativeRead, current.ticket > ticket { return }|            _ = negativeRead|only the newest negative read counts'
  '$S/LinkState.swift|            connectedEvidence = max(connectedEvidence, ticket)\n            switch base {|            switch base {|a newer connected read outvotes an older negative read'
  '$S/LinkState.swift|        guard ticket > authoritative, case .linked = base else { return }\n        guard refusal.isCustomerBillingSignal|        guard ticket > authoritative, case .linked = phase else { return }\n        guard refusal.isCustomerBillingSignal|a newer refusal that lands while a read says unlinked still updates health'
  '$S/LinkState.swift|        guard now >= expiry else { return }|        guard false else { return }|an abandoned link flow expires'
  '$S/LinkState.swift|        let ceiling = max(policy.maxProbeMillis, base)|        let ceiling = policy.maxProbeMillis|the probe ceiling never undercuts the first interval'
  '$S/LinkState.swift|            interval = Saturating.multiply(interval, 2)|            interval = Saturating.multiply(interval, 1)|failed probes back off exponentially'
  '$S/LinkState.swift|            failedProbes = min(failedProbes + 1, 16)\n||probe failures drive the backoff'
  '$S/LinkState.swift|            clearProbe(resetFailures: false)\n        }\n        // A non-probe refusal|        }\n        clearProbe(resetFailures: false)\n        // A non-probe refusal|a straggler refusal doesn'"'"'t cancel the probe in flight'
  '$S/LinkState.swift|            if let read = negativeRead, read.ticket > connectedEvidence {|            if let read = negativeRead {|a negative status read older than a success or a 402 doesn'"'"'t unlink'
  '$S/LinkState.swift|            connectedEvidence = max(connectedEvidence, ticket)\n        }|            _ = ticket\n        }|a 402 counts as proof the connection was alive'
  '$S/LinkState.swift|            let resetsAt = BillingMonth(containing: sentAt).end|            let resetsAt = BillingMonth(containing: now).end|a refused cap resets with the month the request was sent in'
  '$S/LinkState.swift|        guard ticket > authoritative, case .linked = base else { return }\n        connectedEvidence = max(connectedEvidence, ticket) // the org paid|        guard case .linked = base else { return }\n        connectedEvidence = max(connectedEvidence, ticket) // the org paid|a success issued before a relink is ignored'
  '$S/WireProtocol.swift|        case (403, "permission_error", "user_profile_not_billable"):|        case (403, "permission_error", _):|a bare 403 is not read as an unlinked customer'
  '$S/WireProtocol.swift|        default:\n            return .unknown\n        }\n    }\n\n    private struct ProfileEnvelope|        default:\n            return .notConnected\n        }\n    }\n\n    private struct ProfileEnvelope|an unrecognised connection_status type is unknown'
  '$S/WireProtocol.swift|        case (503, "overloaded_error", _):|        case (503, _, _):|only Anthropic'"'"'s overloaded_error counts as unbilled and retryable'
  '$S/LinkedBillingGateway.swift|    public var maxAttempts: Int { didSet { maxAttempts = min(max(1, maxAttempts), 10) } }|    public var maxAttempts: Int { didSet { } }|retry limits set after init are clamped'
  '$S/LinkState.swift|    public var capProbeMillis: Int64 { didSet { capProbeMillis = max(1_000, capProbeMillis) } }|    public var capProbeMillis: Int64 { didSet { } }|link policy values set after init are clamped'
  '$S/WireProtocol.swift|        return min(seconds, 3600)|        return seconds|retry-after is clamped'
  '$S/WireProtocol.swift|        for beta in additionalBetas where !betas.contains(beta) { betas.append(beta) }|        _ = additionalBetas|other betas are merged into the header, not dropped'
  '$S/SpendLedger.swift|        totals(for: month).spent(budget) + (reservedTotals[ReservedKey(month: month, budget: budget)] ?? .zero)|        totals(for: month).spent(budget)|in-flight reservations count against the budget'
  '$S/SpendLedger.swift|        reservedTotals[key] = remaining == .zero ? nil : remaining|        _ = remaining|releasing a reservation returns the budget'
  '$S/SpendLedger.swift|            month = held.month|            _ = held.month|a billed amount is charged to the reservation'"'"'s month'
  '$S/SpendLedger.swift|            ringStart = (ringStart + 1) % entryCapacity|            ringStart = 0|the entry log is a bounded ring, newest first'
  '$S/SpendLedger.swift|        guard reserved.count < Self.maxReservations else { return nil }|        _ = Self.maxReservations|reservations are bounded'
  '$S/BillingRouter.swift|        if feature.billing == .appOperational {|        if false {|operational usage is never billed to the customer'
  '$S/BillingRouter.swift|        if case let .subscription(included) = plan,\n           ledger.committed|        if case let .subscription(included) = plan, false,\n           ledger.committed|the App Store allowance pays before the customer'"'"'s org'
  '$S/BillingRouter.swift|        if feature.usesCodeExecution {|        if false {|code execution is never billed to the customer'
  '$S/BillingRouter.swift|            return .billApp(model: feature.model, budget: .subsidy,\n                            reason: .codeExecutionNotCustomerBillable|            return .billApp(model: subsidyModel, budget: .subsidy,\n                            reason: .codeExecutionNotCustomerBillable|code execution keeps the feature'"'"'s own model'
  '$S/BillingRouter.swift|            && !(policy.subsidyRequiresSubscription && plan == .noSubscription)|            && true|subsidy requires a subscription when the policy says so'
  '$S/BillingRouter.swift|        let subsidyFits = ledger.committed(.subsidy, in: month) + subsidyCost <= policy.subsidyPerMonth|        let subsidyFits = true|subsidy stops at the monthly budget'
  '$S/BillingRouter.swift|        let scaled = Saturating.add(Saturating.multiply(value / 100, downgrade.costPercent),|        let scaled = Saturating.add(Saturating.multiply(value, downgrade.costPercent) / 100, 0 *|huge estimates scale by the right percentage'
  '$S/BillingRouter.swift|        guard let downgrade = feature.subsidyModel else { return (feature.model, estimate) }|        guard let downgrade = Optional<SubsidyModel>.none else { return (feature.model, estimate) }|subsidy runs on the cheaper model'
  '$S/LinkedBillingGateway.swift|                        guard !warmupRetried else {|                        guard true else {|a second warm-up refusal stops trying the customer for that request'
  '$S/LinkedBillingGateway.swift|                    guard refusal.isCustomerBillingSignal else { return finish(.failed(.rejected(refusal))) }|                    _ = refusal.isCustomerBillingSignal|a caller bug is not masked by falling back to the app'
  '$S/LinkedBillingGateway.swift|                    let attributed = budget == .operational ? nil : profile|                    let attributed = profile|operational usage carries no customer profile'
  '$S/LinkedBillingGateway.swift|                        guard overloadRetries < limits.maxOverloadRetries, wait <= limits.maxRetryWaitMillis else {\n                            return finish(.failed(.overloaded))\n                        }\n                        overloadRetries += 1\n                        guard (try? await sleeper.sleep(millis: wait)) != nil else { return finish(.failed(.cancelled)) }\n                        continue\n                    }\n                    guard refusal.isCustomerBillingSignal|                        guard overloadRetries < limits.maxOverloadRetries else {\n                            return finish(.failed(.overloaded))\n                        }\n                        overloadRetries += 1\n                        guard (try? await sleeper.sleep(millis: wait)) != nil else { return finish(.failed(.cancelled)) }\n                        continue\n                    }\n                    guard refusal.isCustomerBillingSignal|a retry-after beyond the wait cap fails instead of holding the caller'
  '$S/LinkedBillingGateway.swift|            return Saturating.multiply(retryAfterSeconds, 1_000)|            return 0|retry-after is honoured'
  '$S/LinkedBillingGateway.swift|                    if refusal == .notBillable, !link.isInWarmup(sentAt: now) { statusCheck = true }|                    if refusal == .notBillable, false { statusCheck = true }|not_billable recommends a status read'
  '$S/LinkedBillingGateway.swift|                    if refusal == .notBillable, !link.isInWarmup(sentAt: now) { statusCheck = true }|                    if refusal == .notBillable { statusCheck = true }|a warm-up refusal doesn'"'"'t recommend a status read'
  '$S/LinkedBillingGateway.swift|                    attempts.append(GatewayAttempt(decision: decision, result: .transportFailed))\n                    return finish(.failed(.transportFailed))\n                }\n                let after = clock.now()\n                switch result {\n                case let .success(cost, text):\n                    link.apply|                    attempts.append(GatewayAttempt(decision: decision, result: .transportFailed))\n                    continue\n                }\n                let after = clock.now()\n                switch result {\n                case let .success(cost, text):\n                    link.apply|a transport failure is not retried (it could bill twice)'
  '$S/LinkedBillingGateway.swift|            guard !Task.isCancelled else { return finish(.failed(.cancelled)) }|            _ = Task.isCancelled|a cancelled task stops before sending'
  '$S/LinkedBillingGateway.swift|                    // the customer'"'"'s link, so they don'"'"'t touch LinkState.\n                    return finish|                    // the customer'"'"'s link, so they don'"'"'t touch LinkState.\n                    link.apply(.customerRefused(refusal, ticket: link.issueTicket()), at: after)\n                    return finish|an app-side refusal never touches the customer'"'"'s link'
  '$S/LinkedBillingGateway.swift|                    if isProbe { link.apply(.probeAbandoned(ticket: ticket), at: clock.now()) }|                    _ = isProbe|a probe lost to a transport error frees the slot'
  '$S/ConnectionReconciler.swift|        if let current = inFlight {|        if let current = inFlight, false {|concurrent reconciles share one read'
  '$S/ConnectionReconciler.swift|            guard fresh else { return shared }|            if true { return shared }|a fresh reconcile reads again after an older read'
  '$S/ConnectionReconciler.swift|        let ticket = await gateway.beginStatusRead()\n        do {\n            let status = try await source.fetchStatus(for: profile)|        do {\n            let status = try await source.fetchStatus(for: profile)\n            let ticket = await gateway.beginStatusRead()|a read that began before the user linked can'"'"'t revert the link'
  '$S/ConnectionReconciler.swift|        let offset = Int64(jitterDraw % UInt64(2 * span + 1)) - span|        let offset = span - span|jitter spreads a fleet'"'"'s polls'
  '$S/LinkSession.swift|        guard allowedHosts.contains(host) else { throw StartError.hostNotAllowed(host) }|        _ = allowedHosts|the authorize URL must be on an allow-listed host'
  '$S/LinkSession.swift|        guard !consumed else { return .rejected(.alreadyUsed) }\n\n        let items|        guard !consumed else { return .rejected(.alreadyUsed) }\n        consumed = true\n\n        let items|a forged state can'"'"'t cancel the user'"'"'s real sign-in'
  '$S/LinkSession.swift|        guard !consumed else { return .rejected(.alreadyUsed) }|        _ = consumed|a callback is accepted once'
  '$S/LinkSession.swift|        for name in ["state", "code", "error"] where items.filter({ $0.name == name }).count > 1 {|        for name in [String]() where items.filter({ $0.name == name }).count > 1 {|duplicate state, code or error parameters are rejected'
  '$S/LinkSession.swift|        for index in x.indices {|        for index in x.indices.prefix(1) {|state comparison covers every byte'
  '$S/LinkSession.swift|              now <= Saturating.add(createdAt, ttlMillis) else { return .rejected(.expired) }|              true else { return .rejected(.expired) }|a callback after the TTL is rejected'
  '$S/LinkSession.swift|        guard now >= Saturating.subtract(createdAt, clockSkewToleranceMillis),|        guard true,|a callback from well before the session began is rejected'
  '$S/BillingMonth.swift|            : -((-(millis + 1)) / Self.millisPerDay) - 1|            : millis / Self.millisPerDay|instants before 1970 land in the right month'
  '$S/Primitives.swift|        // Overflow is only possible when both operands share a sign.\n        return a < 0 ? .min : .max|        // Overflow is only possible when both operands share a sign.\n        return result|addition saturates instead of wrapping'
  '$S/Primitives.swift|        // a - b overflows only when a and b have opposite signs.\n        return a < 0 ? .min : .max|        // a - b overflows only when a and b have opposite signs.\n        return result|subtraction saturates instead of wrapping'
  '$S/Primitives.swift|        return (a < 0) == (b < 0) ? .max : .min|        return result|multiplication saturates instead of wrapping'
)
if command -v timeout >/dev/null; then LIMIT="timeout 300"; else LIMIT="perl -e alarm(300);exec(@ARGV)"; fi
if ! swift build --build-tests -q >/dev/null 2>&1 || ! $LIMIT swift test --skip-build >/dev/null 2>&1; then
  echo "BASELINE FAILED: the unmutated suite must pass before mutants mean anything"; exit 2
fi
echo "baseline: unmutated suite passes"
survived=0; caught=0
BACKUP=$(mktemp -d); CURRENT=""
trap '[ -n "$CURRENT" ] && cp "$BACKUP/orig" "$CURRENT"; rm -rf "$BACKUP"' EXIT
for entry in "${MUTANTS[@]}"; do
  entry=${entry//\$S/$S}
  IFS='|' read -r file from to claim <<< "$entry"
  cp "$file" "$BACKUP/orig"; CURRENT="$file"
  count=$(FROM="$from" perl -0777 -ne '($f=$ENV{FROM}) =~ s/\\n/\n/g; $c = () = /\Q$f\E/g; print $c' "$file")
  if [ "$count" != "1" ]; then echo "SETUP ERROR: pattern occurs $count times in $file: $claim"; exit 2; fi
  FROM="$from" TO="$to" perl -0777 -pi -e 'BEGIN { ($f = $ENV{FROM}) =~ s/\\n/\n/g; ($t = $ENV{TO}) =~ s/\\n/\n/g } s/\Q$f\E/$t/' "$file"
  if ! swift build --build-tests -q >/dev/null 2>&1; then
    echo "SETUP ERROR: mutant does not compile: $claim"; exit 2
  fi
  $LIMIT swift test --skip-build >/dev/null 2>&1; status=$?
  if [ "$status" -eq 0 ]; then
    echo "SURVIVED: $claim"; survived=$((survived + 1))
  elif [ "$status" -eq 124 ] || [ "$status" -eq 142 ]; then
    # A hang is not a catch: the suite must fail on an assertion, not on a timeout.
    echo "TIMEOUT:  $claim"; survived=$((survived + 1))
  else
    echo "caught:   $claim"; caught=$((caught + 1))
  fi
  cp "$BACKUP/orig" "$file"; CURRENT=""
done
echo "mutants caught: $caught, survived or timed out: $survived"
[ "$survived" -eq 0 ]
