// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Edward",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "edward", targets: ["EdwardCLI"]),
        .executable(name: "MicTest", targets: ["MicTest"]),
    ],
    dependencies: [
        .package(url: "https://github.com/soniqo/speech-swift.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "EdwardCore",
            dependencies: [
                .product(name: "SpeechVAD", package: "speech-swift"),
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "SpeechEnhancement", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
            ],
            path: "Sources/EdwardCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "EdwardCLI",
            dependencies: ["EdwardCore"],
            path: "Sources/EdwardCLI"
        ),
        .executableTarget(
            name: "EdwardUI",
            dependencies: ["EdwardCore"],
            path: "Sources/EdwardUI"
        ),
        .executableTarget(
            name: "MicTest",
            dependencies: [],
            path: "Sources/MicTest"
        ),
    ]
)
