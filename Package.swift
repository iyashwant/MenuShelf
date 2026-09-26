// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MenuShelf",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "MenuShelf", targets: ["MenuShelf"]),
        .executable(name: "MenuShelfLidHelper", targets: ["MenuShelfLidHelper"])
    ],
    dependencies: [
        .package(url: "https://github.com/Clipy/Sauce", from: "2.4.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        .package(url: "https://github.com/sindresorhus/Defaults", from: "8.0.0"),
        .package(url: "https://github.com/krisk/fuse-swift", from: "1.4.0")
    ],
    targets: [
        .executableTarget(
            name: "MenuShelf",
            dependencies: [
                .product(name: "Sauce", package: "Sauce"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Defaults", package: "Defaults"),
                .product(name: "Fuse", package: "fuse-swift")
            ],
            resources: [
                .copy("ClipboardShelf/Vendor/Sounds/Knock.caf"),
                .copy("ClipboardShelf/Vendor/Sounds/Write.caf")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // Privileged companion for CaffeineShelf's lid-closed mode. Deliberately
        // dependency-free and UI-free: build_app.sh nests it inside MenuShelf.app
        // and signs it WITHOUT the sandbox entitlement, which is the entire point
        // (see Sources/MenuShelfLidHelper/main.swift).
        .executableTarget(
            name: "MenuShelfLidHelper",
            path: "Sources/MenuShelfLidHelper",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "ClockShelfTests",
            dependencies: ["MenuShelf"],
            path: "Tests/ClockShelfTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
