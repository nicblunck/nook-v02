// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NookLibrary",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "NookLibrary", targets: ["NookLibrary"])
    ],
    targets: [
        .target(
            name: "NookLibrary",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NookLibraryTests",
            dependencies: ["NookLibrary"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
