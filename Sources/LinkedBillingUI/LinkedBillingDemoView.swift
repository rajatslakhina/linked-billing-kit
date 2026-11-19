#if canImport(SwiftUI)
import LinkedBilling
import SwiftUI

/// The demo's root view: a scripted month (Timeline), the routing table (Who pays)
/// and the app's own ledger (Ledger).
public struct LinkedBillingDemoView: View {
    public enum Tab: String, Hashable, Sendable, CaseIterable {
        case timeline, router, ledger
    }

    @State private var model: LinkedBillingDemoModel
    @State private var tab: Tab
    private let autoplaySteps: Int

    /// - Parameter autoplaySteps: run this many steps of the scripted month on appear
    ///   (0 = none; anything above the script length runs the whole month).
    public init(configuration: LinkedBillingDemoConfiguration, initialTab: Tab = .timeline, autoplaySteps: Int = 0) {
        _model = State(initialValue: LinkedBillingDemoModel(configuration: configuration))
        _tab = State(initialValue: initialTab)
        self.autoplaySteps = max(0, autoplaySteps)
    }

    public var body: some View {
        TabView(selection: $tab) {
            NavigationStack { TimelineScreen(model: model) }
                .tabItem { Label("Timeline", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.timeline)
            NavigationStack { RouterScreen(model: model) }
                .tabItem { Label("Who pays", systemImage: "arrow.triangle.branch") }
                .tag(Tab.router)
            NavigationStack { LedgerScreen(model: model) }
                .tabItem { Label("Ledger", systemImage: "list.bullet.rectangle") }
                .tag(Tab.ledger)
        }
        .task {
            if autoplaySteps > 0 { await model.run(steps: autoplaySteps) }
        }
    }
}

// MARK: Timeline

struct TimelineScreen: View {
    let model: LinkedBillingDemoModel

    var body: some View {
        List {
            Section {
                StatusHeader(phase: model.phase, now: model.now, totals: model.totals)
            }
            if model.steps.isEmpty {
                Section {
                    Text("A month in the life of one B2B customer whose Claude org pays for your app's AI features. Each step runs through the real gateway against a simulated Claude API.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.steps.reversed()) { step in
                Section {
                    StepCard(step: step, total: model.totalSteps)
                }
            }
        }
        .navigationTitle("Linked billing")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Reset") { model.reset() }
                    .disabled(model.isRunning || model.steps.isEmpty)
                Button(model.isFinished ? "Done" : "Next step") {
                    Task { await model.runNextStep() }
                }
                .disabled(model.isRunning || model.isFinished)
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct StatusHeader: View {
    let phase: LinkPhase
    let now: EpochMillis
    let totals: SpendTotals

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PhaseBadge(phase: phase)
                Spacer()
                Text(Format.dateTime(now)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Metric(label: "Customer org", value: totals.customerBilled.description, tint: .green)
                Metric(label: "Included", value: totals.appIncluded.description, tint: .blue)
                Metric(label: "Subsidy", value: totals.appSubsidy.description, tint: .orange)
                Metric(label: "App ops", value: totals.appOperational.description, tint: .gray)
            }
        }
        .padding(.vertical, 4)
    }
}

struct Metric: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PhaseBadge: View {
    let phase: LinkPhase

    var body: some View {
        Text(Format.phase(phase))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Format.phaseColor(phase).opacity(0.18), in: Capsule())
            .foregroundStyle(Format.phaseColor(phase))
    }
}

struct StepCard: View {
    let step: DemoStepRecord
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(step.id + 1)/\(total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(step.title).font(.headline)
            }
            Text(step.narrative).font(.footnote).foregroundStyle(.secondary)
            ForEach(step.requests) { request in
                RequestRow(request: request)
            }
            if let note = step.note {
                Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.blue)
            }
            HStack {
                Text("Link after step:").font(.caption).foregroundStyle(.secondary)
                PhaseBadge(phase: step.phaseAfter)
            }
        }
        .padding(.vertical, 4)
    }
}

struct RequestRow: View {
    let request: DemoRequestRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(request.featureName).font(.subheadline.weight(.medium))
                Spacer()
                Text(Format.outcome(request.result.outcome))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Format.outcomeColor(request.result.outcome))
            }
            ForEach(Array(request.result.attempts.enumerated()), id: \.offset) { _, attempt in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: Format.attemptSymbol(attempt.result))
                        .foregroundStyle(Format.attemptColor(attempt.result))
                        .font(.caption)
                    Text("\(Format.decision(attempt.decision)) → \(Format.attempt(attempt.result))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: Who pays

struct RouterScreen: View {
    let model: LinkedBillingDemoModel

    var body: some View {
        let rows = model.matrix()
        List {
            Section {
                Text("The router is a pure function. This is its answer for a $0.40 request per feature and link condition, for an App Store subscriber whose included allowance is used up.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.feature.id) { row in
                Section(row.feature.displayName) {
                    ForEach(Array(zip(LinkedBillingDemoModel.MatrixColumn.allCases, row.decisions)), id: \.0.id) { column, decision in
                        HStack(alignment: .top) {
                            Text(column.rawValue).font(.subheadline).frame(width: 104, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Format.payerTitle(decision))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Format.decisionColor(decision))
                                Text(Format.decisionDetail(decision)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Who pays")
    }
}

// MARK: Ledger

struct LedgerScreen: View {
    let model: LinkedBillingDemoModel

    var body: some View {
        List {
            if model.monthTotals.isEmpty {
                Section("This UTC month") {
                    StatusHeader(phase: model.phase, now: model.now, totals: model.totals)
                }
            }
            ForEach(model.monthTotals, id: \.month) { item in
                Section("\(item.month.description) (UTC)") {
                    HStack(spacing: 12) {
                        Metric(label: "Customer org", value: item.totals.customerBilled.description, tint: .green)
                        Metric(label: "Included", value: item.totals.appIncluded.description, tint: .blue)
                        Metric(label: "Subsidy", value: item.totals.appSubsidy.description, tint: .orange)
                        Metric(label: "App ops", value: item.totals.appOperational.description, tint: .gray)
                    }
                    if item.totals.unknownOutcomes > 0 {
                        Text("\(item.totals.unknownOutcomes) request(s) with unknown billing (transport failed)")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Section {
                if model.entries.isEmpty {
                    Text("No requests yet. Run the timeline first.").foregroundStyle(.secondary)
                }
                ForEach(model.entries) { entry in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName(forFeatureID: entry.featureID)).font(.subheadline)
                            Text("\(Format.payer(entry.payer, budget: entry.budget)) · \(entry.model.rawValue)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Format.ledgerOutcome(entry.outcome)).font(.caption.monospacedDigit())
                    }
                }
            } header: {
                Text("Recent requests (the API doesn't say who paid; this ledger does)")
            }
        }
        .navigationTitle("Ledger")
    }
}
#endif
