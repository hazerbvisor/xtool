import Foundation

/// A prepared Darwin SDK/runtime tree imported into the app container.
///
/// The mobile port intentionally separates the target SDK from the compiler
/// implementation. Linux-hosted `swift`, `swiftc`, and `swift-frontend`
/// executables cannot run on iOS/iPadOS, so the imported tree only needs to
/// provide the Apple platform SDK and target runtime files. The compiler bridge
/// will be embedded into xtool and invoked in-process.
public struct PreparedToolchain: Sendable, Hashable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Accept either the artifact-bundle root or the Developer folder itself.
    public var developerDirectory: URL {
        if root.lastPathComponent == "Developer" {
            return root
        }
        return root.appendingPathComponent("Developer", isDirectory: true)
    }

    public var toolchainDirectory: URL {
        developerDirectory.appendingPathComponent(
            "Toolchains/XcodeDefault.xctoolchain",
            isDirectory: true
        )
    }

    /// Informational only. A frontend found here must not be assumed runnable on
    /// iOS; the mobile compiler path is an embedded in-process bridge.
    public var swiftFrontend: URL {
        toolchainDirectory.appendingPathComponent("usr/bin/swift-frontend")
    }

    public var hasBundledSwiftFrontend: Bool {
        FileManager.default.fileExists(atPath: swiftFrontend.path)
    }

    public var iPhoneOSPlatform: URL {
        developerDirectory.appendingPathComponent("Platforms/iPhoneOS.platform", isDirectory: true)
    }

    /// Validate the imported Darwin target SDK/runtime tree.
    ///
    /// This deliberately does NOT require `swift-frontend`. The Android xtool
    /// Darwin SDK keeps the Linux host compiler under /opt/swift while the
    /// artifact bundle provides the iPhoneOS target SDK/runtime data.
    public func validate(fileManager: FileManager = .default) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: developerDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MobileBuildBackendError.toolchainInvalid("Developer directory is missing")
        }

        guard fileManager.fileExists(atPath: iPhoneOSPlatform.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MobileBuildBackendError.toolchainInvalid("iPhoneOS.platform is missing")
        }

        _ = try iPhoneOSSDK(fileManager: fileManager)
    }

    /// Finds the newest installed iPhoneOS SDK in the prepared Darwin tree.
    public func iPhoneOSSDK(fileManager: FileManager = .default) throws -> URL {
        let sdkDirectory = iPhoneOSPlatform.appendingPathComponent("Developer/SDKs", isDirectory: true)
        let contents = try fileManager.contentsOfDirectory(
            at: sdkDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        guard let sdk = contents
            .filter({ $0.pathExtension == "sdk" && $0.lastPathComponent.hasPrefix("iPhoneOS") })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
            .first else {
            throw MobileBuildBackendError.toolchainInvalid("No iPhoneOS SDK was found")
        }
        return sdk
    }
}
