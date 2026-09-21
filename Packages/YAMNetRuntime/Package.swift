// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "YAMNetRuntime",
    platforms: [.iOS(.v17)],
    products: [.library(name: "YAMNetRuntime", targets: ["YAMNetRuntime"])],
    targets: [
        .binaryTarget(name: "TensorFlowLiteC", path: "TensorFlowLiteC.xcframework"),
        .target(
            name: "YAMNetRuntime",
            dependencies: ["TensorFlowLiteC"],
            resources: [.copy("PrivacyInfo.xcprivacy")],
            linkerSettings: [.linkedLibrary("c++")]
        )
    ]
)
