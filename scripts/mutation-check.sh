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
  '$S/LinkState.swift|        guard ticket > authoritative, case let .linked(health) = phase else { return }|        guard case let .linked(health) = phase else { return }|a refusal issued before a relink is ignored'
  '$S/LinkState.swift|        // Invariant 2: an outcome older than the newest applied one is stale.\n        guard ticket > latestOutcome else {|        // Invariant 2: an outcome older than the newest applied one is stale.\n        guard true else {|a refusal issued before a recovering success can'"'"'t re-degrade'
  '$S/LinkState.swift|        // (A stale success from before a degrading refusal is not evidence of recovery.)\n        guard ticket > latestOutcome else {|        // (A stale success from before a degrading refusal is not evidence of recovery.)\n        guard true else {|a success issued before the degrading refusal can'"'"'t clear it'
  '$S/LinkState.swift|            guard now >= Saturating.add(probe.startedAt, policy.probeTimeoutMillis) else {|            guard true else {|only one probe is in flight at a time'
  '$S/LinkState.swift|        if let probe {\n            // One probe at a time|        if let probe, false {\n            // One probe at a time|a lost probe stops blocking only after the timeout'
  '$S/LinkState.swift|        guard admission(at: now) == .probe else { return false }|        _ = admission(at: now)|beginProbe refuses a second concurrent probe'
  '$S/LinkState.swift|            let next = min(Saturating.add(now, backoff(policy.capProbeMillis)), resetsAt)|            let next = Saturating.add(now, backoff(policy.capProbeMillis))|spend-limit probes are never later than 00:00 UTC on the 1st'
  '$S/LinkState.swift|        if case let .warmingUp(until) = health, refusal == .notBillable, now < until {|        if false, case let .warmingUp(until) = health, refusal == .notBillable, now < until {|not_billable inside the ~10 s window doesn'"'"'t degrade the link'
  '$S/LinkState.swift|        case .unknown:\n            return\n        case .connected:|        case .unknown:\n            phase = .notLinked\n        case .connected:|connection_status unknown never changes state'
  '$S/LinkState.swift|                // still the user'"'"'s to finish or cancel.\n                return|                // still the user'"'"'s to finish or cancel.\n                phase = .linked(.billable); return|connected never overrides request-observed health'
  '$S/LinkState.swift|            interval = Saturating.multiply(interval, 2)|            interval = Saturating.multiply(interval, 1)|failed probes back off exponentially'
  '$S/LinkState.swift|        if wasProbe { failedProbes = min(failedProbes + 1, 16) }|        _ = wasProbe|probe failures drive the backoff'
  '$S/WireProtocol.swift|        case (403, "permission_error", "user_profile_not_billable"):|        case (403, "permission_error", _):|a bare 403 is not read as an unlinked customer'
  '$S/WireProtocol.swift|        default:\n            return .unknown\n        }\n    }\n\n    private struct ProfileEnvelope|        default:\n            return .notConnected\n        }\n    }\n\n    private struct ProfileEnvelope|an unrecognised connection_status type is unknown'
  '$S/WireProtocol.swift|        return min(seconds, 3600)|        return seconds|retry-after is clamped'
  '$S/SpendLedger.swift|        totals(for: month).spent(budget) + (reservedTotals[ReservedKey(month: month, budget: budget)] ?? .zero)|        totals(for: month).spent(budget)|in-flight reservations count against the budget'
  '$S/SpendLedger.swift|        reservedTotals[key] = remaining == .zero ? nil : remaining|        _ = remaining|releasing a reservation returns the budget'
  '$S/SpendLedger.swift|            month = held.month|            _ = held.month|a billed amount is charged to the reservation'"'"'s month'
  '$S/SpendLedger.swift|            ringStart = (ringStart + 1) % entryCapacity|            ringStart = 0|the entry log is a bounded ring, newest first'
  '$S/SpendLedger.swift|        guard reserved.count < Self.maxReservations else { return nil }|        _ = Self.maxReservations|reservations are bounded'
  '$S/BillingRouter.swift|        if feature.billing == .appOperational {|        if false {|operational usage is never billed to the customer'
  '$S/BillingRouter.swift|        if case let .subscription(included) = plan,\n           ledger.committed|        if case let .subscription(included) = plan, false,\n           ledger.committed|the App Store allowance pays before the customer'"'"'s org'
  '$S/BillingRouter.swift|        if feature.usesCodeExecution {|        if false {|code execution is never billed to the customer'
  '$S/BillingRouter.swift|            && !(policy.subsidyRequiresSubscription && plan == .none)|            && true|subsidy requires a subscription when the policy says so'
  '$S/BillingRouter.swift|        let subsidyFits = ledger.committed(.subsidy, in: month) + subsidyCost <= policy.subsidyPerMonth|        let subsidyFits = true|subsidy stops at the monthly budget'
  '$S/BillingRouter.swift|        guard let downgrade = feature.subsidyModel else { return (feature.model, estimate) }|        guard let downgrade = Optional<SubsidyModel>.none else { return (feature.model, estimate) }|subsidy runs on the cheaper model'
  '$S/LinkedBillingGateway.swift|                        guard !warmupRetried else {|                        guard true else {|a second warm-up refusal stops trying the customer for that request'
  '$S/LinkedBillingGateway.swift|                    guard refusal.isCustomerBillingSignal else { return finish(.failed(.rejected(refusal))) }|                    _ = refusal.isCustomerBillingSignal|a caller bug is not masked by falling back to the app'
  '$S/LinkedBillingGateway.swift|            return Saturating.multiply(retryAfterSeconds, 1_000)|            return 0|retry-after is honoured'
  '$S/LinkedBillingGateway.swift|                    if refusal == .notBillable { statusCheck = true }|                    if refusal == .notBillable, false { statusCheck = true }|not_billable recommends a status read'
  '$S/LinkedBillingGateway.swift|                    if isProbe { link.apply(.probeAbandoned(ticket: ticket), at: clock.now()) }|                    _ = isProbe|a probe lost to a transport error frees the slot'
  '$S/ConnectionReconciler.swift|        if let inFlight { return await inFlight.task.value }|        _ = inFlight|concurrent reconciles share one read'
  '$S/ConnectionReconciler.swift|        let ticket = await gateway.beginStatusRead()\n        do {\n            let status = try await source.fetchStatus(for: profile)|        do {\n            let status = try await source.fetchStatus(for: profile)\n            let ticket = await gateway.beginStatusRead()|a read that began before the user linked can'"'"'t revert the link'
  '$S/ConnectionReconciler.swift|        let offset = Int64(jitterDraw % UInt64(2 * span + 1)) - span|        let offset = span - span|jitter spreads a fleet'"'"'s polls'
  '$S/LinkSession.swift|        guard allowedHosts.contains(host) else { throw StartError.hostNotAllowed(host) }|        _ = allowedHosts|the authorize URL must be on an allow-listed host'
  '$S/LinkSession.swift|        guard !consumed else { return .rejected(.alreadyUsed) }\n        guard now|        guard !consumed else { return .rejected(.alreadyUsed) }\n        consumed = true\n        guard now|a forged state can'"'"'t cancel the user'"'"'s real sign-in'
  '$S/LinkSession.swift|        guard !consumed else { return .rejected(.alreadyUsed) }|        _ = consumed|a callback is accepted once'
  '$S/LinkSession.swift|        guard states.count == 1, let received|        guard let received|duplicate state parameters are rejected'
  '$S/LinkSession.swift|        for index in x.indices {|        for index in x.indices.prefix(1) {|state comparison covers every byte'
  '$S/LinkSession.swift|        guard now >= createdAt, now <= Saturating.add(createdAt, ttlMillis) else {|        guard true else {|a callback after the TTL is rejected'
  '$S/BillingMonth.swift|            : -((-(millis + 1)) / Self.millisPerDay) - 1|            : millis / Self.millisPerDay|instants before 1970 land in the right month'
  '$S/Primitives.swift|        // Overflow is only possible when both operands share a sign.\n        return a < 0 ? .min : .max|        // Overflow is only possible when both operands share a sign.\n        return result|arithmetic saturates instead of wrapping'
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
  if $LIMIT swift test --skip-build >/dev/null 2>&1; then
    echo "SURVIVED: $claim"; survived=$((survived + 1))
  else
    echo "caught:   $claim"; caught=$((caught + 1))
  fi
  cp "$BACKUP/orig" "$file"; CURRENT=""
done
echo "mutants caught: $caught, survived: $survived"
[ "$survived" -eq 0 ]
