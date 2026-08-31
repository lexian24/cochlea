// swift-tools-version: 5.9
import PackageDescription

// Deliberately dependency-free.
//
// The ASR backend is a seam (`Transcriber`), not a hard dependency: pulling
// mlx-swift in here would make the package unbuildable for anyone without the
// full toolchain and would couple M0 to a decision the spec leaves open
// (Whisper turbo vs SenseVoice-Small, benchmarked at M0). Add it in a target
// that conforms to `Transcriber` once that benchmark is settled.
let package = Package(
    name: "Cochlea",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CochleaApp", targets: ["CochleaApp"]),
        .library(name: "CochleaCore", targets: ["CochleaCore"]),
    ],
    targets: [
        .target(name: "CochleaCore"),
        .target(name: "CochleaAudio", dependencies: ["CochleaCore"]),
        .target(name: "CochleaASR", dependencies: ["CochleaCore"]),
        .target(name: "CochleaInput", dependencies: ["CochleaCore"]),
        .executableTarget(
            name: "CochleaApp",
            dependencies: ["CochleaCore", "CochleaAudio", "CochleaASR", "CochleaInput"]
        ),
        .testTarget(name: "CochleaCoreTests", dependencies: ["CochleaCore"]),
    ]
)
