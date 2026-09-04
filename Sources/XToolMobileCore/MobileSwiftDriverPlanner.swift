import Foundation
import SwiftDriver
import TSCBasic

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Uses the real Swift 6.3.2 driver to create the frontend invocation that XTool
/// executes in-process. This removes the hand-maintained frontend argument list:
/// SwiftDriver is now responsible for SDK/resource-dir defaults, target features,
/// prebuilt module selection and future compiler-driver behavior.
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
            .deletingLastPathComponent() // lib
            .deletingLastPathComponent() // usr
        let compilerBin = toolchainUSR.appendingPathComponent("bin", isDirectory: true)

        // These are driver-level arguments, deliberately matching the host
        // `swiftc` probe that already succeeds against this Darwin SDK.
        var driverArguments = [
            "swiftc",
            "-c", sourceURL.path,
            "-target", targetTriple,
            "-sdk", sdkURL.path,
            "-resource-dir", swiftResourceDirectory.path,
            "-I", platformResources.path,
        ]
        for path in includeSearchPaths {
            driverArguments += ["-I", path.path]
        }
        driverArguments += [
            "-Xcc", "-isysroot",
            "-Xcc", sdkURL.path,
        ]
        if let clangBuiltinHeaders {
            driverArguments += [
                "-Xcc", "-isystem",
                "-Xcc", clangBuiltinHeaders.path,
            ]
        }
        driverArguments += ["-o", objectURL.path]

        // Tool lookup normally expects runnable sibling executables. On iOS the
        // frontend is a dylib entry point instead, so give SwiftDriver a stable
        // synthetic path and let the executor intercept every frontend launch.
        let syntheticFrontend = compilerBin.appendingPathComponent("swift-frontend")
        let environment = [
            "SWIFT_DRIVER_SWIFT_FRONTEND_EXEC": syntheticFrontend.path,
            "SWIFT_FORCE_MODULE_LOADING": "prefer-serialized",
        ]

        let compilerExecutableDir = try AbsolutePath(validating: compilerBin.path)
        var driver = try Driver(
            args: driverArguments,
            env: environment,
            executor: executor,
            integratedDriver: true,
            compilerExecutableDir: compilerExecutableDir
        )

        let jobs = try driver.planBuild()
        guard let compileJob = jobs.first else {
            throw MobileSwiftDriverPlannerError.noCompileJob
        }

        var resolved = try executor.resolver.resolveArgumentList(
            for: compileJob,
            useResponseFiles: .disabled
        )
        guard !resolved.isEmpty else {
            throw MobileSwiftDriverPlannerError.emptyCommandLine
        }

        // ArgsResolver includes argv[0]. `xtool_swift_frontend_run` consumes the
        // arguments after the executable and after SwiftDriver's dispatch marker.
        resolved.removeFirst()
        if resolved.first == "-frontend" {
            resolved.removeFirst()
        }
        return resolved
    }
}

enum MobileSwiftDriverPlannerError: Error, CustomStringConvertible {
    case compilerEngineNotBundled([URL])
    case compilerEngineLoadFailed(URL, String)
    case missingFrontendSymbol
    case noCompileJob
    case emptyCommandLine
    case unsupportedPlanningWorkload
    case unsupportedTool(String)
    case frontendFailed(Int32, String)
    case streamCaptureFailed(Int32)

    var description: String {
        switch self {
        case .compilerEngineNotBundled(let urls):
            return "SwiftDriver planner could not find the compiler engine: \(urls.map(\.path).joined(separator: ", "))"
        case .compilerEngineLoadFailed(let url, let message):
            return "SwiftDriver planner could not load \(url.path): \(message)"
        case .missingFrontendSymbol:
            return "SwiftDriver planner could not find xtool_swift_frontend_run"
        case .noCompileJob:
            return "SwiftDriver did not produce a compile job"
        case .emptyCommandLine:
            return "SwiftDriver produced an empty frontend command line"
        case .unsupportedPlanningWorkload:
            return "SwiftDriver requested an unsupported incremental planning workload"
        case .unsupportedTool(let tool):
            return "SwiftDriver planning tried to execute unsupported tool: \(tool)"
        case .frontendFailed(let code, let diagnostics):
            return "Swift frontend planning query failed with exit \(code): \(diagnostics)"
        case .streamCaptureFailed(let value):
            return "Could not capture SwiftDriver frontend output (errno \(value))"
        }
    }
}

/// DriverExecutor used only during planning. SwiftDriver asks the frontend for
/// target information and supported features; those queries are executed through
/// the same embedded frontend as the eventual compile, never as child processes.
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
        let arguments = try resolver.resolveArgumentList(for: job, useResponseFiles: handling)
        return try execute(arguments: arguments, environment: [:])
    }

    func execute(
        job: Job,
        forceResponseFiles: Bool,
        recordedInputModificationDates: [TypedVirtualPath: TimePoint]
    ) throws -> ProcessResult {
        try execute(job: job, forceResponseFiles: forceResponseFiles, recordedInputMetadata: [:])
    }

    func execute(
        workload: DriverExecutorWorkload,
        delegate: JobExecutionDelegate,
        numParallelJobs: Int,
        forceResponseFiles: Bool,
        recordedInputMetadata: [TypedVirtualPath: FileMetadata]
    ) throws {
        switch workload.kind {
        case .all(let jobs):
            for job in jobs {
                let args = try resolver.resolveArgumentList(for: job, useResponseFiles: .disabled)
                delegate.jobStarted(job: job, arguments: args, pid: 0)
                let result = try execute(
                    job: job,
                    forceResponseFiles: forceResponseFiles,
                    recordedInputMetadata: recordedInputMetadata
                )
                delegate.jobFinished(job: job, result: result, pid: 0)
            }
        case .incremental:
            throw MobileSwiftDriverPlannerError.unsupportedPlanningWorkload
        }
    }

    func execute(
        workload: DriverExecutorWorkload,
        delegate: JobExecutionDelegate,
        numParallelJobs: Int,
        forceResponseFiles: Bool,
        recordedInputModificationDates: [TypedVirtualPath: TimePoint]
    ) throws {
        try execute(
            workload: workload,
            delegate: delegate,
            numParallelJobs: numParallelJobs,
            forceResponseFiles: forceResponseFiles,
            recordedInputMetadata: [:]
        )
    }

    func execute(
        jobs: [Job],
        delegate: JobExecutionDelegate,
        numParallelJobs: Int,
        forceResponseFiles: Bool,
        recordedInputModificationDates: [TypedVirtualPath: TimePoint]
    ) throws {
        try execute(
            workload: .all(jobs),
            delegate: delegate,
            numParallelJobs: numParallelJobs,
            forceResponseFiles: forceResponseFiles,
            recordedInputMetadata: [:]
        )
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
        return try resolver.resolveArgumentList(for: job, useResponseFiles: handling)
            .joined(separator: " ")
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

/// Tiny frontend-only loader used by SwiftDriver's planning queries. It captures
/// stdout as well as stderr because `-print-target-info` returns JSON on stdout.
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

    deinit {
        dlclose(handle)
    }

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

        let exitCode: Int32
        do {
            exitCode = try body()
        } catch {
            fflush(nil)
            _ = dup2(savedStdout, STDOUT_FILENO)
            _ = dup2(savedStderr, STDERR_FILENO)
            close(savedStdout)
            close(savedStderr)
            close(stdoutFD)
            close(stderrFD)
            try? manager.removeItem(at: stdoutURL)
            try? manager.removeItem(at: stderrURL)
            throw error
        }

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
