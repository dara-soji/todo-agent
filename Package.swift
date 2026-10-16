// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "TodoAgent",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AssistantCore", targets: ["AssistantCore"]),
        .executable(name: "AssistantHelper", targets: ["AssistantHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.65.0"),
    ],
    targets: [
        // The whole domain. No UI, no OS calls: Signals and time enter only through ports.
        .target(name: "AssistantCore"),
        // SQLite adapter for the core's persistence. Only the helper writes the store.
        .target(name: "AssistantPersistence", dependencies: ["AssistantCore"]),
        // The local MCP server: the contract through which Claude Code reaches the core (ADR 0001).
        .target(name: "AssistantMCP", dependencies: [
            "AssistantCore",
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
        ]),
        // The menu-bar helper: OS sensors and AppKit UI wired to the core.
        .executableTarget(name: "AssistantHelper", dependencies: ["AssistantCore", "AssistantPersistence", "AssistantMCP"]),
        // Fakes for the core's ports, shared by both test seams.
        .target(name: "AssistantTestSupport", dependencies: ["AssistantCore"], path: "Tests/AssistantTestSupport"),
        .testTarget(name: "AssistantCoreTests", dependencies: ["AssistantCore", "AssistantTestSupport"]),
        // The SQLite store against a real file in a temporary folder.
        .testTarget(name: "AssistantPersistenceTests", dependencies: ["AssistantPersistence", "AssistantCore"]),
        .testTarget(name: "AssistantMCPContractTests", dependencies: [
            "AssistantMCP", "AssistantCore", "AssistantTestSupport",
            .product(name: "MCP", package: "swift-sdk"),
        ]),
    ]
)
