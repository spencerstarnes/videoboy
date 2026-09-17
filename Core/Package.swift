// swift-tools-version: 6.0
//
// Core/Package.swift — the non-UI half of Videoboy.
//
// Purpose : Declares `VideoboyCore`, the headless library holding the bitstream
//           engine, clocks, param-code registry, template I/O, render-graph model
//           and the self-QA harness. It has no AppKit dependency so that
//           `swift test` runs with no window server and no hardware attached.
// Inputs  : none (pure SwiftPM manifest).
// Outputs : the `VideoboyCore` library product, linked by the `App` package.
// Extend  : add source files under Sources/VideoboyCore/<Subsystem>/. Do not add
//           AppKit/UIKit here — anything that needs a window belongs in App/.
//
// Language mode is Swift 5 on purpose: the render loop and the self-QA harness
// pass buffers across threads in ways Swift 6 strict concurrency would require
// substantial ceremony to express, and clarity wins (SPEC 1.5).

import PackageDescription

let package = Package(
    name: "VideoboyCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VideoboyCore", targets: ["VideoboyCore"]),
        // The Amiga setup CLI. An executable rather than a shell script because the
        // Amiga-side ARexx listener is GENERATED from VideoboyCore — two copies of it,
        // one in Swift and one in bash, would drift and the failure would be silent.
        .executable(name: "videoboy-amiga", targets: ["videoboy-amiga"])
    ],
    targets: [
        // The C shim exposing the vendored LGPL FFmpeg. Its header and library
        // search paths are supplied at build time by scripts/_common.sh, because
        // vendor/ffmpeg is built by scripts/build-ffmpeg.sh rather than checked in.
        .target(
            name: "CFFmpeg",
            path: "Sources/CFFmpeg"
        ),
        .target(
            name: "VideoboyCore",
            dependencies: ["CFFmpeg"],
            path: "Sources/VideoboyCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "videoboy-amiga",
            dependencies: ["VideoboyCore"],
            path: "Sources/videoboy-amiga",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VideoboyCoreTests",
            dependencies: ["VideoboyCore"],
            path: "Tests/VideoboyCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
