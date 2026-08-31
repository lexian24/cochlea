// swift-tools-version: 5.9
import PackageDescription

// Deliberately dependency-free, and it stays that way under D5.
//
// The ASR backend is a seam (`Transcriber`), not a hard dependency. D5 puts
// inference in a Python child process rather than an in-process Swift library,
// so there is still nothing to link: `SidecarTranscriber` needs only
// Foundation. That is a consequence of the decision, not a constraint that
// drove it -- see docs/DECISIONS.md D5 for why the decode loop belongs next to
// the lexicon.
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
        .testTarget(name: "CochleaASRTests", dependencies: ["CochleaASR"]),
    ]
)
