// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DexedKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DexedKit", targets: ["DexedKit"]),
    ],
    targets: [
        // Dexed's msfa FM engine plus a JUCE-free voice manager, exposed through a C API.
        .target(
            name: "CDexedEngine",
            path: "Sources/CDexedEngine",
            exclude: ["msfa/MTS-ESP-LICENSE.txt"],
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-std=c++17"])]
        ),
        .target(
            name: "DexedKit",
            dependencies: ["CDexedEngine"],
            path: "Sources/DexedKit"
        ),
        .testTarget(
            name: "DexedKitTests",
            dependencies: ["DexedKit"],
            path: "Tests/DexedKitTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
