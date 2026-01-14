// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IPMonitor",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "IPMonitor", targets: ["IPMonitor"])
    ],
    targets: [
        .executableTarget(
            name: "IPMonitor",
            path: "Sources",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Info.plist"])
            ]
        )
    ]
)
