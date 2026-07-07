// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "Models", targets: ["Models"]),
        .library(name: "KeyKit", targets: ["KeyKit"]),
        .library(name: "SSHKit", targets: ["SSHKit"]),
        .library(name: "ReconnectKit", targets: ["ReconnectKit"]),
        .library(name: "TmuxKit", targets: ["TmuxKit"]),
        .library(name: "TerminalUI", targets: ["TerminalUI"]),
        .library(name: "ToolbarUI", targets: ["ToolbarUI"]),
        .library(name: "VNCKit", targets: ["VNCKit"]),
        .library(name: "LockKit", targets: ["LockKit"]),
        .library(name: "MonitorKit", targets: ["MonitorKit"]),
        .library(name: "SFTPKit", targets: ["SFTPKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        .package(url: "https://github.com/royalapplications/royalvnc.git", revision: "92d4427c73817d8f849bb289ff190aa4b40c44ea"),
    ],
    targets: [
        .target(name: "Models"),
        .target(name: "LockKit"),
        .target(name: "MonitorKit", dependencies: ["TmuxKit"]),
        .target(name: "SFTPKit"),
        .target(name: "KeyKit", dependencies: [
            "Models",
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .target(name: "SSHKit", dependencies: [
            "Models",
            "KeyKit",
            "SFTPKit",
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
        ]),
        .target(name: "ReconnectKit", dependencies: ["Models"]),
        .target(name: "TmuxKit", dependencies: ["Models"]),
        .target(name: "TerminalUI", dependencies: [
            "Models",
            "ToolbarUI",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),
        .target(name: "ToolbarUI", dependencies: ["Models"]),
        .target(name: "VNCKit", dependencies: [
            "Models",
            .product(name: "RoyalVNCKit", package: "royalvnc"),
        ]),
        .testTarget(name: "ModelsTests", dependencies: ["Models"]),
        .testTarget(name: "LockKitTests", dependencies: ["LockKit"]),
        .testTarget(name: "MonitorKitTests", dependencies: ["MonitorKit"]),
        .testTarget(name: "SFTPKitTests", dependencies: ["SFTPKit"]),
        .testTarget(name: "KeyKitTests", dependencies: ["KeyKit"]),
        .testTarget(name: "SSHKitTests", dependencies: ["SSHKit"]),
        .testTarget(name: "ReconnectKitTests", dependencies: ["ReconnectKit"]),
        .testTarget(name: "TmuxKitTests", dependencies: ["TmuxKit"]),
        .testTarget(name: "ToolbarUITests", dependencies: ["ToolbarUI"]),
        .testTarget(name: "TerminalUITests", dependencies: ["TerminalUI"]),
        .testTarget(name: "VNCKitTests", dependencies: ["VNCKit"]),
    ]
)
