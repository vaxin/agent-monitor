// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentMonitor",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "AgentMonitor", targets: ["AgentMonitor"])
    ],
    targets: [
        .executableTarget(
            name: "AgentMonitor",
            path: "Sources",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Info.plist"])
            ]
        )
    ]
)
