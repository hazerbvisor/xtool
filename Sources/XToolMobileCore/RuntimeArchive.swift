import Foundation

public enum MobileRuntimeArchiveError: Error, CustomStringConvertible, Sendable {
    case malformedArchive(String)
    case unsafePath(String)

    public var description: String {
        switch self {
        case .malformedArchive(let reason):
            return "Malformed runtime archive: \(reason)"
        case .unsafePath(let path):
            return "Unsafe runtime archive path: \(path)"
        }
    }
}

/// Minimal TAR extractor used by the mobile port so the app can unpack its
/// bundled Darwin SDK without depending on an external archive package.
/// Supports regular files, directories, and symbolic links from a ustar archive.
public enum MobileRuntimeArchive {
    private static let blockSize = 512

    public static func extractTar(at archiveURL: URL, to destinationURL: URL, fileManager: FileManager = .default) throws {
        let data = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        var offset = 0
        while offset + blockSize <= data.count {
            let header = data.subdata(in: offset..<(offset + blockSize))
            if header.allSatisfy({ $0 == 0 }) { break }

            let name = stringField(header, range: 0..<100)
            let prefix = stringField(header, range: 345..<500)
            let relativePath = prefix.isEmpty ? name : "\(prefix)/\(name)"
            guard !relativePath.isEmpty else {
                throw MobileRuntimeArchiveError.malformedArchive("empty entry name")
            }

            let sizeString = stringField(header, range: 124..<136).trimmingCharacters(in: .whitespacesAndNewlines)
            let size = Int(sizeString, radix: 8) ?? 0
            let typeFlag = header[156]
            let linkName = stringField(header, range: 157..<257)

            let outputURL = try safeDestination(for: relativePath, under: destinationURL)
            let parent = outputURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

            switch typeFlag {
            case 0, 48: // regular file
                let contentStart = offset + blockSize
                let contentEnd = contentStart + size
                guard contentEnd <= data.count else {
                    throw MobileRuntimeArchiveError.malformedArchive("truncated file: \(relativePath)")
                }
                let contents = data.subdata(in: contentStart..<contentEnd)
                if fileManager.fileExists(atPath: outputURL.path) {
                    try fileManager.removeItem(at: outputURL)
                }
                try contents.write(to: outputURL, options: .atomic)

            case 53: // directory
                try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

            case 50: // symbolic link
                if fileManager.fileExists(atPath: outputURL.path) {
                    try fileManager.removeItem(at: outputURL)
                }
                try fileManager.createSymbolicLink(atPath: outputURL.path, withDestinationPath: linkName)

            default:
                // Ignore metadata/special entries that are not needed for the SDK tree.
                break
            }

            let paddedSize = ((size + blockSize - 1) / blockSize) * blockSize
            offset += blockSize + paddedSize
        }
    }

    private static func stringField(_ header: Data, range: Range<Int>) -> String {
        let bytes = header.subdata(in: range)
        let trimmed = bytes.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    private static func safeDestination(for relativePath: String, under root: URL) throws -> URL {
        guard !relativePath.hasPrefix("/") else {
            throw MobileRuntimeArchiveError.unsafePath(relativePath)
        }
        let normalized = NSString(string: relativePath).standardizingPath
        guard normalized != "..", !normalized.hasPrefix("../") else {
            throw MobileRuntimeArchiveError.unsafePath(relativePath)
        }
        return root.appendingPathComponent(normalized)
    }
}
