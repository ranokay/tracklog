// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tracklog",
    platforms: [.macOS(.v14)],
    products: [
        // Static engine products exist only for the sibling test package in
        // Tests/: the Store refuses test targets and a Tests/ folder, so the
        // tests live outside this package and import the engine through these.
        .library(name: "TracklogCore", type: .static, targets: ["TracklogCore"]),
        .library(name: "TracklogMedia", type: .static, targets: ["TracklogMedia"]),
        // A droplet is a loadable bundle, so its product is a dynamic library.
        // Do not make it static: the app already carries DroppyKit, and a
        // second copy inside the droplet gives the same type two metadata
        // records, which fails every cast between them.
        .library(name: "Tracklog", type: .dynamic, targets: ["Tracklog"]),
    ],
    dependencies: [
        .package(url: "https://gitlab.com/droppyformac1/droppykit.git", from: "1.20.1"),
    ],
    targets: [
        .target(name: "TracklogCore"),
        .target(name: "TracklogMedia", dependencies: ["TracklogCore"]),
        .target(
            name: "Tracklog",
            dependencies: [
                "TracklogCore",
                "TracklogMedia",
                .product(name: "DroppyKit", package: "droppykit"),
            ],
        ),
        .executableTarget(
            name: "TracklogHarness",
            dependencies: [
                "Tracklog",
                .product(name: "DroppyKitHarness", package: "droppykit"),
            ],
        ),
    ],
)
