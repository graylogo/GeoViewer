// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GeoViewer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "GeoViewer", targets: ["GeoViewer"])
    ],
    targets: [
        .executableTarget(
            name: "GeoViewer",
            path: "Sources/GeoViewer"
        )
    ]
)
