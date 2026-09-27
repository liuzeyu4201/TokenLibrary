// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenLibraryClient",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "LibraryUI", targets: ["LibraryUI"])],
    dependencies: [.package(path: "LibraryCore")],
    targets: [
        .target(name: "LibraryUI", dependencies: [.product(name: "LibraryCore", package: "LibraryCore")], path: "Shared"),
        .testTarget(name: "LibraryUITests", dependencies: ["LibraryUI", .product(name: "LibraryCore", package: "LibraryCore")], path: "Tests"),
    ]
)
