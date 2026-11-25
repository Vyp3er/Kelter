// swift-tools-version: 6.2
import PackageDescription

// WineKit enthält alles, was mit Wine zu tun hat (Engines, Bottles, Prozessstart).
// Die SwiftUI-App „Kelter“ nutzt nur diese Schnittstelle und kennt keine Wine-Details.
let package = Package(
    name: "WineKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "WineKit", targets: ["WineKit"])
    ],
    targets: [
        .target(
            name: "WineKit",
            resources: [
                .copy("Resources/components.json"),
                .copy("Resources/prerequisites.json"),
                .copy("Resources/Recipes")
            ]
        ),
        .testTarget(
            name: "WineKitTests",
            dependencies: ["WineKit"]
        )
    ]
)
