// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MeetNote",
    platforms: [.macOS("14.4")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7", traits: ["Diarizer"])
    ],
    targets: [
        // Talks to the gpu-proxy and writes summaries. No audio code, so it can be tested on its own.
        .target(name: "SummaryKit", path: "Sources/SummaryKit"),
        .executableTarget(
            name: "MeetNote",
            dependencies: [
                "SummaryKit",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/MeetNote"),
        // Command line tool used to test SummaryKit against a fake proxy.
        .executableTarget(
            name: "SummaryCheck",
            dependencies: ["SummaryKit"],
            path: "Sources/SummaryCheck"),
    ],
    swiftLanguageModes: [.v5]
)
