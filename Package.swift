// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftFlash",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SwiftFlash", targets: ["SwiftFlash"])
    ],
    dependencies: [
        .package(path: "Vendor/CodeEditTextView")
    ],
    targets: [
        .executableTarget(
            name: "SwiftFlash",
            dependencies: [
                .product(name: "CodeEditTextView", package: "CodeEditTextView")
            ],
            path: "Sources/SwiftFlash",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "SwiftFlashTests",
            dependencies: [
                "SwiftFlash"
            ],
            path: "Tests/SwiftFlashTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
