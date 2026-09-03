import Foundation

/// A SwiftPM project selected from the iOS/iPadOS Files picker.
public struct MobileProject: Sendable, Hashable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var name: String {
        root.lastPathComponent
    }

    public var packageManifest: URL {
        root.appendingPathComponent("Package.swift")
    }

    public var xtoolConfiguration: URL {
        root.appendingPathComponent("xtool.yml")
    }

    public var hasXToolConfiguration: Bool {
        FileManager.default.fileExists(atPath: xtoolConfiguration.path)
    }

    public func validate(fileManager: FileManager = .default) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MobileBuildBackendError.backendUnavailable("Selected project folder is unavailable")
        }

        guard fileManager.fileExists(atPath: packageManifest.path) else {
            throw MobileBuildBackendError.backendUnavailable("Package.swift is missing from the selected project")
        }
    }
}
