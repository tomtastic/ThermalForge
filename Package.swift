// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ThermalForge",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "ThermalForgeCore",
            path: "Sources/ThermalForgeCore",
            linkerSettings: [
                .linkedFramework("Metal"),
            ]
        ),
        .executableTarget(
            name: "thermalforge",
            dependencies: [
                "ThermalForgeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/thermalforge"
        ),
        .executableTarget(
            name: "ThermalForgeApp",
            dependencies: ["ThermalForgeCore"],
            path: "Sources/ThermalForgeApp"
        ),
        .testTarget(
            name: "ThermalForgeTests",
            dependencies: ["ThermalForgeCore", "ThermalForgeFixture", "thermalforge"],
            path: "Tests/ThermalForgeTests"
        ),
        // Test-only command. Release packaging copies only the two production executables.
        .executableTarget(
            name: "ThermalForgeFixture",
            dependencies: [
                "ThermalForgeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Tests/IntegrationFixture"
        ),
    ]
)
