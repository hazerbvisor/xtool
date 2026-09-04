import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Loads the optional compiler engine bundled inside XTool Mobile and invokes
/// Swift's frontend through a small stable C ABI.
///
/// Keeping the heavy Swift/LLVM implementation behind a dylib means the app,
/// UI and build planner can be rebuilt independently from the compiler itself.
public final class MobileCompilerEngine: @unchecked Sendable {
    public static let dylibName = "libXToolCompilerEngine.dylib"

    private typealias FrontendRun = @convention(c) (
        Int32,
        UnsafePointer<UnsafePointer<CChar>?>?
    ) -> Int32
    private typealias VersionRead = @convention(c) () -> UnsafePointer<CChar>?

    private let handle: UnsafeMutableRawPointer
    private let runFrontendFunction: FrontendRun
    public let location: URL
    public let version: String

    private init(
        handle: UnsafeMutableRawPointer,
        runFrontendFunction: @escaping FrontendRun,
        location: URL,
        version: String
    ) {
        self.handle = handle
        self.runFrontendFunction = runFrontendFunction
        self.location = location
        self.version = version
    }

    deinit {
        dlclose(handle)
    }

    public static func loadFromApplicationBundle(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> MobileCompilerEngine {
        let candidates = bundleCandidates(bundle: bundle)
        guard let location = candidates.first(where: {
            fileManager.fileExists(atPath: $0.path)
        }) else {
            throw MobileCompilerEngineError.notBundled(candidates)
        }

        dlerror()
        guard let handle = dlopen(location.path, RTLD_NOW | RTLD_LOCAL) else {
            let message = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
            throw MobileCompilerEngineError.loadFailed(location, message)
        }

        do {
            guard let runSymbol = dlsym(handle, "xtool_swift_frontend_run") else {
                throw MobileCompilerEngineError.missingSymbol("xtool_swift_frontend_run")
            }
            let runFrontend = unsafeBitCast(runSymbol, to: FrontendRun.self)

            var version = "unknown"
            if let versionSymbol = dlsym(handle, "xtool_compiler_engine_version") {
                let readVersion = unsafeBitCast(versionSymbol, to: VersionRead.self)
                if let value = readVersion() {
                    version = String(cString: value)
                }
            }

            return MobileCompilerEngine(
                handle: handle,
                runFrontendFunction: runFrontend,
                location: location,
                version: version
            )
        } catch {
            dlclose(handle)
            throw error
        }
    }

    /// Executes one already-prepared Swift frontend job in-process.
    ///
    /// `swift::performFrontend` expects the arguments that come *after* the
    /// desktop driver's `-frontend` dispatch marker. Strip that marker here as
    /// a defensive compatibility measure so older cached plans cannot feed a
    /// driver-only option to the embedded frontend.
    ///
    /// The embedded frontend writes diagnostics to the process stderr file
    /// descriptor. Capture that descriptor around the call so compiler errors
    /// can be surfaced in XTool Mobile's build log instead of disappearing into
    /// the application process console.
    public func run(_ plan: MobileCompilerPlan) throws -> MobileBuildResult {
        var frontendArguments = plan.arguments
        if frontendArguments.first == "-frontend" {
            frontendArguments.removeFirst()
        }

        let capture = try captureStandardError {
            try withCStringArray(frontendArguments) { argc, argv in
                runFrontendFunction(argc, argv)
            }
        }

        return MobileBuildResult(
            standardError: capture.standardError,
            exitCode: capture.value
        )
    }

    public static func bundleCandidates(bundle: Bundle = .main) -> [URL] {
        var result: [URL] = []
        if let frameworks = bundle.privateFrameworksURL {
            result.append(frameworks.appendingPathComponent(dylibName))
        }
        result.append(
            bundle.bundleURL
                .appendingPathComponent("Frameworks", isDirectory: true)
                .appendingPathComponent(dylibName)
        )
        result.append(bundle.bundleURL.appendingPathComponent(dylibName))

        var seen = Set<String>()
        return result.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func captureStandardError<R>(
        _ body: () throws -> R
    ) throws -> (value: R, standardError: Data) {
        let fileManager = FileManager.default
        let captureURL = fileManager.temporaryDirectory
            .appendingPathComponent("xtool-swift-frontend-\(UUID().uuidString).stderr")

        let captureFD = captureURL.path.withCString {
            open($0, O_CREAT | O_TRUNC | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard captureFD >= 0 else {
            throw MobileCompilerEngineError.diagnosticCaptureFailed(errno)
        }

        let savedStderr = dup(STDERR_FILENO)
        guard savedStderr >= 0 else {
            close(captureFD)
            try? fileManager.removeItem(at: captureURL)
            throw MobileCompilerEngineError.diagnosticCaptureFailed(errno)
        }

        guard dup2(captureFD, STDERR_FILENO) >= 0 else {
            let capturedErrno = errno
            close(savedStderr)
            close(captureFD)
            try? fileManager.removeItem(at: captureURL)
            throw MobileCompilerEngineError.diagnosticCaptureFailed(capturedErrno)
        }

        var bodyResult: Result<R, Error>!
        do {
            bodyResult = .success(try body())
        } catch {
            bodyResult = .failure(error)
        }

        fflush(nil)
        _ = dup2(savedStderr, STDERR_FILENO)
        close(savedStderr)

        _ = lseek(captureFD, 0, SEEK_SET)
        let captureHandle = FileHandle(fileDescriptor: captureFD, closeOnDealloc: true)
        let capturedData = (try? captureHandle.readToEnd()) ?? Data()
        try? captureHandle.close()
        try? fileManager.removeItem(at: captureURL)

        switch bodyResult! {
        case .success(let value):
            return (value, capturedData)
        case .failure(let error):
            throw error
        }
    }

    private func withCStringArray<R>(
        _ strings: [String],
        body: (Int32, UnsafePointer<UnsafePointer<CChar>?>?) throws -> R
    ) rethrows -> R {
        let storage: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        defer {
            for pointer in storage {
                free(pointer)
            }
        }

        var argv: [UnsafePointer<CChar>?] = storage.map { pointer in
            pointer.map { UnsafePointer($0) }
        }
        argv.append(nil)

        return try argv.withUnsafeBufferPointer { buffer in
            try body(Int32(strings.count), buffer.baseAddress)
        }
    }
}

public enum MobileCompilerEngineError: Error, CustomStringConvertible, Sendable {
    case notBundled([URL])
    case loadFailed(URL, String)
    case missingSymbol(String)
    case diagnosticCaptureFailed(Int32)

    public var description: String {
        switch self {
        case .notBundled(let candidates):
            let paths = candidates.map(\.path).joined(separator: ", ")
            return "Compiler engine is not bundled. Searched: \(paths)"
        case .loadFailed(let url, let message):
            return "Could not load compiler engine at \(url.path): \(message)"
        case .missingSymbol(let symbol):
            return "Compiler engine is missing required symbol: \(symbol)"
        case .diagnosticCaptureFailed(let errorNumber):
            return "Could not capture compiler diagnostics (errno \(errorNumber))"
        }
    }
}
