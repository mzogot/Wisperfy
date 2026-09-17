// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Wisperfy",
    platforms: [.macOS(.v26)],
    dependencies: [
        // NVIDIA Parakeet TDT v3 compiled to CoreML, run on the Neural Engine. Covers
        // 25 languages including Russian, which Apple's on-device engine lacks.
        // Pinned exactly: it ships a 500 MB model loader inside a signed binary, so a
        // bump must always be an explicit, reviewed diff rather than a package update.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.7"),
    ],
    targets: [
        .executableTarget(
            name: "Wisperfy",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Wisperfy",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // No runtime actor-isolation checks. Swift 6 language mode checks
                // isolation statically; the dynamic checks the compiler adds at closure
                // entry crashed inside the OS runtime in framework callbacks (event
                // tap, SwiftUI animator). See docs/LESSONS.md.
                .unsafeFlags(["-Xfrontend", "-disable-dynamic-actor-isolation"]),
            ]
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
