// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "TodoAgent",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AssistantCore", targets: ["AssistantCore"]),
        .executable(name: "AssistantHelper", targets: ["AssistantHelper"]),
    ],
    targets: [
        // The whole domain. No UI, no OS calls: Signals and time enter only through ports.
        .target(name: "AssistantCore"),
        // SQLite adapter for the core's persistence. Only the helper writes the store.
        .target(name: "AssistantPersistence", dependencies: ["AssistantCore"]),
        // The menu-bar helper: OS sensors and AppKit UI wired to the core.
        .executableTarget(name: "AssistantHelper", dependencies: ["AssistantCore", "AssistantPersistence"]),
        .testTarget(name: "AssistantCoreTests", dependencies: ["AssistantCore"]),
    ]
)
