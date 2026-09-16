// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Wisperfy",
    platforms: [.macOS(.v26)],
    dependencies: [
        // NVIDIA Parakeet TDT v3 compiled to CoreML, run on the Neural Engine. Covers
        // 25 languages including Russian, which Apple's on-device engine lacks.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.7"),
    ],
    targets: [
        .executableTarget(
            name: "Wisperfy",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Wisperfy",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Pure logic only: formatting, vocabulary mapping, correction diffs. Anything
        // touching TCC, the event tap or audio needs a signed bundle and a person.
        .testTarget(
            name: "WisperfyTests",
            dependencies: ["Wisperfy"],
            path: "Tests/WisperfyTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
