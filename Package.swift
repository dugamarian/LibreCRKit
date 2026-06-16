// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LibreCRKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "LibreCRKit", targets: ["LibreCRKit"]),
    ],
    targets: [
        .target(
            name: "LibreCRKit",
            path: "Sources/LibreCRKit",
            resources: [
                .copy("Resources/RuntimeTables"),
            ],
            swiftSettings: [
                // The clean-room Phase 5 key derivation is a tight pure-Swift
                // compute loop. Under `-Onone` (Debug) it runs ~20x slower —
                // ~30s on device, which overruns the Libre 3 authorization
                // timeout and drops the link before StartAuthorization. Force
                // optimization for this package even in Debug so the derivation
                // takes ~1s; the app target stays debuggable (-Onone). Output is
                // bit-identical to Release (verified), so correctness is unchanged.
                .unsafeFlags(["-O"], .when(configuration: .debug)),
            ]
        ),
        .testTarget(
            name: "LibreCRKitTests",
            dependencies: ["LibreCRKit"],
            path: "Tests/LibreCRKitTests"
        ),
    ]
)
