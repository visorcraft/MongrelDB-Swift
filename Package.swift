// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MongrelDB",
    products: [
        .library(name: "MongrelDB", targets: ["MongrelDB"]),
    ],
    targets: [
        .target(name: "MongrelDB"),
        .testTarget(
            name: "MongrelDBTests",
            dependencies: ["MongrelDB"]
        ),
    ]
)
