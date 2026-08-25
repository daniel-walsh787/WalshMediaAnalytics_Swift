// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "WalshMediaAnalytics",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "WalshMediaAnalytics", targets: ["WalshMediaAnalytics"]),
    ],
    targets: [
        .target(name: "WalshMediaAnalytics"),
        .testTarget(
            name: "WalshMediaAnalyticsTests",
            dependencies: ["WalshMediaAnalytics"]
        ),
    ]
)
