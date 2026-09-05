import Foundation

public struct MobileIPAFile: Sendable {
    public let sourceURL: URL
    public let relativePath: String
    public let isExecutable: Bool

    public init(sourceURL: URL, relativePath: String, isExecutable: Bool = false) {
        self.sourceURL = sourceURL
        self.relativePath = relativePath
        self.isExecutable = isExecutable
    }
}

public struct MobileIPAConfiguration: Sendable {
    public let productName: String
    public let executableName: String
    public let bundleIdentifier: String
    public let displayName: String
    public let shortVersion: String
    public let buildVersion: String
    public let minimumOSVersion: String

    public init(
        productName: String,
        executableName: String,
        bundleIdentifier: String,
        displayName: String,
        shortVersion: String = "0.3",
        buildVersion: String = "3",
        minimumOSVersion: String = "16.0"
    ) {
        self.productName = productName
        self.executableName = executableName
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.minimumOSVersion = minimumOSVersion
    }
}

public enum MobileIPAPackager {
    public static func packageUnsignedIPA(
        executableURL: URL,
        configuration: MobileIPAConfiguration,
        additionalFiles: [MobileIPAFile] = [],
        additionalInfoPlist: [String: Any] = [:],
        outputURL: URL
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: executableURL.path) else {
            throw PackagerError.missingInput(executableURL.path)
        }

        try MobileAppManifest.validateName(configuration.productName)
        try MobileAppManifest.validateName(configuration.executableName)
        let appRoot = "Payload/\(configuration.productName).app"
        let infoPlist = try makeInfoPlist(configuration: configuration, additional: additionalInfoPlist)
        var names: Set<String> = [configuration.executableName.lowercased(), "info.plist"]

        var entries: [StoreZIP.Entry] = [
            .file(
                sourceURL: executableURL,
                archivePath: "\(appRoot)/\(configuration.executableName)",
                unixMode: 0o100755
            ),
            .data(
                infoPlist,
                archivePath: "\(appRoot)/Info.plist",
                unixMode: 0o100644
            ),
        ]

        for file in additionalFiles {
            guard fileManager.fileExists(atPath: file.sourceURL.path) else {
                throw PackagerError.missingInput(file.sourceURL.path)
            }
            let relative = file.relativePath
            let key = relative.lowercased()
            guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"),
                  !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !names.contains(where: { $0 == key || $0.hasPrefix(key + "/") || key.hasPrefix($0 + "/") }) else {
                throw PackagerError.invalidArchivePath(file.relativePath)
            }
            names.insert(key)
            entries.append(
                .file(
                    sourceURL: file.sourceURL,
                    archivePath: "\(appRoot)/\(relative)",
                    unixMode: file.isExecutable ? 0o100755 : 0o100644
                )
            )
        }

        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Write alongside the destination; failures never expose a partial IPA.
        let temporary = outputURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).ipa")
        defer { try? fileManager.removeItem(at: temporary) }
        try StoreZIP.write(entries: entries, to: temporary)
        if fileManager.fileExists(atPath: outputURL.path) {
            _ = try fileManager.replaceItemAt(outputURL, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: outputURL)
        }
    }

    private static func makeInfoPlist(configuration: MobileIPAConfiguration, additional: [String: Any]) throws -> Data {
        var plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleDisplayName": configuration.displayName,
            "CFBundleExecutable": configuration.executableName,
            "CFBundleIdentifier": configuration.bundleIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": configuration.productName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": configuration.shortVersion,
            "CFBundleVersion": configuration.buildVersion,
            "LSRequiresIPhoneOS": true,
            "MinimumOSVersion": configuration.minimumOSVersion,
            "UIDeviceFamily": [1, 2],
            "UILaunchScreen": [:] as [String: Any],
            "UISupportedInterfaceOrientations": [
                "UIInterfaceOrientationPortrait",
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight",
            ],
            "UISupportedInterfaceOrientations~ipad": [
                "UIInterfaceOrientationPortrait",
                "UIInterfaceOrientationPortraitUpsideDown",
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight",
            ],
        ]
        plist.merge(additional) { _, custom in custom }
        // Identity and executable paths must agree with what was actually packaged.
        plist["CFBundleExecutable"] = configuration.executableName
        plist["CFBundleIdentifier"] = configuration.bundleIdentifier
        plist["CFBundlePackageType"] = "APPL"
        plist["MinimumOSVersion"] = configuration.minimumOSVersion
        return try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }

    public enum PackagerError: Error, CustomStringConvertible {
        case missingInput(String)
        case invalidArchivePath(String)
        case fileTooLarge(String)
        case archiveTooLarge

        public var description: String {
            switch self {
            case .missingInput(let path):
                return "missing IPA input: \(path)"
            case .invalidArchivePath(let path):
                return "invalid IPA archive path: \(path)"
            case .fileTooLarge(let path):
                return "ZIP32 cannot package a file larger than 4 GiB: \(path)"
            case .archiveTooLarge:
                return "ZIP32 archive exceeded 4 GiB"
            }
        }
    }
}

private enum StoreZIP {
    enum Entry {
        case file(sourceURL: URL, archivePath: String, unixMode: UInt32)
        case data(Data, archivePath: String, unixMode: UInt32)

        var archivePath: String {
            switch self {
            case .file(_, let path, _), .data(_, let path, _): return path
            }
        }

        var unixMode: UInt32 {
            switch self {
            case .file(_, _, let mode), .data(_, _, let mode): return mode
            }
        }
    }

    private struct PreparedEntry {
        let entry: Entry
        let nameData: Data
        let crc32: UInt32
        let size: UInt32
        let dosTime: UInt16
        let dosDate: UInt16
        let localHeaderOffset: UInt32
    }

    static func write(entries: [Entry], to outputURL: URL) throws {
        guard entries.count <= Int(UInt16.max) else { throw MobileIPAPackager.PackagerError.archiveTooLarge }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        var offset: UInt64 = 0
        var prepared: [PreparedEntry] = []
        prepared.reserveCapacity(entries.count)

        for entry in entries {
            let metadata = try metadata(for: entry)
            guard offset <= UInt64(UInt32.max) else {
                throw MobileIPAPackager.PackagerError.archiveTooLarge
            }

            let nameData = Data(entry.archivePath.utf8)
            guard nameData.count <= Int(UInt16.max) else {
                throw MobileIPAPackager.PackagerError.invalidArchivePath(entry.archivePath)
            }
            let (dosTime, dosDate) = dosTimestamp(Date())
            var header = Data()
            header.appendLE(UInt32(0x04034b50))
            header.appendLE(UInt16(20))
            header.appendLE(UInt16(0x0800)) // UTF-8 names
            header.appendLE(UInt16(0)) // stored, no compression
            header.appendLE(dosTime)
            header.appendLE(dosDate)
            header.appendLE(metadata.crc32)
            header.appendLE(metadata.size)
            header.appendLE(metadata.size)
            header.appendLE(UInt16(nameData.count))
            header.appendLE(UInt16(0))
            header.append(nameData)

            try handle.write(contentsOf: header)
            offset += UInt64(header.count)
            try writeBody(of: entry, to: handle) { bytes in
                offset += UInt64(bytes)
            }

            prepared.append(
                PreparedEntry(
                    entry: entry,
                    nameData: nameData,
                    crc32: metadata.crc32,
                    size: metadata.size,
                    dosTime: dosTime,
                    dosDate: dosDate,
                    localHeaderOffset: UInt32(offset - UInt64(metadata.size) - UInt64(header.count))
                )
            )
        }

        guard offset <= UInt64(UInt32.max) else {
            throw MobileIPAPackager.PackagerError.archiveTooLarge
        }
        let centralStart = UInt32(offset)

        for item in prepared {
            var header = Data()
            header.appendLE(UInt32(0x02014b50))
            header.appendLE(UInt16(0x031E)) // created by UNIX, ZIP 3.0
            header.appendLE(UInt16(20))
            header.appendLE(UInt16(0x0800))
            header.appendLE(UInt16(0))
            header.appendLE(item.dosTime)
            header.appendLE(item.dosDate)
            header.appendLE(item.crc32)
            header.appendLE(item.size)
            header.appendLE(item.size)
            header.appendLE(UInt16(item.nameData.count))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(item.entry.unixMode << 16)
            header.appendLE(item.localHeaderOffset)
            header.append(item.nameData)
            try handle.write(contentsOf: header)
            offset += UInt64(header.count)
        }

        guard offset <= UInt64(UInt32.max) else {
            throw MobileIPAPackager.PackagerError.archiveTooLarge
        }
        let centralSize = UInt32(offset) - centralStart
        guard prepared.count <= Int(UInt16.max) else {
            throw MobileIPAPackager.PackagerError.archiveTooLarge
        }

        var end = Data()
        end.appendLE(UInt32(0x06054b50))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(prepared.count))
        end.appendLE(UInt16(prepared.count))
        end.appendLE(centralSize)
        end.appendLE(centralStart)
        end.appendLE(UInt16(0))
        try handle.write(contentsOf: end)
    }

    private static func metadata(for entry: Entry) throws -> (crc32: UInt32, size: UInt32) {
        switch entry {
        case .data(let data, _, _):
            guard data.count <= Int(UInt32.max) else {
                throw MobileIPAPackager.PackagerError.archiveTooLarge
            }
            return (CRC32.checksum(data), UInt32(data.count))

        case .file(let url, _, _):
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            guard fileSize <= UInt64(UInt32.max) else {
                throw MobileIPAPackager.PackagerError.fileTooLarge(url.path)
            }
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            var crc = CRC32.initial
            while true {
                let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                crc = CRC32.update(crc, with: chunk)
            }
            return (CRC32.finalize(crc), UInt32(fileSize))
        }
    }

    private static func writeBody(
        of entry: Entry,
        to handle: FileHandle,
        didWrite: (Int) -> Void
    ) throws {
        switch entry {
        case .data(let data, _, _):
            try handle.write(contentsOf: data)
            didWrite(data.count)

        case .file(let url, _, _):
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            while true {
                let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                try handle.write(contentsOf: chunk)
                didWrite(chunk.count)
            }
        }
    }

    private static func dosTimestamp(_ date: Date) -> (UInt16, UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents(
            in: TimeZone.current,
            from: date
        )
        let year = min(max(parts.year ?? 1980, 1980), 2107)
        let month = min(max(parts.month ?? 1, 1), 12)
        let day = min(max(parts.day ?? 1, 1), 31)
        let hour = min(max(parts.hour ?? 0, 0), 23)
        let minute = min(max(parts.minute ?? 0, 0), 59)
        let second = min(max(parts.second ?? 0, 0), 59)

        let dosTime = UInt16((hour << 11) | (minute << 5) | (second / 2))
        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }
}

private enum CRC32 {
    static let initial: UInt32 = 0xFFFF_FFFF

    static func checksum(_ data: Data) -> UInt32 {
        finalize(update(initial, with: data))
    }

    static func update(_ crc: UInt32, with data: Data) -> UInt32 {
        var value = crc
        for byte in data {
            var current = (value ^ UInt32(byte)) & 0xFF
            for _ in 0..<8 {
                current = (current & 1) != 0
                    ? (current >> 1) ^ 0xEDB8_8320
                    : (current >> 1)
            }
            value = (value >> 8) ^ current
        }
        return value
    }

    static func finalize(_ crc: UInt32) -> UInt32 {
        crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { rawBuffer in
            append(contentsOf: rawBuffer)
        }
    }
}
