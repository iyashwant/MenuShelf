// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MenuShelf",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "MenuShelf", targets: ["MenuShelf"])
    ],
    targets: [
        .executableTarget(
            name: "MenuShelf",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
