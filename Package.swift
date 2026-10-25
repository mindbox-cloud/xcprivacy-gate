// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "xcprivacy-gate",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "xcprivacy-gate", targets: ["xcprivacy-gate"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/indexstore-db.git", revision: "swift-6.3.3-RELEASE"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0")
    ],
    targets: [
        .target(
            name: "XCPrivacyGateRules",
            path: "Rules",
            resources: [
                .copy("rules.json"),
                .copy("fixtures"),
                .copy("apple")
            ]
        ),
        .target(
            name: "XCPrivacyGate",
            dependencies: [
                "XCPrivacyGateRules",
                .product(name: "IndexStoreDB", package: "indexstore-db"),
                .product(name: "SwiftIfConfig", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax")
            ]
        ),
        .executableTarget(
            name: "xcprivacy-gate",
            dependencies: [
                "XCPrivacyGate",
                "XCPrivacyGateRules",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "XCPrivacyGateTests",
            dependencies: ["XCPrivacyGate", "XCPrivacyGateRules"],
            resources: [.copy("Data")]
        )
    ],
    swiftLanguageModes: [.v6]
)
