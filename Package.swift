// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AtriumMac",
    platforms: [
        // 14.2 is the floor for CoreAudio process objects
        // (kAudioHardwarePropertyProcessObjectList) and process taps
        // (AudioHardwareCreateProcessTap). Both are load-bearing.
        .macOS("14.2")
    ],
    targets: [
        // The realtime audio callback must not allocate, lock, or touch
        // ARC. That is not a discipline Swift makes easy to guarantee, so
        // the render-thread hand-off lives in C with C11 atomics.
        .target(name: "CRingBuffer"),

        // Everything that does not touch AppKit or a capture device.
        // Split out so the self-test runner can exercise the upload
        // lane, the session state machine and the drift arithmetic
        // without a windowing session — and because a machine with only
        // the Command Line Tools installed has neither XCTest nor
        // swift-testing, so `swift test` is not available at all.
        .target(
            name: "AtriumCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AtriumMac",
            dependencies: ["CRingBuffer", "AtriumCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // `make test` and `make test-live`. See Sources/AtriumSelfTest.
        .executableTarget(
            name: "AtriumSelfTest",
            dependencies: ["AtriumCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
