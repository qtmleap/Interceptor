// swift-tools-version: 6.0
import PackageDescription

// Core-only QuickJS build; never compile its CLI, std/os library or module loader.
let package = Package(
    name: "InterceptorAutomation",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.executable(name: "interceptor-repository", targets: ["RepositoryPublisher"]), .library(name: "AutomationCore", targets: ["AutomationCore"]), .library(name: "AutomationRuntime", targets: ["AutomationRuntime"]), .library(name: "AutomationRepository", targets: ["AutomationRepository"])],
    targets: [
        .executableTarget(name: "RepositoryPublisher", dependencies: ["AutomationCore"]),
        .target(name: "AutomationCore"),
        .target(
            name: "CQuickJS",
            exclude: ["Vendor/LICENSE", "Vendor/VERSION"],
            sources: ["bridge.c", "Vendor/quickjs.c", "Vendor/dtoa.c", "Vendor/libregexp.c", "Vendor/libunicode.c", "Vendor/cutils.c"],
            publicHeadersPath: "include",
            cSettings: [.define("_GNU_SOURCE"), .define("CONFIG_VERSION", to: "\"2026-06-04\""), .headerSearchPath("Vendor"), .unsafeFlags(["-fwrapv", "-funsigned-char"])],
            linkerSettings: [.linkedLibrary("m")]
        ),
        .target(name: "AutomationRuntime", dependencies: ["CQuickJS", "AutomationCore"]),
        .target(name: "AutomationRepository", dependencies: ["AutomationCore"]),
        .testTarget(name: "AutomationRepositoryTests", dependencies: ["AutomationRepository", "AutomationCore"]),
        .testTarget(name: "AutomationRuntimeTests", dependencies: ["AutomationRuntime", "AutomationCore", "CQuickJS"]),
        .testTarget(name: "AutomationCoreTests", dependencies: ["AutomationCore"]),
    ],
    cLanguageStandard: .gnu11
)
