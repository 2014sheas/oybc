// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OYBC",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "OYBC",
            targets: ["OYBC"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0")
    ],
    targets: [
        .target(
            name: "OYBC",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "OYBC"
        ),
        .testTarget(
            name: "OYBCTests",
            dependencies: ["OYBC"],
            path: "OYBCTests"
        )
    ]
)
