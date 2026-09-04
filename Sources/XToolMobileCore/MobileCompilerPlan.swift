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
    /// The earlier bootstrap version of this method deliberately used
    /// `-parse-stdlib`. That milestone is complete: XTool has already emitted a
    /// real arm64 iOS object on-device. This plan now mirrors the Darwin Swift
    /// SDK configuration used by the successful SwiftPM cross-build and forces
    /// Foundation, UIKit and SwiftUI to load through the embedded frontend.
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

        // Use a new cache namespace for the serialized-module path. The prior
        // SDK-import probe may have cached a failed attempt to rebuild Apple's
        // textual Swift.swiftinterface; never let that poison this strategy.
        let moduleCache = workspace.appendingPathComponent(
            "ModuleCache-Serialized",
            isDirectory: true
        )
        let sdkModuleCache = workspace.appendingPathComponent(
            "SDKModuleCache-Serialized",
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
        let platformSwiftResources = configuration.swiftResourceDirectory
            .appendingPathComponent("iphoneos", isDirectory: true)

        // Referencing one type from each module makes this a real Apple SDK
        // compatibility test rather than an import that can be optimized away.
        let sourceText = """
        import Foundation
        import UIKit
        import SwiftUI

        public func xtoolCompilerProbe() {
            _ = NSObject.self
            _ = UIView.self
            _ = Text.self
        }
        """
        try Data(sourceText.utf8).write(to: source, options: .atomic)
        try? fileManager.removeItem(at: object)

        var arguments = [
            "-c",
            "-primary-file", source.path,
            "-target", target,
            "-sdk", configuration.sdkURL.path,
            "-resource-dir", configuration.swiftResourceDirectory.path,
            "-module-cache-path", moduleCache.path,
            "-sdk-module-cache-path", sdkModuleCache.path,
            "-module-name", "XToolCompilerProbe",
            "-enable-objc-interop",
            "-enable-cross-import-overlays",
            "-disable-modules-validate-system-headers",
            // Emit the exact module/interface paths chosen by the frontend. This
            // makes a failed probe actionable in one log instead of another blind run.
            "-Rmodule-loading",
            // Apple SDKs carry both serialized modules and textual interfaces.
            // Our embedded frontend is built from the same OSS Swift release as
            // the phone toolchain but not Apple's swiftlang build, so prefer a
            // compatible serialized module and avoid rebuilding Swift.swiftinterface.
            "-module-load-mode", "prefer-serialized",
            // Put the toolchain's platform Swift resources before the SDK's
            // usr/lib/swift interfaces. This mirrors normal Swift resource lookup
            // and prevents the raw Apple SDK copy from winning module discovery.
            "-I", platformSwiftResources.path,
        ]

        // These are the include paths encoded in xtool's swift-sdk.json and
        // consumed by SwiftPM for the already-working Linux -> iOS app build.
        for path in configuration.includeSearchPaths {
            arguments += ["-I", path.path]
        }

        // Ensure ClangImporter uses the target SDK and the Swift-sibling Clang
        // builtin headers copied into the Darwin runtime. Accidentally reaching
        // host builtin headers is a known cause of misleading SDK/compiler
        // mismatch diagnostics during Foundation/UIKit imports.
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
