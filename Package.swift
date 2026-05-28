// swift-tools-version: 5.9
import PackageDescription

// sys-monitor — htop-inspired macOS menu-bar system monitor.
//
// One executable product, `sys-monitor`. SPM builds a bare binary under
// .build/<config>/; build.sh wraps it into a .app bundle (with Info.plist
// carrying LSUIElement) and ad-hoc-signs it. This shape is required because
// an SPM executable cannot set LSUIElement itself — only a bundled Info.plist
// can — and a menu-bar app needs LSUIElement to suppress the Dock icon.
//
// Tests sit in Tests/ but the target is commented because XCTest ships with
// full Xcode, not Command Line Tools alone. Re-enable when Xcode is installed.
let package = Package(
    name: "sys-monitor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "sys-monitor", targets: ["sys-monitor"]),
    ],
    targets: [
        .executableTarget(
            name: "sys-monitor",
            path: "Sources/sys-monitor"
        ),
        // .testTarget(
        //     name: "sys-monitorTests",
        //     dependencies: ["sys-monitor"],
        //     path: "Tests/sys-monitorTests"
        // ),
    ]
)
