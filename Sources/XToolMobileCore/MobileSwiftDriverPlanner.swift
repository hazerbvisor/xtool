import Foundation
import SwiftDriver
import TSCBasic

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum MobileSwiftDriverPlanner {
    static func frontendArguments(
        sourceURL: URL,
        objectURL: URL,
        sdkURL: URL,
        swiftResourceDirectory: URL,
        targetTriple: String,
        includeSearchPaths: [URL],
        clangBuiltinHeaders: URL?
    ) throws -> [String] {
        let runner = try EmbeddedSwiftFrontendRunner.loadFromApplicationBundle()
        let executor = try InProcessPlanningExecutor(runner: runner)

        let platformResources = swiftResourceDirectory
            .appendingPathComponent("iphoneos", isDirectory: true)
        let toolchainUSR = swiftResourceDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let compilerBin = toolchainUSR.appendingPathComponent("bin", isDirectory: true)

        // The runtime builder compiles Apple's textual Swift stdlib interface
        // once on the Linux host using the exact upstream Swift toolchain that
        // also backs the embedded compiler. Always point FrontendTool at that
        // distribution-matched cache. Without this explicit frontend option the
        // embedded compiler falls back to the SDK's Apple Swift.swiftinterface.
        let sdkVersion = try resolvedSDKVersion(sdkURL: sdkURL)
        let prebuiltModuleCache = platformResources
            .appendingPathComponent("xtool-prebuilt-modules", isDirectory: true)
            .appendingPathComponent(sdkVersion, isDirectory: true)
        let swiftModuleDirectory = prebuiltModuleCache
            .appendingPathComponent("Swift.swiftmodule", isDirectory: true)
        let swiftModuleCandidates = [
            swiftModuleDirectory.appendingPathComponent("arm64e-apple-ios.swiftmodule"),
            swiftModuleDirectory.appendingPathComponent("arm64-apple-ios.swiftmodule"),
        ]
        guard swiftModuleCandidates.contains(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw MobileSwiftDriverPlannerError.missingPrebuiltSwiftModule(
                swiftModuleCandidates
            )
        }

        // Never let Swift/Clang fall back to ~/.cache on iOS. That location is
        // outside the app's writable sandbox and causes SwiftShims PCM creation
        // to fail with EPERM. Keep both Swift and Clang module caches next to
        // the probe output, which is already inside Application Support.
        let cacheRoot = objectURL.deletingLastPathComponent()
        let moduleCache = cacheRoot.appendingPathComponent("ModuleCache-SwiftDriver", isDirectory: true)
        let sdkModuleCache = cacheRoot.appendingPathComponent("SDKModuleCache-SwiftDriver", isDirectory: true)
        try FileManager.default.createDirectory(
            at: moduleCache,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sdkModuleCache,
            withIntermediateDirectories: true
        )

        // Driver-level invocation matching the already-successful Linux swiftc probe.
        var driverArguments = [
            "swiftc",
            "-c", sourceURL.path,
            "-target", targetTriple,
            "-sdk", sdkURL.path,
            "-resource-dir", swiftResourceDirectory.path,
            "-module-cache-path", moduleCache.path,
            "-sdk-module-cache-path", sdkModuleCache.path,
            "-I", platformResources.path,
        ]
        for path in includeSearchPaths {
            driverArguments += ["-I", path.path]
        }
        driverArguments += [
            "-Xcc", "-isysroot",
            "-Xcc", sdkURL.path,
            // Belt-and-suspenders: ClangImporter ultimately owns the PCM cache.
            // Force its cache to the same writable directory even if frontend
            // defaults or environment variables change in a future toolchain.
            "-Xcc", "-fmodules-cache-path=\(moduleCache.path)",
        ]
        if let clangBuiltinHeaders {
            driverArguments += [
                "-Xcc", "-isystem",
                "-Xcc", clangBuiltinHeaders.path,
            ]
        }

        // These are frontend-only options, so send them through -Xfrontend
        // instead of relying on process environment inherited by SwiftDriver.
        // The in-process frontend is not a child process and therefore does not
        // automatically receive Driver.env.
        driverArguments += [
            "-Xfrontend", "-prebuilt-module-cache-path",
            "-Xfrontend", prebuiltModuleCache.path,
            "-Xfrontend", "-module-load-mode",
            "-Xfrontend", "prefer-serialized",
            "-Xfrontend", "-disable-modules-validate-system-headers",
            "-Xfrontend", "-Rmodule-loading",
            "-o", objectURL.path,
        ]

        // SwiftDriver only needs a path identity. The executor below intercepts
        // the launch and enters xtool_swift_frontend_run in-process.
        let syntheticFrontend = compilerBin.appendingPathComponent("swift-frontend")
        let environment = [
            "SWIFT_DRIVER_SWIFT_FRONTEND_EXEC": syntheticFrontend.path,
            "SWIFT_FORCE_MODULE_LOADING": "prefer-serialized",
        ]

        var driver = try Driver(
            args: driverArguments,
            env: environment,
            executor: executor,
            integratedDriver: true,
            compilerExecutableDir: try AbsolutePath(validating: compilerBin.path)
        )

        let jobs = try driver.planBuild()
        guard let compileJob = jobs.first(where: { $0.kind == .compile }) else {
            throw MobileSwiftDriverPlannerError.noCompileJob
        }

        var resolved: [String] = try executor.resolver.resolveArgumentList(
            for: compileJob,
            useResponseFiles: .disabled
        )
        guard !resolved.isEmpty else {
            throw MobileSwiftDriverPlannerError.emptyCommandLine
        }

        resolved.removeFirst() // argv[0]
        if resolved.first == "-frontend" {
            resolved.removeFirst()
        }
        return resolved
    }

    private static func resolvedSDKVersion(sdkURL: URL) throws -> String {
        let stem = sdkURL.deletingPathExtension().lastPathComponent
        let prefix = "iPhoneOS"
        if stem.hasPrefix(prefix) {
            let suffix = String(stem.dropFirst(prefix.count))
            if !suffix.isEmpty {
                return suffix
            }
        }

        let settingsURL = sdkURL.appendingPathComponent("SDKSettings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = object["Version"] as? String,
           !version.isEmpty {
            return version
        }

        throw MobileSwiftDriverPlannerError.missingSDKVersion(sdkURL)
    }
}

enum MobileSwiftDriverPlannerError: Error, CustomStringConvertible {
    case compilerEngineNotBundled([URL])
    case compilerEngineLoadFailed(URL, String)
    case missingFrontendSymbol
    case noCompileJob
    case emptyCommandLine
    case unsupportedTool(String)
    case frontendFailed(Int32, String)
    case streamCaptureFailed(Int32)
    case missingSDKVersion(URL)
    case missingPrebuiltSwiftModule([URL])

    var description: String {
        switch self {
        case .compilerEngineNotBundled(let urls):
            return "SwiftDriver planner could not find compiler engine: \(urls.map(\.path).joined(separator: ", "))"
        case .compilerEngineLoadFailed(let url, let message):
            return "SwiftDriver planner could not load \(url.path): \(message)"
        case .missingFrontendSymbol:
            return "SwiftDriver planner could not find xtool_swift_frontend_run"
        case .noCompileJob:
            return "SwiftDriver did not produce a compile job"
        case .emptyCommandLine:
            return "SwiftDriver produced an empty command line"
        case .unsupportedTool(let tool):
            return "SwiftDriver planning requested unsupported tool: \(tool)"
        case .frontendFailed(let code, let diagnostics):
            return "Swift frontend planning query failed with exit \(code): \(diagnostics)"
        case .streamCaptureFailed(let value):
            return "Could not capture SwiftDriver frontend output (errno \(value))"
        case .missingSDKVersion(let sdkURL):
            return "Could not determine SDK version for prebuilt modules: \(sdkURL.path)"
        case .missingPrebuiltSwiftModule(let urls):
            return "Prepared runtime is missing XTool's upstream Swift module. Searched: \(urls.map(\.path).joined(separator: ", "))"
        }
    }
}

/// Equivalent to SwiftDriver's SimpleExecutor, except every frontend query is
/// routed into the compiler dylib instead of creating a child process.
private final class InProcessPlanningExecutor: DriverExecutor {
    let resolver: ArgsResolver
    private let runner: EmbeddedSwiftFrontendRunner

    init(runner: EmbeddedSwiftFrontendRunner) throws {
        self.runner = runner
        self.resolver = try ArgsResolver(fileSystem: localFileSystem)
    }

    func execute(
        job: Job,
        forceResponseFiles: Bool,
        recordedInputMetadata: [TypedVirtualPath: FileMetadata]
    ) throws -> ProcessResult {
        let handling: ResponseFileHandling = forceResponseFiles ? .forced : .disabled
        let arguments: [String] = try resolver.resolveArgumentList(
            for: job,
            useResponseFiles: handling
        )
        return try execute(arguments: arguments, environment: [:])
    }

    // SwiftDriver planning does not use these legacy/multi-job entry points.
    func execute(
        job: Job,
        forceResponseFiles: Bool,
        recordedInputModificationDates: [TypedVirtualPath: TimePoint]
    ) throws -> ProcessResult {
        fatalError("Unsupported legacy SwiftDriver executor entry point")
    }

    func execute(
        workload: DriverExecutorWorkload,
        delegate: JobExecutionDelegate,
        numParallelJobs: Int,
        forceResponseFiles: Bool,
        recordedInputMetadata: [TypedVirtualPath: FileMetadata]
    ) throws {
        fatalError("SwiftDriver planning unexpectedly requested workload execution")
    }

    func execute(
        workload: DriverExecutorWorkload,
        delegate: JobExecutionDelegate,
        numParallelJobs: Int,
        forceResponseFiles: Bool,
        recordedInputModificationDates: [TypedVirtualPath: FileMetadata]
    ) throws {
        fatalError("Unsupported legacy SwiftDriver executor entry point")
    }

    func execute(
        jobs: [Job],
        delegate: JobExecutionDelegate,
        numParallelJobs: Int,
        forceResponseFiles: Bool,
        recordedInputModificationDates: [TypedVirtualPath: TimePoint]
    ) throws {
        fatalError("Unsupported legacy SwiftDriver executor entry point")
    }

    func checkNonZeroExit(args: String..., environment: [String: String]) throws -> String {
        let result = try execute(arguments: args, environment: environment)
        guard result.exitStatus == .terminated(code: 0) else {
            let diagnostics = (try? result.utf8stderrOutput()) ?? ""
            let code: Int32
            switch result.exitStatus {
            case .terminated(let value): code = value
            #if os(Windows)
            case .abnormal: code = 1
            #else
            case .signalled(let signal): code = 128 + signal
            #endif
            }
            throw MobileSwiftDriverPlannerError.frontendFailed(code, diagnostics)
        }
        return try result.utf8Output()
    }

    func description(of job: Job, forceResponseFiles: Bool) throws -> String {
        let handling: ResponseFileHandling = forceResponseFiles ? .forced : .disabled
        let arguments: [String] = try resolver.resolveArgumentList(
            for: job,
            useResponseFiles: handling
        )
        return arguments.joined(separator: " ")
    }

    private func execute(arguments: [String], environment: [String: String]) throws -> ProcessResult {
        guard let executable = arguments.first else {
            throw MobileSwiftDriverPlannerError.emptyCommandLine
        }
        let tool = URL(fileURLWithPath: executable).lastPathComponent
        guard tool == "swift-frontend" || tool == "swift" else {
            throw MobileSwiftDriverPlannerError.unsupportedTool(tool)
        }

        var frontendArguments = Array(arguments.dropFirst())
        if frontendArguments.first == "-frontend" {
            frontendArguments.removeFirst()
        }
        let result = try runner.run(arguments: frontendArguments)

        return ProcessResult(
            arguments: arguments,
            environment: environment,
            exitStatus: .terminated(code: result.exitCode),
            output: .success(Array(result.standardOutput)),
            stderrOutput: .success(Array(result.standardError))
        )
    }
}

/// Frontend-only dylib loader for SwiftDriver's planning queries. Unlike the
/// normal compile bridge it captures stdout too, because -print-target-info
/// returns JSON there.
private final class EmbeddedSwiftFrontendRunner {
    private typealias NativeRun = @convention(c) (
        Int32,
        UnsafePointer<UnsafePointer<CChar>?>?
    ) -> Int32

    private let handle: UnsafeMutableRawPointer
    private let runFunction: NativeRun

    private init(handle: UnsafeMutableRawPointer, runFunction: @escaping NativeRun) {
        self.handle = handle
        self.runFunction = runFunction
    }

    deinit { dlclose(handle) }

    static func loadFromApplicationBundle(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> EmbeddedSwiftFrontendRunner {
        let candidates = MobileCompilerEngine.bundleCandidates(bundle: bundle)
        guard let location = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw MobileSwiftDriverPlannerError.compilerEngineNotBundled(candidates)
        }

        dlerror()
        guard let handle = dlopen(location.path, RTLD_NOW | RTLD_LOCAL) else {
            let message = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
            throw MobileSwiftDriverPlannerError.compilerEngineLoadFailed(location, message)
        }
        guard let symbol = dlsym(handle, "xtool_swift_frontend_run") else {
            dlclose(handle)
            throw MobileSwiftDriverPlannerError.missingFrontendSymbol
        }
        return EmbeddedSwiftFrontendRunner(
            handle: handle,
            runFunction: unsafeBitCast(symbol, to: NativeRun.self)
        )
    }

    func run(arguments: [String]) throws -> MobileBuildResult {
        try captureStandardStreams {
            try withCStringArray(arguments) { argc, argv in
                runFunction(argc, argv)
            }
        }
    }

    private func captureStandardStreams(
        _ body: () throws -> Int32
    ) throws -> MobileBuildResult {
        let manager = FileManager.default
        let stem = "xtool-swiftdriver-\(UUID().uuidString)"
        let stdoutURL = manager.temporaryDirectory.appendingPathComponent("\(stem).stdout")
        let stderrURL = manager.temporaryDirectory.appendingPathComponent("\(stem).stderr")

        let stdoutFD = stdoutURL.path.withCString {
            open($0, O_CREAT | O_TRUNC | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard stdoutFD >= 0 else {
            throw MobileSwiftDriverPlannerError.streamCaptureFailed(errno)
        }
        let stderrFD = stderrURL.path.withCString {
            open($0, O_CREAT | O_TRUNC | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard stderrFD >= 0 else {
            close(stdoutFD)
            throw MobileSwiftDriverPlannerError.streamCaptureFailed(errno)
        }

        let savedStdout = dup(STDOUT_FILENO)
        let savedStderr = dup(STDERR_FILENO)
        guard savedStdout >= 0, savedStderr >= 0 else {
            if savedStdout >= 0 { close(savedStdout) }
            if savedStderr >= 0 { close(savedStderr) }
            close(stdoutFD)
            close(stderrFD)
            throw MobileSwiftDriverPlannerError.streamCaptureFailed(errno)
        }

        guard dup2(stdoutFD, STDOUT_FILENO) >= 0, dup2(stderrFD, STDERR_FILENO) >= 0 else {
            let captured = errno
            _ = dup2(savedStdout, STDOUT_FILENO)
            _ = dup2(savedStderr, STDERR_FILENO)
            close(savedStdout)
            close(savedStderr)
            close(stdoutFD)
            close(stderrFD)
            throw MobileSwiftDriverPlannerError.streamCaptureFailed(captured)
        }

        let exitCode = try body()
        fflush(nil)
        _ = dup2(savedStdout, STDOUT_FILENO)
        _ = dup2(savedStderr, STDERR_FILENO)
        close(savedStdout)
        close(savedStderr)

        _ = lseek(stdoutFD, 0, SEEK_SET)
        _ = lseek(stderrFD, 0, SEEK_SET)
        let stdoutHandle = FileHandle(fileDescriptor: stdoutFD, closeOnDealloc: true)
        let stderrHandle = FileHandle(fileDescriptor: stderrFD, closeOnDealloc: true)
        let stdout = (try? stdoutHandle.readToEnd()) ?? Data()
        let stderr = (try? stderrHandle.readToEnd()) ?? Data()
        try? stdoutHandle.close()
        try? stderrHandle.close()
        try? manager.removeItem(at: stdoutURL)
        try? manager.removeItem(at: stderrURL)

        return MobileBuildResult(
            standardOutput: stdout,
            standardError: stderr,
            exitCode: exitCode
        )
    }

    private func withCStringArray<R>(
        _ strings: [String],
        body: (Int32, UnsafePointer<UnsafePointer<CChar>?>?) throws -> R
    ) rethrows -> R {
        let storage: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        defer { storage.forEach { free($0) } }

        var argv: [UnsafePointer<CChar>?] = storage.map { pointer in
            pointer.map { UnsafePointer($0) }
        }
        argv.append(nil)
        return try argv.withUnsafeBufferPointer { buffer in
            try body(Int32(strings.count), buffer.baseAddress)
        }
    }
}
