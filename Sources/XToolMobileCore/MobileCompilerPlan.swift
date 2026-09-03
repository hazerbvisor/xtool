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

    /// Writes a tiny Swift source file and prepares the exact frontend job that
    /// should emit an arm64 iOS object file.
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
            "-frontend",
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

/// Describes the ABI boundary the next native milestone will implement.
///
/// Swift's compiler frontend exposes a library-level `swift::performFrontend`
/// path internally. The mobile bridge will adapt this Swift-friendly request to
/// that C++ entry point instead of starting `swift-frontend` as a child process.
public enum MobileCompilerBridgeContract {
    public static let backendName = "Swift FrontendTool / performFrontend"
    public static let executionModel = "in-process AOT"
}
