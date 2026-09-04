import Foundation

/// A concrete Swift frontend invocation prepared for the in-process compiler bridge.
///
/// This type deliberately contains no subprocess logic. The same argument list is
/// passed directly to Swift's frontend library entry point from the C++ bridge.
public struct MobileCompilerPlan: Sendable, Hashable {
    public let sourceURL: URL
    public let objectURL: URL
    public let sdkURL: URL
    public let swiftResourceDirectory: URL
    public let targetTriple: String
    public let arguments: [String]

    public init(
        sourceURL: URL,
        objectURL: URL,
        sdkURL: URL,
        swiftResourceDirectory: URL,
        targetTriple: String,
        arguments: [String]
    ) {
        self.sourceURL = sourceURL
        self.objectURL = objectURL
        self.sdkURL = sdkURL
        self.swiftResourceDirectory = swiftResourceDirectory
        self.targetTriple = targetTriple
        self.arguments = arguments
    }

    /// Writes the normal-SDK Swift probe used by the iPad IDE.
    ///
    /// This intentionally mirrors the minimal Swift driver job that is already
    /// known to compile successfully against the same Darwin artifact bundle on
    /// Linux. The first goal is to prove normal Swift stdlib loading and emit a
    /// real iOS object in-process; Apple-framework imports are tested separately.
    ///
    /// Important: `-frontend` is a Swift driver dispatch flag, not a frontend
    /// argument. The desktop driver strips it before calling `performFrontend`,
    /// so the in-process mobile bridge must not include it here.
    public static func helloWorld(
        toolchain: PreparedToolchain,
        workspace: URL,
        deploymentTarget: String = "16.0",
        fileManager: FileManager = .default
    ) throws -> Self {
        let configuration = try toolchain.mobileSwiftSDKConfiguration(
            fileManager: fileManager
        )

        try fileManager.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )

        // Keep module caches inside the writable app container. A failed textual
        // interface rebuild from an older probe must not poison this run.
        let moduleCache = workspace.appendingPathComponent(
            "ModuleCache-Prebuilt",
            isDirectory: true
        )
        let sdkModuleCache = workspace.appendingPathComponent(
            "SDKModuleCache-Prebuilt",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: moduleCache,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: sdkModuleCache,
            withIntermediateDirectories: true
        )

        let source = workspace.appendingPathComponent("Hello.swift")
        let object = workspace.appendingPathComponent("Hello.o")
        let target = "arm64-apple-ios\(deploymentTarget)"
        let platformSwiftResources = configuration.iPhoneOSSwiftResourceDirectory

        // Match the host-side probe that succeeds with upstream Swift 6.3.2 and
        // iPhoneOS 26.5. This still requires the Swift standard library, but keeps
        // Foundation/UIKit/SwiftUI out of the equation until stdlib loading works.
        let sourceText = """
        public func xtoolHello() -> Int {
            return 42
        }
        """
        try Data(sourceText.utf8).write(to: source, options: .atomic)
        try? fileManager.removeItem(at: object)

        var arguments = [
            "-c",
            "-primary-file", source.path,
            "-target", target,
            "-Xllvm", "-aarch64-use-tbi",
            "-enable-objc-interop",
            "-sdk", configuration.sdkURL.path,
            "-I", platformSwiftResources.path,
        ]

        // These are the include paths encoded in xtool's swift-sdk.json and
        // consumed by the already-working Linux -> iOS cross-build.
        for path in configuration.includeSearchPaths {
            arguments += ["-I", path.path]
        }

        arguments += [
            "-no-color-diagnostics",
            "-Xcc", "-fno-color-diagnostics",
            "-empty-abi-descriptor",
            "-resource-dir", configuration.swiftResourceDirectory.path,
            "-module-cache-path", moduleCache.path,
            "-sdk-module-cache-path", sdkModuleCache.path,
            "-no-auto-bridging-header-chaining",
            "-module-name", "main",
            // Keep module-loading diagnostics enabled so the app log proves
            // whether Swift came from the prebuilt cache or a textual interface.
            "-Rmodule-loading",
        ]

        // Swift's resource tree contains Apple-provided serialized modules at:
        //   iphoneos/prebuilt-modules/<sdk-version>/Swift.swiftmodule/...
        // Point performFrontend there explicitly. The normal driver can derive
        // this path, but our in-process bridge has no real swift-frontend argv[0]
        // and should not depend on executable-path inference.
        if let sdkVersion = configuration.targetSDKVersion {
            let prebuiltModules = platformSwiftResources
                .appendingPathComponent("prebuilt-modules", isDirectory: true)
                .appendingPathComponent(sdkVersion, isDirectory: true)
            arguments += [
                "-prebuilt-module-cache-path", prebuiltModules.path,
                "-target-sdk-version", sdkVersion,
            ]
        }
        if let sdkName = configuration.targetSDKName {
            arguments += ["-target-sdk-name", sdkName]
        }

        // Mirror the successful host frontend's ClangImporter setup.
        arguments += [
            "-Xcc", "-isysroot",
            "-Xcc", configuration.sdkURL.path,
        ]
        if let clangHeaders = configuration.clangBuiltinHeaders {
            arguments += [
                "-Xcc", "-isystem",
                "-Xcc", clangHeaders.path,
            ]
        }

        arguments += ["-o", object.path]

        return Self(
            sourceURL: source,
            objectURL: object,
            sdkURL: configuration.sdkURL,
            swiftResourceDirectory: configuration.swiftResourceDirectory,
            targetTriple: target,
            arguments: arguments
        )
    }

    /// Keeps the original stdlib-free probe available for diagnostics without
    /// regressing the normal IDE build path back to bootstrap mode.
    public static func stdlibFreeBootstrap(
        toolchain: PreparedToolchain,
        workspace: URL,
        deploymentTarget: String = "16.0",
        fileManager: FileManager = .default
    ) throws -> Self {
        try toolchain.validate(fileManager: fileManager)
        let sdk = try toolchain.iPhoneOSSDK(fileManager: fileManager)

        try fileManager.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        let moduleCache = workspace.appendingPathComponent("ModuleCache", isDirectory: true)
        let sdkModuleCache = workspace.appendingPathComponent("SDKModuleCache", isDirectory: true)
        try fileManager.createDirectory(at: moduleCache, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sdkModuleCache, withIntermediateDirectories: true)

        let source = workspace.appendingPathComponent("Bootstrap.swift")
        let object = workspace.appendingPathComponent("Bootstrap.o")
        let resourceDirectory = toolchain.toolchainDirectory
            .appendingPathComponent("usr/lib/swift", isDirectory: true)
        let target = "arm64-apple-ios\(deploymentTarget)"

        try Data("public func xtoolCompilerBootstrapProbe() {}\n".utf8)
            .write(to: source, options: .atomic)
        try? fileManager.removeItem(at: object)

        let arguments = [
            "-c",
            "-parse-stdlib",
            "-primary-file", source.path,
            "-target", target,
            "-sdk", sdk.path,
            "-resource-dir", resourceDirectory.path,
            "-module-cache-path", moduleCache.path,
            "-sdk-module-cache-path", sdkModuleCache.path,
            "-module-name", "XToolCompilerBootstrapProbe",
            "-o", object.path,
        ]

        return Self(
            sourceURL: source,
            objectURL: object,
            sdkURL: sdk,
            swiftResourceDirectory: resourceDirectory,
            targetTriple: target,
            arguments: arguments
        )
    }
}

/// Describes the ABI boundary the native compiler engine implements.
///
/// Swift's compiler frontend exposes the library-level `swift::performFrontend`
/// entry point. The mobile bridge passes frontend arguments directly to that C++
/// entry point instead of starting `swift-frontend` as a child process.
public enum MobileCompilerBridgeContract {
    public static let backendName = "Swift FrontendTool / performFrontend"
    public static let executionModel = "in-process AOT"
}
