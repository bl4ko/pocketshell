// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Models", targets: ["Models"]),
        .library(name: "KeyKit", targets: ["KeyKit"]),
        .library(name: "SSHKit", targets: ["SSHKit"]),
        .library(name: "ReconnectKit", targets: ["ReconnectKit"]),
        .library(name: "TmuxKit", targets: ["TmuxKit"]),
        .library(name: "TerminalUI", targets: ["TerminalUI"]),
        .library(name: "ToolbarUI", targets: ["ToolbarUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .target(name: "Models"),
        .target(name: "KeyKit", dependencies: [
            "Models",
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .target(name: "SSHKit", dependencies: [
            "Models",
            "KeyKit",
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
        ]),
        .target(name: "ReconnectKit", dependencies: ["Models"]),
        .target(name: "TmuxKit", dependencies: ["Models"]),
        .target(name: "TerminalUI", dependencies: [
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),
        .target(name: "ToolbarUI", dependencies: ["Models"]),
        .testTarget(name: "ModelsTests", dependencies: ["Models"]),
        .testTarget(name: "KeyKitTests", dependencies: ["KeyKit"]),
        .testTarget(name: "SSHKitTests", dependencies: ["SSHKit"]),
        .testTarget(name: "ReconnectKitTests", dependencies: ["ReconnectKit"]),
        .testTarget(name: "TmuxKitTests", dependencies: ["TmuxKit"]),
    ]
)
