import Foundation

// The parts of the Claude Platform linked-billing API this package depends on,
// modelled as types. Sources: Claude Platform docs, "Bill your customers' Claude
// organizations" (organization-billing-connections), as published November 2026.

/// Who pays for one `/v1/messages` call.
public enum Payer: Hashable, Sendable {
    /// `billing_policy.bill_to = "user_profile"` with the `anthropic-user-profile-id`
    /// header: the customer's linked Claude organization pays.
    case customer(UserProfileID)
    /// `bill_to = "self"`: your organization pays.
    case app

    public var wireValue: String {
        switch self {
        case .customer: return "user_profile"
        case .app: return "self"
        }
    }

    public var isCustomer: Bool {
        if case .customer = self { return true }
        return false
    }
}

/// The headers and body fragment for a billed request.
public struct BillingEnvelope: Hashable, Sendable {
    /// The billing beta in the docs as of November 2026. Versioned: pass a newer value
    /// to `init` when Anthropic publishes one.
    public static let billingBeta = "user-profiles-billing-2026-10-01"

    public let headers: [String: String]
    /// Merge into the request body as `"billing_policy"`.
    public let billingPolicy: [String: String]

    /// - Parameters:
    ///   - profile: the customer's user profile, if there is one. Sent as
    ///     `anthropic-user-profile-id` on every call for a linked customer, including
    ///     app-paid ones, so the Console and usage API attribute that usage to them.
    ///   - additionalBetas: other betas the same request needs (for example for a
    ///     tool). They're joined into the single `anthropic-beta` header, so the
    ///     billing beta and yours don't overwrite each other.
    public init(payer: Payer, profile: UserProfileID? = nil,
                betaHeaderValue: String = BillingEnvelope.billingBeta,
                additionalBetas: [String] = []) {
        var betas = [betaHeaderValue]
        for beta in additionalBetas where !betas.contains(beta) { betas.append(beta) }
        var headers = ["anthropic-beta": betas.joined(separator: ",")]
        switch payer {
        case let .customer(billed):
            // Required when bill_to is user_profile and the call authenticates as
            // the operator service account; without it the API answers
            // 400 user_profile_required. The billed profile always wins.
            headers["anthropic-user-profile-id"] = billed.rawValue
        case .app:
            if let profile { headers["anthropic-user-profile-id"] = profile.rawValue }
        }
        self.headers = headers
        self.billingPolicy = ["type": "billing_policy", "bill_to": payer.wireValue]
    }
}

/// A refusal the API returns for a request, decoded from its status and body.
///
/// The decoder reads `error.type` *and* `error.details.error_code`. A bare 403
/// `permission_error` is not `user_profile_not_billable`, and treating every 403 as
/// "unlinked" would flip a customer's entitlement because of an unrelated auth bug.
public enum BillingRefusal: Hashable, Sendable {
    /// 403 `user_profile_not_billable`. Not retryable, except within ~10 s of a new
    /// connection. Causes include an ended connection and an ineligible organization;
    /// the response does not say which.
    case notBillable
    /// 402 `linked_organization_billing_unavailable`. Not retryable. May arrive after
    /// Claude has started a reply (for example, credit ran out mid-stream).
    case billingUnavailable
    /// 402 `linked_organization_spend_limit_reached`. The app's spend cap, the org's
    /// monthly limit, or no usable credit; the response does not say which. Refused
    /// before Claude started a reply.
    case spendLimitReached
    /// 503 `overloaded_error`: billing could not be confirmed. Retry with backoff,
    /// honouring `retry-after` (seconds). Not served, not billed.
    case overloaded(retryAfterSeconds: Int64?)
    /// 400 `user_profile_required`: a bug in the caller (missing profile header).
    case userProfileRequired
    /// 400 `invalid_request_error`, any other code or none: a malformed request.
    case invalidRequest(code: String?)
    /// Anything else. Not a billing signal; never changes entitlement state.
    case other(status: Int, type: String?, code: String?)

    /// Whether the refusal is evidence about the *customer's* billability, as opposed
    /// to a transient or caller-side problem.
    public var isCustomerBillingSignal: Bool {
        switch self {
        case .notBillable, .billingUnavailable, .spendLimitReached: return true
        case .overloaded, .userProfileRequired, .invalidRequest, .other: return false
        }
    }

    /// Decode an error response. `retryAfterHeader` is the raw `retry-after` value.
    public static func decode(status: Int, body: Data, retryAfterHeader: String? = nil) -> BillingRefusal {
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body)
        let type = envelope?.error.type
        let code = envelope?.error.details?.errorCode
        switch (status, type, code) {
        case (403, "permission_error", "user_profile_not_billable"):
            return .notBillable
        case (402, "billing_error", "linked_organization_billing_unavailable"):
            return .billingUnavailable
        case (402, "billing_error", "linked_organization_spend_limit_reached"):
            return .spendLimitReached
        case (503, _, _):
            return .overloaded(retryAfterSeconds: parseRetryAfter(retryAfterHeader))
        case (400, "invalid_request_error", "user_profile_required"):
            return .userProfileRequired
        case (400, "invalid_request_error", _):
            return .invalidRequest(code: code)
        default:
            return .other(status: status, type: type, code: code)
        }
    }

    /// `retry-after` in delta-seconds, clamped to 0...3600. An HTTP-date or garbage
    /// value yields `nil` (the caller falls back to its own backoff).
    static func parseRetryAfter(_ raw: String?) -> Int64? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty, raw.count <= 10,
              raw.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let seconds = Int64(raw) else { return nil }
        return min(seconds, 3600)
    }

    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable {
            struct Details: Decodable {
                let errorCode: String?
                enum CodingKeys: String, CodingKey { case errorCode = "error_code" }
            }
            let type: String?
            let details: Details?
        }
        let error: Body
    }
}

/// `connection_status` from `GET /v1/user_profiles/{id}?oauth_app_id=…`.
///
/// There is no webhook when a customer unlinks your app in the Claude Console, so
/// this read is the only positive signal that a link ended. Per the docs, `null` or
/// an unrecognised `type` is *unknown* (never "disconnected"), and an unrecognised
/// revocation reason is `other`.
public enum ConnectionStatus: Hashable, Sendable {
    case connected
    case disconnected(revokedAt: String?, reason: RevocationReason)
    case notConnected
    case unknown

    public enum RevocationReason: Hashable, Sendable {
        case revokedByAdmin
        case revokedByAppOwner
        case other
    }

    /// Decode the `connection_status` object from a user-profile response body.
    public static func decode(userProfileBody body: Data) -> ConnectionStatus {
        guard let profile = try? JSONDecoder().decode(ProfileEnvelope.self, from: body),
              let status = profile.connectionStatus else { return .unknown }
        switch status.type {
        case "connected":
            return .connected
        case "not_connected":
            return .notConnected
        case "disconnected":
            let reason: RevocationReason
            switch status.lastRevokedReason?.type {
            case "revoked_by_admin": reason = .revokedByAdmin
            case "revoked_by_app_owner": reason = .revokedByAppOwner
            default: reason = .other
            }
            return .disconnected(revokedAt: status.lastRevokedAt, reason: reason)
        default:
            return .unknown
        }
    }

    private struct ProfileEnvelope: Decodable {
        struct Status: Decodable {
            struct Reason: Decodable { let type: String? }
            let type: String?
            let lastRevokedAt: String?
            let lastRevokedReason: Reason?
            enum CodingKeys: String, CodingKey {
                case type
                case lastRevokedAt = "last_revoked_at"
                case lastRevokedReason = "last_revoked_reason"
            }
        }
        let connectionStatus: Status?
        enum CodingKeys: String, CodingKey { case connectionStatus = "connection_status" }
    }
}
