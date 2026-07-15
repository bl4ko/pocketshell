// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

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
        .package(
            url: "https://github.com/royalapplications/royalvnc.git",
            revision: "92d4427c73817d8f849bb289ff190aa4b40c44ea"),
    ],
    targets: [
        .target(name: "Models", swiftSettings: strict),
        .target(name: "LockKit", swiftSettings: strict),
        .target(name: "MonitorKit", dependencies: ["TmuxKit"], swiftSettings: strict),
        .target(name: "SFTPKit", swiftSettings: strict),
        .target(
            name: "KeyKit",
            dependencies: [
                "Models",
                .product(name: "Crypto", package: "swift-crypto"),
            ], swiftSettings: strict),
        .target(
            name: "SSHKit",
            dependencies: [
                "Models",
                "KeyKit",
                "SFTPKit",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ], swiftSettings: strict),
        .target(name: "ReconnectKit", dependencies: ["Models"], swiftSettings: strict),
        .target(name: "TmuxKit", dependencies: ["Models"], swiftSettings: strict),
        .target(
            name: "TerminalUI",
            dependencies: [
                "Models",
                "ToolbarUI",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ], swiftSettings: strict),
        .target(name: "ToolbarUI", dependencies: ["Models"], swiftSettings: strict),
        .target(
            name: "VNCKit",
            dependencies: [
                "Models",
                .product(name: "RoyalVNCKit", package: "royalvnc"),
            ], swiftSettings: strict),
        .testTarget(name: "ModelsTests", dependencies: ["Models"], swiftSettings: strict),
        .testTarget(name: "LockKitTests", dependencies: ["LockKit"], swiftSettings: strict),
        .testTarget(name: "MonitorKitTests", dependencies: ["MonitorKit"], swiftSettings: strict),
        .testTarget(name: "SFTPKitTests", dependencies: ["SFTPKit"], swiftSettings: strict),
        .testTarget(name: "KeyKitTests", dependencies: ["KeyKit"], swiftSettings: strict),
        .testTarget(name: "SSHKitTests", dependencies: ["SSHKit"], swiftSettings: strict),
        .testTarget(name: "ReconnectKitTests", dependencies: ["ReconnectKit"], swiftSettings: strict),
        .testTarget(name: "TmuxKitTests", dependencies: ["TmuxKit"], swiftSettings: strict),
        .testTarget(name: "ToolbarUITests", dependencies: ["ToolbarUI"], swiftSettings: strict),
        .testTarget(name: "TerminalUITests", dependencies: ["TerminalUI"], swiftSettings: strict),
        .testTarget(name: "VNCKitTests", dependencies: ["VNCKit"], swiftSettings: strict),
    ]
)
