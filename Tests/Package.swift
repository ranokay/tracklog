// swift-tools-version: 6.2
import PackageDescription

/// The Store refuses test targets and a top-level Tests/ folder inside the
/// submitted package, so the engine's tests live here, in a sibling package.
/// TracklogCore and TracklogMedia are static products of that package; the
/// dynamic Tracklog product is the only one the Store builds as a droplet.
let package = Package(
    name: "TracklogTests",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../tracklog"),
    ],
    targets: [
        .testTarget(
            name: "TracklogCoreTests",
            dependencies: [
                .product(name: "TracklogCore", package: "Tracklog"),
            ],
            path: "TracklogCoreTests",
        ),
        .testTarget(
            name: "TracklogMediaTests",
            dependencies: [
                .product(name: "TracklogMedia", package: "Tracklog"),
                .product(name: "TracklogCore", package: "Tracklog"),
            ],
            path: "TracklogMediaTests",
        ),
    ],
)
