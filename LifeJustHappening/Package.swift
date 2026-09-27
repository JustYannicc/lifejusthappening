// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LifeJustHappening",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LifeJustHappening", targets: ["LifeJustHappening"])
    ],
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "9.29.2")
    ],
    targets: [
        .executableTarget(
            name: "LifeJustHappening",
            dependencies: [.product(name: "Sentry", package: "sentry-cocoa")],
            path: "Sources/LifeJustHappening",
            exclude: [
                "Resources/Info.plist",
                "Resources/LifeJustHappening.entitlements"
            ],
            resources: [
                .process("Resources/Assets.xcassets")
            ]
        ),
        .testTarget(
            name: "LifeJustHappeningTests",
            dependencies: ["LifeJustHappening"],
            path: "Tests/LifeJustHappeningTests"
        )
    ]
)
