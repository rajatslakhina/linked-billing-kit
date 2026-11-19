// swift-tools-version: 6.0
import PackageDescription

// Library only. The runnable demo lives in a separate repository
// (linked-billing-kit-demo-app) that consumes this package as a remote,
// version-pinned dependency. There is deliberately no executable target here.
//
// Platforms: only what CI builds — macOS (tests), a generic iOS Simulator build,
// and Linux (tests; LinkedBillingUI compiles to an empty module there because it is
// wrapped in `#if canImport(SwiftUI)`).
let package = Package(
    name: "LinkedBilling",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LinkedBilling", targets: ["LinkedBilling"]),
        .library(name: "LinkedBillingUI", targets: ["LinkedBillingUI"]),
    ],
    targets: [
        .target(name: "LinkedBilling"),
        .target(name: "LinkedBillingUI", dependencies: ["LinkedBilling"]),
        .testTarget(name: "LinkedBillingTests", dependencies: ["LinkedBilling"]),
    ]
)
