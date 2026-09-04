import Foundation

/// A concrete Swift frontend invocation prepared for the in-process compiler bridge.
///
/// This type deliberately contains no subprocess logic. The same argument list can
/// later be passed to Swift's frontend library entry point from a C++ bridge.
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

    /// Writes a tiny Swift source file and prepares the exact argument list
    /// consumed by `swift::performFrontend` to emit an arm64 iOS object file.
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
        try toolchain.validate(fileManager: fileManager)
        let sdk = try toolchain.iPhoneOSSDK(fileManager: fileManager)

        try fileManager.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )

        let source = workspace.appendingPathComponent("Hello.swift")
        let object = workspace.appendingPathComponent("Hello.o")
        let resourceDirectory = toolchain.toolchainDirectory
            .appendingPathComponent("usr/lib/swift", isDirectory: true)
        let target = "arm64-apple-ios\(deploymentTarget)"

        let sourceText = """
        public func xtoolCompilerProbe() -> Int {
            42
        }
        """
        try Data(sourceText.utf8).write(to: source, options: .atomic)
        try? fileManager.removeItem(at: object)

        let arguments = [
            "-c",
            "-primary-file", source.path,
            "-target", target,
            "-sdk", sdk.path,
            "-resource-dir", resourceDirectory.path,
            "-module-name", "XToolCompilerProbe",
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
