// swift-tools-version: 6.0
import PackageDescription

// macOS host tests exercise filesystem behavior without running an exploit.
let package = Package(
    name: "TaiKueriRunnerCore",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    targets: [
        .target(name: "NativeBridge", path: "TaiKueriRunner/Native", publicHeadersPath: "."),
        // The iOS app target is compiled by Xcode; this target exposes only the
        // non-UI logic so the same code can be tested on macOS.
        .target(name: "RunnerCore", dependencies: ["NativeBridge"], path: "TaiKueriRunner",
                exclude: ["Native", "App", "UI", "Resources", "TaiKueriRunner.entitlements",
                          "Features/Wallpaper/Views", "Features/Keypad/Views", "Features/LINE/Views",
                          "Features/MobileGestalt/Views", "Features/Applications/Views",
                          "Features/AppGroups/Views", "Features/FileBrowser/Views", "Features/Settings"],
                sources: ["Core",
                          "Features/Wallpaper/Services", "Features/Keypad/Services", "Features/LINE/Services",
                          "Features/MobileGestalt/Services", "Features/Applications/Services",
                          "Features/AppGroups/Services", "Features/FileBrowser/Services"],
                linkerSettings: [.linkedLibrary("sqlite3"), .linkedLibrary("z")]),
        .testTarget(name: "RunnerCoreTests", dependencies: ["RunnerCore"], path: "Tests")
    ],
    swiftLanguageModes: [.v6]
)
