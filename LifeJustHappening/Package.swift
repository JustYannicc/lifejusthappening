// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LifeJustHappening",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "LifeJustHappening", targets: ["LifeJustHappening"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "LifeJustHappening",
            dependencies: [],
            path: "Sources/LifeJustHappening",
            exclude: [
                "Resources/Info.plist",
                "Resources/LifeJustHappening.entitlements"
            ],
            resources: [
                .process("Resources/Assets.xcassets")
            ]
        )
    ]
)
