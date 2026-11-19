// swift-tools-version: 6.0
import PackageDescription

// Library only. The runnable demo lives in a separate repository
// (linked-billing-kit-demo-app) that consumes this package as a remote,
// version-pinned dependency. There is deliberately no executable target here.
//
// Products:
// - LinkedBilling: the production library (no Apple-only imports).
// - LinkedBillingTesting: deterministic test doubles (simulated Claude org, manual
//   clock) and the scripted month the demo app plays. Link it from test targets or a
//   demo, not from production code.
//
// Platforms: only what CI builds — macOS (tests), a generic iOS Simulator build, and
// Linux (tests).
let package = Package(
    name: "LinkedBilling",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LinkedBilling", targets: ["LinkedBilling"]),
        .library(name: "LinkedBillingTesting", targets: ["LinkedBillingTesting"]),
    ],
    targets: [
        .target(name: "LinkedBilling"),
        .target(name: "LinkedBillingTesting", dependencies: ["LinkedBilling"]),
        .testTarget(name: "LinkedBillingTests", dependencies: ["LinkedBilling", "LinkedBillingTesting"]),
    ]
)
