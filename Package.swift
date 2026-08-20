// swift-tools-version:5.9
// Notibase iOS SDK — zero dependencies (Arch §8.2), Foundation-only core so
// the exact shipped code also builds and e2e-tests on Linux CI.
import PackageDescription

let package = Package(
    name: "Notibase",
    platforms: [
        .iOS(.v13),
        .macOS(.v12),
    ],
    products: [
        .library(name: "Notibase", targets: ["Notibase"]),
    ],
    dependencies: [
        // TEST-ONLY: HMAC for the e2e's identity-verification checks on Linux.
        // The Notibase library target itself has ZERO dependencies.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(name: "Notibase", dependencies: []),
        .executableTarget(
            name: "TestMain",
            dependencies: [
                "Notibase",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
    ]
)
