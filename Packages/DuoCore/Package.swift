// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DuoCore",
    platforms: [.iOS("27.1"), .macOS(.v14)],
    products: [
        .library(name: "F1TV", targets: ["F1TV"]),
        .library(name: "Library", targets: ["Library"]),
    ],
    targets: [
        .target(name: "F1TV"),
        .target(name: "Library"),
        .testTarget(name: "F1TVTests", dependencies: ["F1TV"], resources: [.copy("Fixtures")]),
        .testTarget(name: "LibraryTests", dependencies: ["Library"]),
    ],
    swiftLanguageModes: [.v6]
)
