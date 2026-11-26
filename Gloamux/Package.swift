// swift-tools-version:5.9
// Native SwiftNIO SSH provides the product's connections; Citadel supplies AES-CTR compatibility and loopback test
// servers. Build and test with `swift test`.
import PackageDescription

let package = Package(
    name: "Gloamux",
    // Interface text lives in Sources/app/Resources/<language>.lproj; English is the development language.
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GloamuxApp", targets: ["GloamuxApp"]),
        .executable(name: "gloamux", targets: ["GloamuxApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.0"),
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.2.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.35.0"),
        // Vendored with TLS session resumption for FTPS; see Vendor/swift-nio-ssl/VENDORED.md.
        .package(path: "Vendor/swift-nio-ssl"),
        // RSA (rsa-sha2-256/512) and ECDSA key support for SSH authentication.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.15.1"),
        // Test-only: lets the loopback test host an in-process SSH server. Citadel pulls this same
        // fork transitively; using the same module identity avoids duplicate NIOSSH products.
        // Vendored with agent forwarding added; see Vendor/swift-nio-ssh/VENDORED.md.
        .package(path: "Vendor/swift-nio-ssh"),
        // In-app updates (Gloamux › Check for Updates), signed with EdDSA. Only the app executable links it.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(name: "LocalPTY", path: "Sources/LocalPTY", linkerSettings: [.linkedLibrary("util")]),
        .target(name: "GloamuxShared", path: "Sources/GloamuxShared"),
        .target(name: "Formats", dependencies: ["GloamuxShared"], path: "Sources/formats"),
        .target(name: "GloamuxNetwork", dependencies: ["GloamuxShared", .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio"), .product(name: "NIOSOCKS", package: "swift-nio-extras")], path: "Sources/network"),
        .target(name: "Highlight", dependencies: ["GloamuxShared", "Formats"], path: "Sources/highlight"),
        .target(name: "Profiles", dependencies: ["GloamuxShared", "Formats"], path: "Sources/profiles"),
        .target(name: "Terminal", dependencies: ["GloamuxShared", "Formats"], path: "Sources/terminal"),
        .target(name: "ShellIntents", path: "Sources/intents"),
        .target(name: "MasterPassword", dependencies: ["GloamuxShared", "Profiles"], path: "Sources/master-password"),
        .target(name: "Ssh", dependencies: [.product(name: "Citadel", package: "Citadel"), "GloamuxShared", "MasterPassword", "GloamuxNetwork", "Profiles", .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio"), .product(name: "NIOSSH", package: "swift-nio-ssh"), .product(name: "NIOSOCKS", package: "swift-nio-extras"), .product(name: "Crypto", package: "swift-crypto"), .product(name: "_CryptoExtras", package: "swift-crypto"), .product(name: "BigInt", package: "BigInt")], path: "Sources/ssh"),
        .target(name: "FileTransfer", dependencies: ["GloamuxShared", "Ssh", .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio"), .product(name: "NIOSSL", package: "swift-nio-ssl"), .product(name: "NIOSSH", package: "swift-nio-ssh"), .product(name: "Crypto", package: "swift-crypto")], path: "Sources/file-transfer"),
        .target(name: "App", dependencies: ["LocalPTY", "GloamuxShared", "FileTransfer", "Highlight", "MasterPassword", "Ssh", "Terminal", "Profiles", "Formats", "GloamuxNetwork", "ShellIntents"], path: "Sources/app", resources: [.process("Resources")]),
        .executableTarget(name: "GloamuxApp", dependencies: ["GloamuxShared", "Formats", "GloamuxNetwork", "Highlight", "Profiles", "Terminal", "MasterPassword", "Ssh", "FileTransfer", "App", "ShellIntents", .product(name: "Sparkle", package: "Sparkle")], path: "Sources/GloamuxApp"),
        .testTarget(name: "FormatsTests", dependencies: ["GloamuxShared", "Formats"], path: "Tests/formats"),
        .testTarget(name: "NetworkTests", dependencies: ["GloamuxShared", "GloamuxNetwork", .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio")], path: "Tests/network"),
        .testTarget(name: "HighlightTests", dependencies: ["GloamuxShared", "Highlight"], path: "Tests/highlight"),
        .testTarget(name: "ProfilesTests", dependencies: ["GloamuxShared", "Profiles"], path: "Tests/profiles"),
        .testTarget(name: "TerminalTests", dependencies: ["GloamuxShared", "Terminal"], path: "Tests/terminal"),
        .testTarget(name: "MasterPasswordTests", dependencies: ["GloamuxShared", "MasterPassword"], path: "Tests/master-password"),
        .testTarget(name: "SshTests", dependencies: ["GloamuxShared", "Ssh", "GloamuxNetwork", "FileTransfer", .product(name: "NIOSSH", package: "swift-nio-ssh"), .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio"), .product(name: "Crypto", package: "swift-crypto"), .product(name: "_CryptoExtras", package: "swift-crypto"), .product(name: "BigInt", package: "BigInt")], path: "Tests/ssh"),
        .testTarget(name: "FileTransferTests", dependencies: ["GloamuxShared", "FileTransfer", "Ssh", "GloamuxNetwork", "App", .product(name: "NIOEmbedded", package: "swift-nio"), .product(name: "NIOTLS", package: "swift-nio"), .product(name: "NIOSSL", package: "swift-nio-ssl"), .product(name: "Citadel", package: "Citadel"), .product(name: "NIOSSH", package: "swift-nio-ssh"), .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio"), .product(name: "NIOSOCKS", package: "swift-nio-extras")], path: "Tests/file-transfer"),
        .testTarget(name: "AppTests", dependencies: ["GloamuxShared", "App", "MasterPassword", "GloamuxNetwork"], path: "Tests/app")
    ]
)
