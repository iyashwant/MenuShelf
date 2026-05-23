// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MenuShelf",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "MenuShelf", targets: ["MenuShelf"])
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
            exclude: [
                "ClipboardShelf/Vendor/MACCY_LICENSE.txt"
            ],
            resources: [
                .copy("ClipboardShelf/Vendor/Sounds/Knock.caf"),
                .copy("ClipboardShelf/Vendor/Sounds/Write.caf")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "WorldClockTests",
            dependencies: ["MenuShelf"],
            path: "Tests/WorldClockTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
