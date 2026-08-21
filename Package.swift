// swift-tools-version: 5.9
import PackageDescription
import Foundation

// SwiftUI `App`-lifecycle executables built via SwiftPM don't get an
// Info.plist unless they're wrapped in a proper .app bundle. Without one,
// NSApplication has no bundle identity and macOS tears the process down
// right after it activates (dock icon flashes and disappears) — this bites
// specifically when running via Xcode's "Run" or `swift run`, since those
// don't go through build_app.sh's bundling. Embedding Info.plist directly
// into the binary's __TEXT,__info_plist section fixes it everywhere.
let infoPlistPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Info.plist")
    .path

let package = Package(
    name: "UTMStudio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "UTMStudio",
            path: "Sources/UTMStudio",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlistPath
                ])
            ]
        )
    ]
)
