// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "isftool",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "isftool", targets: ["isftool"]),
        .library(name: "ISFKit", targets: ["ISFKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "isftool",
            dependencies: [
                "ISFKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "CISFGLSLGenerator",
            path: "Vendor/ISFGLSLGenerator/libISFGLSLGenerator",
            exclude: ["CMakeLists.txt", "Info.plist", "include/exprtk", "include/nlohmann_json"],
            sources: ["src"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                // Upstream's top-level CMakeLists.txt defines this on macOS.
                .define("MAC", to: "1"),
            ]
        ),
        .target(
            name: "ISFGLSLBridge",
            dependencies: ["CISFGLSLGenerator"]
        ),
        .target(
            name: "ISFKit",
            dependencies: ["ISFGLSLBridge"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Metal")]
        ),
        .testTarget(
            name: "ISFKitTests",
            dependencies: ["ISFKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
