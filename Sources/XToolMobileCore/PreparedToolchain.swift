import Foundation

/// A prepared Darwin SDK/toolchain imported into the app container.
///
/// The mobile port intentionally does not assume that Xcode is installed on the
/// device. The first prototype can import a pre-extracted toolchain produced by
/// desktop xtool's existing SDK setup flow.
public struct PreparedToolchain: Sendable, Hashable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Supports selecting either the directory that contains `Developer` or
    /// the `Developer` directory itself from the iOS Files picker.
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

    public var swiftFrontend: URL {
        toolchainDirectory.appendingPathComponent("usr/bin/swift-frontend")
    }

    public var swiftCompiler: URL {
        toolchainDirectory.appendingPathComponent("usr/bin/swift")
    }

    public var iPhoneOSPlatform: URL {
        developerDirectory.appendingPathComponent("Platforms/iPhoneOS.platform", isDirectory: true)
    }

    public func validate(fileManager: FileManager = .default) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: developerDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MobileBuildBackendError.toolchainInvalid("Developer directory is missing")
        }

        guard fileManager.fileExists(atPath: toolchainDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MobileBuildBackendError.toolchainInvalid("XcodeDefault.xctoolchain is missing")
        }

        guard fileManager.fileExists(atPath: swiftFrontend.path) else {
            throw MobileBuildBackendError.toolchainInvalid("swift-frontend is missing")
        }

        guard fileManager.fileExists(atPath: iPhoneOSPlatform.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MobileBuildBackendError.toolchainInvalid("iPhoneOS.platform is missing")
        }
    }

    /// Finds the first installed iPhoneOS SDK in the prepared toolchain.
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
