// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ikkunointi",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Ikkunointi", targets: ["Ikkunointi"]),
        .executable(name: "ikkunointictl", targets: ["ikkunointictl"]),
    ],
    targets: [
        // Pure logic: layout tree, workspace model, config parser. No AppKit, fully unit-tested.
        .target(name: "IkkunointiCore"),
        // The menu bar app: Accessibility glue, event tap, border, status item, IPC server.
        .executableTarget(
            name: "Ikkunointi",
            dependencies: ["IkkunointiCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        // hyprctl-style command line client talking to the app over a Unix socket.
        .executableTarget(name: "ikkunointictl", dependencies: ["IkkunointiCore"]),
        .testTarget(name: "IkkunointiCoreTests", dependencies: ["IkkunointiCore"]),
    ]
)
