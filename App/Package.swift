// swift-tools-version: 6.0
//
// App/Package.swift — the thin AppKit + Metal shell.
//
// Purpose : Declares the `Videoboy` executable. It owns windows, output, and UI,
//           and links `VideoboyCore` for everything else. Keep logic out of here:
//           if a type does not need AppKit, it belongs in Core.
// Inputs  : ../Core (by path, so the two move together).
// Outputs : the `Videoboy` executable, wrapped into a .app bundle by scripts/build.sh.
// Extend  : add files under Sources/Videoboy/. New non-UI subsystems go in Core.

import PackageDescription

let package = Package(
    name: "Videoboy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Videoboy", targets: ["Videoboy"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .executableTarget(
            name: "Videoboy",
            dependencies: [.product(name: "VideoboyCore", package: "Core")],
            path: "Sources/Videoboy",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
