// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SherpaTagging",
    platforms: [.iOS(.v17)],
    products: [.library(name: "SherpaTagging", targets: ["SherpaTagging"])],
    targets: [
        .binaryTarget(name: "SherpaOnnxC", path: "sherpa-onnx.xcframework"),
        .binaryTarget(name: "onnxruntime", path: "onnxruntime.xcframework"),
        .target(name: "ASCBridge", dependencies: ["onnxruntime"], publicHeadersPath: "include", linkerSettings: [.linkedLibrary("c++")]),
        .target(name: "EfficientATBridge", dependencies: ["onnxruntime"], publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Accelerate")]),
        .target(name: "SherpaTagging", dependencies: ["SherpaOnnxC", "onnxruntime", "ASCBridge", "EfficientATBridge"],
                linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Accelerate")])
    ],
    cxxLanguageStandard: .cxx17
)
