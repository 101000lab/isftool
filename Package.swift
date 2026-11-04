// swift-tools-version: 6.0
import PackageDescription

// The configuration VDMX's GLSLangValidatorLib was built with: HLSL on, spirv-opt off.
let glslangSettings: [CXXSetting] = [
    .define("ENABLE_HLSL"),
    .define("ENABLE_OPT", to: "0"),
    .define("GLSLANG_OSINCLUDE_UNIX"),
]

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
            name: "CGLSLang",
            path: "Vendor/glslang",
            sources: [
                "glslang/GenericCodeGen/CodeGen.cpp",
                "glslang/GenericCodeGen/Link.cpp",
                "glslang/MachineIndependent/glslang_tab.cpp",
                "glslang/MachineIndependent/attribute.cpp",
                "glslang/MachineIndependent/Constant.cpp",
                "glslang/MachineIndependent/iomapper.cpp",
                "glslang/MachineIndependent/InfoSink.cpp",
                "glslang/MachineIndependent/Initialize.cpp",
                "glslang/MachineIndependent/IntermTraverse.cpp",
                "glslang/MachineIndependent/Intermediate.cpp",
                "glslang/MachineIndependent/ParseContextBase.cpp",
                "glslang/MachineIndependent/ParseHelper.cpp",
                "glslang/MachineIndependent/PoolAlloc.cpp",
                "glslang/MachineIndependent/RemoveTree.cpp",
                "glslang/MachineIndependent/Scan.cpp",
                "glslang/MachineIndependent/ShaderLang.cpp",
                "glslang/MachineIndependent/SpirvIntrinsics.cpp",
                "glslang/MachineIndependent/SymbolTable.cpp",
                "glslang/MachineIndependent/Versions.cpp",
                "glslang/MachineIndependent/intermOut.cpp",
                "glslang/MachineIndependent/limits.cpp",
                "glslang/MachineIndependent/linkValidate.cpp",
                "glslang/MachineIndependent/parseConst.cpp",
                "glslang/MachineIndependent/reflection.cpp",
                "glslang/MachineIndependent/preprocessor/Pp.cpp",
                "glslang/MachineIndependent/preprocessor/PpAtom.cpp",
                "glslang/MachineIndependent/preprocessor/PpContext.cpp",
                "glslang/MachineIndependent/preprocessor/PpScanner.cpp",
                "glslang/MachineIndependent/preprocessor/PpTokens.cpp",
                "glslang/MachineIndependent/propagateNoContraction.cpp",
                "glslang/HLSL/hlslAttributes.cpp",
                "glslang/HLSL/hlslParseHelper.cpp",
                "glslang/HLSL/hlslScanContext.cpp",
                "glslang/HLSL/hlslOpMap.cpp",
                "glslang/HLSL/hlslTokenStream.cpp",
                "glslang/HLSL/hlslGrammar.cpp",
                "glslang/HLSL/hlslParseables.cpp",
                "glslang/OSDependent/Unix/ossource.cpp",
                "glslang/ResourceLimits/ResourceLimits.cpp",
                "SPIRV/GlslangToSpv.cpp",
                "SPIRV/InReadableOrder.cpp",
                "SPIRV/Logger.cpp",
                "SPIRV/SpvBuilder.cpp",
                "SPIRV/SpvPostProcess.cpp",
                "SPIRV/doc.cpp",
                "SPIRV/disassemble.cpp",
            ],
            publicHeadersPath: "glslang/Public",
            cxxSettings: glslangSettings + [.headerSearchPath("."), .headerSearchPath("../../Sources/CToolchain/generated")]
        ),
        .target(
            name: "CSPIRVCross",
            path: "Vendor/SPIRV-Cross",
            sources: [
                "spirv_cross.cpp",
                "spirv_parser.cpp",
                "spirv_cross_parsed_ir.cpp",
                "spirv_cfg.cpp",
                "spirv_glsl.cpp",
                "spirv_msl.cpp",
                "spirv_hlsl.cpp",
                "spirv_cpp.cpp",
                "spirv_reflect.cpp",
                "spirv_cross_util.cpp",
            ],
            publicHeadersPath: "include"
        ),
        .target(
            name: "CToolchain",
            dependencies: ["CGLSLang", "CSPIRVCross"],
            cxxSettings: glslangSettings + [
                .headerSearchPath("generated"),
                .headerSearchPath("../../Vendor/glslang"),
                .headerSearchPath("../../Vendor/SPIRV-Cross"),
            ]
        ),
        .target(
            name: "ISFGLSLBridge",
            dependencies: ["CISFGLSLGenerator"]
        ),
        .target(
            name: "ISFKit",
            dependencies: ["ISFGLSLBridge", "CToolchain"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Metal"), .linkedFramework("MetalKit")]
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
