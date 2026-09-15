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
        // Added to the app's Notification Service Extension target, not the
        // app target. Media attachments and action buttons both require an
        // extension running between APNs and the notification; without one,
        // `mutable-content` is set and nothing happens.
        .library(name: "NotibaseNotificationService", targets: ["NotibaseNotificationService"]),
    ],
    dependencies: [
        // TEST-ONLY: HMAC for the e2e's identity-verification checks on Linux.
        // The Notibase library target itself has ZERO dependencies.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(name: "Notibase", dependencies: []),
        // Guarded by `#if canImport(UserNotifications)`, so it compiles to
        // nothing on Linux and the e2e CI job keeps working.
        .target(name: "NotibaseNotificationService", dependencies: []),
        .executableTarget(
            name: "TestMain",
            dependencies: [
                "Notibase",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
    ]
)
