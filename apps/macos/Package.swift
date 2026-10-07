// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Manimble",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "Manimble",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/Manimble"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
