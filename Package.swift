// swift-tools-version: 6.3
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
        // The vendored Infomap core (submodule pin of iliasaz/infomap),
        // compiled as-is: src minus the CLI's main.cpp, no defines — matching
        // upstream's CMake infomap_core target. fmt and nlohmann_json are
        // vendored header-only inside the submodule.
        .target(
            name: "InfomapCore",
            path: "vendor/infomap",
            exclude: ["src/main.cpp"],
            sources: ["src"],
            publicHeadersPath: "src",
            cxxSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("vendor/fmt/include"),
                .headerSearchPath("vendor/nlohmann_json/include"),
            ]
        ),
        // The thin C++ bridge — the only target that includes Infomap
        // headers. Its public header is standard-library-only, so Swift
        // imports the bridge surface and never the core's headers.
        .target(
            name: "CInfomap",
            dependencies: ["InfomapCore"],
            cxxSettings: [
                .headerSearchPath("../../vendor/infomap/vendor/fmt/include"),
                .headerSearchPath("../../vendor/infomap/vendor/nlohmann_json/include"),
            ]
        ),
        // The Swift API. Enables C++ interop, which SwiftPM requires every
        // dependent target to enable as well (consumers add
        // .interoperabilityMode(.Cxx) to their own swiftSettings); no C++
        // type appears in InfomapKit's public interface.
        .target(
            name: "InfomapKit",
            dependencies: ["CInfomap"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .testTarget(
            name: "InfomapKitTests",
            dependencies: ["InfomapKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
