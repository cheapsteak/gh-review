// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GHReview",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.0.2"),
        .package(url: "https://github.com/raspu/Highlightr", from: "2.2.1")
    ],
    targets: [
        .executableTarget(
            name: "GHReview",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "Highlightr", package: "Highlightr")
            ],
            path: "Sources"
        )
    ]
)
