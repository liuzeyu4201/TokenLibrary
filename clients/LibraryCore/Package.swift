// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LibraryCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LibraryCore", targets: ["LibraryCore"]),
        .executable(name: "tltool", targets: ["tltool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"),
    ],
    targets: [
        .target(
            name: "LibraryCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/LibraryCore",
            resources: [.copy("Resources/ThirdPartyNotices")]
        ),
        .executableTarget(
            name: "tltool",
            dependencies: ["LibraryCore"],
            path: "Sources/tltool"
        ),
        .testTarget(
            name: "LibraryCoreTests",
            dependencies: ["LibraryCore"],
            path: "Tests/LibraryCoreTests"
        ),
    ]
)
