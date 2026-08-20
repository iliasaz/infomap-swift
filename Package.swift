// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "infomap-swift",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "InfomapKit", targets: ["InfomapKit"])
    ],
    targets: [
        // Interface-specification stage: pure Swift, no C++ target yet.
        // Roadmap step 2 adds `CInfomap` (C++ interop over the vendored
        // iliasaz/infomap submodule) and makes InfomapKit depend on it.
        .target(name: "InfomapKit"),
        .testTarget(name: "InfomapKitTests", dependencies: ["InfomapKit"]),
    ],
    cxxLanguageStandard: .cxx14
)
