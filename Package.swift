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
// No XCTest target: XCTest ships with full Xcode, not the Command Line Tools
// this project builds under. The regression suite runs instead as a binary
// mode — `sys-monitor --self-test` (Sources/sys-monitor/SelfTest.swift),
// exit 0 on pass / 1 on failure, exercising the real in-target RateMath and
// formatBps. If full Xcode is ever installed, an XCTest target can wrap the
// same assertions; until then --self-test is the runnable net.
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
