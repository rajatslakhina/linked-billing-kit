/// How a feature's Claude usage may be billed.
public enum FeatureBilling: Hashable, Sendable {
    /// Usage the customer and their users cause in your product. The only kind the
    /// docs allow you to bill to the customer.
    case customerDirected
    /// Your own usage (tests, evaluations, background moderation, work for other
    /// customers). Never billed to the customer, whatever the link state.
    case appOperational
}

/// A cheaper model the app uses when it pays on the customer's behalf.
public struct SubsidyModel: Hashable, Sendable {
    public let model: ModelID
    /// Its cost as a percentage of the primary model's, clamped to 1...100.
    public let costPercent: Int64

    public init(_ model: ModelID, costPercent: Int64) {
        self.model = model
        self.costPercent = min(max(1, costPercent), 100)
    }
}

/// A product feature, as the router sees it. Declared once, in code you own.
public struct FeatureDescriptor: Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let billing: FeatureBilling
    public let model: ModelID
    /// Used when the app pays on the customer's behalf. `nil` means no downgrade.
    public let subsidyModel: SubsidyModel?
    /// Uses billable code execution. A request with `bill_to: "user_profile"` can't
    /// use it (the API returns a 400), so the router never bills the customer for it.
    public let usesCodeExecution: Bool
    /// May the app pay for this feature when the customer's org can't?
    public let subsidyEligible: Bool

    public init(id: String, displayName: String, billing: FeatureBilling = .customerDirected,
                model: ModelID, subsidyModel: SubsidyModel? = nil,
                usesCodeExecution: Bool = false, subsidyEligible: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.billing = billing
        self.model = model
        self.subsidyModel = subsidyModel
        self.usesCodeExecution = usesCodeExecution
        self.subsidyEligible = subsidyEligible
    }
}

/// What the user has bought through the App Store, as resolved from StoreKit.
public enum StorePlan: Hashable, Sendable {
    /// No App Store subscription. (Not named `none`, which would collide with
    /// `Optional.none` wherever a plan is optional.)
    case noSubscription
    /// A subscription that includes this much Claude usage per UTC month.
    case subscription(includedPerMonth: MicroUSD)
}

/// Business rules the app compiles in (or fetches as remote config).
public struct RoutingPolicy: Hashable, Sendable {
    /// Most the app will spend per customer per UTC month covering requests the
    /// customer's org refused. `.zero` turns subsidy off.
    public var subsidyPerMonth: MicroUSD
    /// Subsidy applies only to App Store subscribers (a free user whose org stops
    /// paying gets a paused feature, not free inference).
    public var subsidyRequiresSubscription: Bool

    public init(subsidyPerMonth: MicroUSD, subsidyRequiresSubscription: Bool = true) {
        self.subsidyPerMonth = subsidyPerMonth
        self.subsidyRequiresSubscription = subsidyRequiresSubscription
    }
}

public enum AppPaidReason: Hashable, Sendable {
    case operational
    case includedInSubscription
    case codeExecutionNotCustomerBillable
    case subsidy(CustomerDenial)
}

public enum PauseReason: Hashable, Sendable {
    /// The customer's org can't pay and the app won't: link, fix billing, or subscribe.
    case customerUnavailable(CustomerDenial)
    case subsidyNotEligible(CustomerDenial)
    case subsidyBudgetExhausted(CustomerDenial)
    /// A code-execution feature the customer can't be billed for, with no app budget
    /// (included allowance or subsidy) left to cover it.
    case codeExecutionUnfunded
    /// The app's budget is reserved by in-flight requests, or the ledger refused a
    /// reservation for safety (see `SpendLedger.maxReservations`).
    case reservationRefused
}

/// The router's answer for one request.
public enum RouteDecision: Hashable, Sendable {
    case billCustomer(UserProfileID, model: ModelID, isProbe: Bool)
    case billApp(model: ModelID, budget: AppBudget, reason: AppPaidReason, estimate: MicroUSD)
    case pause(PauseReason)

    public var payer: Payer? {
        switch self {
        case let .billCustomer(profile, _, _): return .customer(profile)
        case .billApp: return .app
        case .pause: return nil
        }
    }
}

/// Decides who pays for a request. A pure function of its inputs, so every rule is
/// unit-testable without a network, and the same table can be shown in a UI.
///
/// Precedence, first match wins:
/// 1. **Operational usage → app.** Never billed to a customer.
/// 2. **Included in the App Store subscription → app**, while the monthly allowance
///    lasts. A user who paid Apple for usage is never also billed by their org for it.
///    (Code-execution features land here too when the allowance covers them.)
/// 3. **Code execution → app**, on the feature's own model, from the subsidy budget
///    (or pause): the API won't bill a customer for it.
/// 4. **Customer's org can pay → customer.** (`admit` or a due `probe`.)
/// 5. **Subsidy → app, on the cheaper model**, if the feature and plan are eligible
///    and the reservation fits the monthly subsidy budget.
/// 6. **Otherwise pause**, with a reason the UI can act on.
public enum BillingRouter {
    public static func route(
        feature: FeatureDescriptor,
        estimate: MicroUSD,
        profile: UserProfileID?,
        admission: CustomerAdmission,
        plan: StorePlan,
        policy: RoutingPolicy,
        ledger: SpendLedger,
        at now: EpochMillis
    ) -> RouteDecision {
        if feature.billing == .appOperational {
            return .billApp(model: feature.model, budget: .operational, reason: .operational, estimate: estimate)
        }

        let month = BillingMonth(containing: now)
        if case let .subscription(included) = plan,
           ledger.committed(.included, in: month) + estimate <= included {
            return .billApp(model: feature.model, budget: .included, reason: .includedInSubscription, estimate: estimate)
        }

        let subsidyAllowed = feature.subsidyEligible
            && !(policy.subsidyRequiresSubscription && plan == .noSubscription)
        let (subsidyModel, subsidyCost) = subsidyChoice(feature: feature, estimate: estimate)
        let subsidyFits = ledger.committed(.subsidy, in: month) + subsidyCost <= policy.subsidyPerMonth

        if feature.usesCodeExecution {
            // Runs on the feature's own model: code execution is a capability choice,
            // not a request the app may quietly downgrade.
            let fits = ledger.committed(.subsidy, in: month) + estimate <= policy.subsidyPerMonth
            guard subsidyAllowed, fits else { return .pause(.codeExecutionUnfunded) }
            return .billApp(model: feature.model, budget: .subsidy,
                            reason: .codeExecutionNotCustomerBillable, estimate: estimate)
        }

        func pauseOrSubsidy(_ denial: CustomerDenial) -> RouteDecision {
            guard feature.subsidyEligible else { return .pause(.subsidyNotEligible(denial)) }
            guard subsidyAllowed else { return .pause(.customerUnavailable(denial)) }
            guard subsidyFits else { return .pause(.subsidyBudgetExhausted(denial)) }
            return .billApp(model: subsidyModel, budget: .subsidy, reason: .subsidy(denial), estimate: subsidyCost)
        }

        guard let profile else { return pauseOrSubsidy(.notLinked) }
        switch admission {
        case .admit: return .billCustomer(profile, model: feature.model, isProbe: false)
        case .probe: return .billCustomer(profile, model: feature.model, isProbe: true)
        case let .deny(denial): return pauseOrSubsidy(denial)
        }

    }

    /// The model and estimated cost used when the app subsidises a request.
    public static func subsidyChoice(feature: FeatureDescriptor, estimate: MicroUSD) -> (ModelID, MicroUSD) {
        guard let downgrade = feature.subsidyModel else { return (feature.model, estimate) }
        // costPercent is clamped to 1...100, so the result never exceeds `estimate`;
        // a non-zero estimate never rounds down to a free request.
        guard estimate.value > 0 else { return (downgrade.model, .zero) }
        let scaled = Saturating.multiply(estimate.value, downgrade.costPercent) / 100
        return (downgrade.model, MicroUSD(max(1, scaled)))
    }
}
