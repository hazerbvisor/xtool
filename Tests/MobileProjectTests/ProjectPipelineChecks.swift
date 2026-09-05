import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw MobileProjectBuildError.invalid("TEST FAILED: " + message) }
}

private final class RecordingCompiler: MobileProjectCompiler, @unchecked Sendable {
    let supportsClangFrontend = true
    let supportsMachOLLD = true
    let location = URL(fileURLWithPath: "/unused/libXToolCompilerEngine.dylib")
    var modules: [String] = []
    var failModule: String?
    var swiftArguments: [[String]] = []
    var linkArguments: [String] = []
    func runSwiftFrontend(arguments: [String]) throws -> MobileBuildResult {
        func value(_ option: String) -> String { arguments[arguments.firstIndex(of: option)! + 1] }
        let name = value("-module-name")
        modules.append(name)
        swiftArguments.append(arguments)
        if name == failModule { return MobileBuildResult(standardError: Data("Expected compiler error".utf8), exitCode: 1) }
        try Data("object".utf8).write(to: URL(fileURLWithPath: value("-o")))
        try Data("module".utf8).write(to: URL(fileURLWithPath: value("-emit-module-path")))
        return MobileBuildResult()
    }
    func runClangFrontend(arguments: [String]) throws -> MobileBuildResult {
        try Data("C object".utf8).write(to: URL(fileURLWithPath: arguments[arguments.firstIndex(of: "-o")! + 1]))
        return MobileBuildResult()
    }
    func runMachOLLD(arguments: [String]) throws -> MobileBuildResult {
        linkArguments = arguments
        let output = URL(fileURLWithPath: arguments[arguments.firstIndex(of: "-o")! + 1])
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1, 0, 0, 0, 0, 2, 0, 0, 0]).write(to: output)
        return MobileBuildResult()
    }
}

@main struct ProjectPipelineChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("xtool-project-tests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let project = try MobileAppStarter.create(in: root)
        let toolchain = PreparedToolchain(root: root.appendingPathComponent("SDKFixture"))
        try fm.createDirectory(at: toolchain.iPhoneOSPlatform.appendingPathComponent("Developer/SDKs/iPhoneOS26.5.sdk"), withIntermediateDirectories: true)
        try fm.createDirectory(at: toolchain.toolchainDirectory.appendingPathComponent("usr/lib/swift/iphoneos"), withIntermediateDirectories: true)
        let engine = RecordingCompiler()
        let output = try MobileProjectBuilder.build(project: project, toolchain: toolchain, engine: engine,
            outputDirectory: root.appendingPathComponent("Success"))
        try require(engine.modules == ["Greeting", "HelloApp"], "dependency compiled before app")
        try require(engine.swiftArguments[1].filter { $0.hasSuffix(".swift") }.count == 2, "all app files compiled together")
        try require(engine.swiftArguments.allSatisfy { $0.contains("prefer-serialized") && !$0.contains("only-serialized") }, "prebuilt loader remains enabled")
        try require(engine.linkArguments.contains("-no_adhoc_codesign"), "unsigned link")
        try require(engine.linkArguments.filter { $0.hasSuffix(".o") }.count == 2, "link all targets")
        let ipaData = try Data(contentsOf: output.ipaURL)
        try require(ipaData.starts(with: [0x50, 0x4b, 0x03, 0x04]), "ZIP archive written")
        try require(ipaData.range(of: Data("Payload/HelloApp.app/Info.plist".utf8)) != nil, "IPA payload layout")

        engine.failModule = "Greeting"
        let failureRoot = root.appendingPathComponent("Failure")
        do {
            _ = try MobileProjectBuilder.build(project: project, toolchain: toolchain, engine: engine, outputDirectory: failureRoot)
            throw MobileProjectBuildError.invalid("TEST FAILED: build succeeded after compiler error")
        } catch MobileProjectBuildError.failed { }
        let failedFiles = fm.enumerator(at: failureRoot, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        try require(!failedFiles.contains { $0.pathExtension == "ipa" }, "failure must not export an IPA")
        try require(failedFiles.contains { $0.lastPathComponent == "build.log" }, "failure log preserved")

        var manifest = try MobileAppManifest.load(from: project.root)
        manifest.targets[0].dependencies = ["HelloApp"]
        do {
            _ = try manifest.orderedTargets()
            throw NSError(domain: "Cycle was not rejected", code: 1)
        } catch MobileProjectBuildError.invalid { }

        let executable = output.ipaURL.deletingLastPathComponent().appendingPathComponent("HelloApp")
        for badPath in ["../escape", "/absolute", "Info.plist", "HelloApp"] {
            do {
                try MobileIPAPackager.packageUnsignedIPA(executableURL: executable,
                    configuration: MobileIPAConfiguration(productName: "Test", executableName: "HelloApp", bundleIdentifier: "com.example.test", displayName: "Test"),
                    additionalFiles: [MobileIPAFile(sourceURL: executable, relativePath: badPath)],
                    outputURL: root.appendingPathComponent("bad.ipa"))
                throw NSError(domain: "Invalid IPA path was accepted", code: 1)
            } catch MobileIPAPackager.PackagerError.invalidArchivePath { }
        }
        print("PASS: dependency order, multi-file jobs, linking, IPA output, failure handling, cycles and archive paths")
    }
}
