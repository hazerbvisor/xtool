import SwiftUI
import UniformTypeIdentifiers
import XToolMobileCore

@main
struct XToolMobileApp: App {
    var body: some Scene {
        WindowGroup {
            MobileHomeView()
        }
    }
}

private struct MobileHomeView: View {
    private let capabilities = MobilePlatformCapabilities.current()

    @State private var project: MobileProject?
    @State private var toolchain: PreparedToolchain?
    @State private var helloPlan: MobileCompilerPlan?
    @State private var compilerEngine: MobileCompilerEngine?
    @State private var compilerEngineStatus = "Not bundled"
    @State private var projectScopeURL: URL?
    @State private var toolchainScopeURL: URL?
    @State private var toolchainSource = "None"
    @State private var showingProjectImporter = false
    @State private var showingToolchainImporter = false
    @State private var logLines: [String] = ["xtool mobile ready"]
    @State private var attemptedBundledRuntimeDiscovery = false
    @State private var attemptedCompilerEngineDiscovery = false
    @State private var isPreparingBundledRuntime = false
    @State private var isCompilingHello = false
    @State private var isRunningNativeProbe = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    Button {
                        showingProjectImporter = true
                    } label: {
                        Label("Choose Project Folder", systemImage: "folder")
                    }

                    if let project {
                        LabeledContent("Name", value: project.name)
                        LabeledContent("Package.swift", value: "Found")
                        LabeledContent("xtool.yml", value: project.hasXToolConfiguration ? "Found" : "Not present")
                    } else {
                        Text("Project import is optional for the first compiler test. Hello.swift runs from xtool's sandbox.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Darwin SDK") {
                    if isPreparingBundledRuntime {
                        HStack {
                            ProgressView()
                            Text("Unpacking bundled runtime…")
                        }
                    }

                    if let toolchain {
                        LabeledContent("Source", value: toolchainSource)
                        LabeledContent("iPhoneOS SDK", value: sdkDisplayName(toolchain))
                        LabeledContent(
                            "Standalone frontend",
                            value: toolchain.hasBundledSwiftFrontend ? "Present" : "Not required"
                        )
                    } else if !isPreparingBundledRuntime {
                        Button {
                            showingToolchainImporter = true
                        } label: {
                            Label("Import External Darwin SDK", systemImage: "shippingbox")
                        }

                        Text("No usable bundled runtime was found. You can still import the prepared runtime from Files.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Compiler Bridge Probe") {
                    Button {
                        runCompilerProbe()
                    } label: {
                        Label("Run SDK + VM Probe", systemImage: "checkmark.seal")
                    }
                    .disabled(toolchain == nil)

                    LabeledContent("Execution", value: MobileCompilerBridgeContract.executionModel)
                    LabeledContent("Backend", value: "FrontendTool")
                    LabeledContent("Engine", value: compilerEngineStatus)
                    LabeledContent(
                        "Clang frontend",
                        value: compilerEngine?.supportsClangFrontend == true ? "Ready" : "Not bundled"
                    )
                    LabeledContent(
                        "Mach-O LLD",
                        value: compilerEngine?.supportsMachOLLD == true ? "Ready" : "Not bundled"
                    )
                    LabeledContent("Architecture", value: capabilities.architecture)
                    LabeledContent("iOS family", value: capabilities.isRunningOnIOSFamily ? "Yes" : "No")
                    LabeledContent(
                        "Physical memory",
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(capabilities.physicalMemory),
                            countStyle: .memory
                        )
                    )
                }

                Section("Hello.swift AOT Job") {
                    Button {
                        prepareHelloCompilerJob()
                    } label: {
                        Label("Prepare Hello.swift", systemImage: "hammer.circle")
                    }
                    .disabled(toolchain == nil || isCompilingHello || isRunningNativeProbe)

                    Button {
                        compileHello()
                    } label: {
                        if isCompilingHello {
                            HStack {
                                ProgressView()
                                Text("Compiling Hello.swift…")
                            }
                        } else {
                            Label("Compile Hello.swift", systemImage: "play.circle.fill")
                        }
                    }
                    .disabled(helloPlan == nil || compilerEngine == nil || isCompilingHello || isRunningNativeProbe)

                    if let helloPlan {
                        LabeledContent("Target", value: helloPlan.targetTriple)
                        LabeledContent("Source", value: helloPlan.sourceURL.lastPathComponent)
                        LabeledContent("Output", value: helloPlan.objectURL.lastPathComponent)
                        Text(
                            compilerEngine == nil
                                ? "The frontend job is ready. Bundle libXToolCompilerEngine.dylib to execute it in-process."
                                : "Compiler engine is loaded. Compile should produce a real arm64 iOS Hello.o without spawning a process."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                Section("C + Mach-O Bootstrap") {
                    Button {
                        runClangLLDProbe()
                    } label: {
                        if isRunningNativeProbe {
                            HStack {
                                ProgressView()
                                Text("Compiling + linking C probe…")
                            }
                        } else {
                            Label("Run C + LLD Probe", systemImage: "link.circle.fill")
                        }
                    }
                    .disabled(
                        toolchain == nil ||
                        compilerEngine?.supportsClangFrontend != true ||
                        compilerEngine?.supportsMachOLLD != true ||
                        isRunningNativeProbe ||
                        isCompilingHello
                    )

                    Text("Compiles Hello.c to an arm64 iOS object with embedded Clang, then links it to a Mach-O executable with embedded LLD. No subprocesses are used.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Build Log") {
                    ScrollView {
                        Text(logLines.joined(separator: "\n"))
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                    .frame(minHeight: 220)
                }
            }
            .navigationTitle("xtool")
        }
        .onAppear {
            discoverCompilerEngineIfNeeded()
            discoverBundledRuntimeIfNeeded()
        }
        .fileImporter(
            isPresented: $showingProjectImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            importProject(result)
        }
        .fileImporter(
            isPresented: $showingToolchainImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            importToolchain(result)
        }
    }

    private func discoverCompilerEngineIfNeeded() {
        guard !attemptedCompilerEngineDiscovery else { return }
        attemptedCompilerEngineDiscovery = true

        do {
            let engine = try MobileCompilerEngine.loadFromApplicationBundle()
            compilerEngine = engine
            compilerEngineStatus = "Loaded: \(engine.version)"
            appendLog("compiler engine: loaded")
            appendLog("compiler engine version: \(engine.version)")
            appendLog("compiler engine path: \(engine.location.path)")
            appendLog("compiler engine clang: \(engine.supportsClangFrontend ? "ready" : "missing")")
            appendLog("compiler engine lld-macho: \(engine.supportsMachOLLD ? "ready" : "missing")")
        } catch {
            compilerEngine = nil
            compilerEngineStatus = "Not bundled"
            appendLog("compiler engine: not bundled yet")
        }
    }

    private func discoverBundledRuntimeIfNeeded() {
        guard !attemptedBundledRuntimeDiscovery else { return }
        attemptedBundledRuntimeDiscovery = true

        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            appendLog("bundled runtime: Application Support unavailable")
            return
        }

        let extractedRoot = applicationSupport.appendingPathComponent(
            "XToolMobileRuntime",
            isDirectory: true
        )

        let existing = PreparedToolchain(root: extractedRoot)
        if (try? existing.validate()) != nil {
            toolchain = existing
            toolchainScopeURL = nil
            toolchainSource = "Bundled archive"
            appendLog("bundled runtime cache: valid")
            appendLog("SDK: \(sdkDisplayName(existing))")
            return
        }

        guard let archiveURL = Bundle.main.url(
            forResource: "MobileRuntime",
            withExtension: "tar"
        ) else {
            appendLog("bundled runtime archive: not present")
            return
        }

        isPreparingBundledRuntime = true
        appendLog("bundled runtime archive: found")
        appendLog("bundled runtime: extracting to Application Support...")

        Task {
            do {
                let selected = try await Task.detached(priority: .userInitiated) {
                    let fileManager = FileManager.default
                    try fileManager.createDirectory(
                        at: applicationSupport,
                        withIntermediateDirectories: true
                    )

                    if fileManager.fileExists(atPath: extractedRoot.path) {
                        try fileManager.removeItem(at: extractedRoot)
                    }

                    try MobileRuntimeArchive.extractTar(
                        at: archiveURL,
                        to: applicationSupport
                    )

                    let selected = PreparedToolchain(root: extractedRoot)
                    try selected.validate()
                    return selected
                }.value

                toolchain = selected
                toolchainScopeURL = nil
                toolchainSource = "Bundled archive"
                isPreparingBundledRuntime = false
                appendLog("bundled runtime: extracted + valid")
                appendLog("SDK: \(sdkDisplayName(selected))")
            } catch {
                isPreparingBundledRuntime = false
                appendLog("bundled runtime extraction failed: \(String(describing: error))")
            }
        }
    }

    private func importProject(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            releaseSecurityScope(for: projectScopeURL)
            _ = url.startAccessingSecurityScopedResource()

            let selected = MobileProject(root: url)
            try selected.validate()
            project = selected
            projectScopeURL = url
            appendLog("project: \(selected.name)")
            appendLog("Package.swift: found")
        } catch {
            appendLog("project import failed: \(String(describing: error))")
        }
    }

    private func importToolchain(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            releaseSecurityScope(for: toolchainScopeURL)
            _ = url.startAccessingSecurityScopedResource()

            let selected = PreparedToolchain(root: url)
            try selected.validate()
            let sdk = try selected.iPhoneOSSDK()
            toolchain = selected
            toolchainScopeURL = url
            toolchainSource = "Files"
            appendLog("external Darwin SDK tree: valid")
            appendLog("SDK: \(sdk.lastPathComponent)")
        } catch {
            appendLog("Darwin SDK import failed: \(String(describing: error))")
        }
    }

    private func runCompilerProbe() {
        guard let toolchain else {
            appendLog("probe failed: no Darwin SDK selected")
            return
        }

        do {
            appendLog("probe: validating Darwin SDK...")
            try toolchain.validate()
            let sdk = try toolchain.iPhoneOSSDK()
            appendLog("probe: \(sdk.lastPathComponent) found")
            appendLog("probe: Linux compiler executable not required")

            let reservationBytes = 2 * 1024 * 1024 * 1024
            let reserved = MobilePlatformCapabilities.canReserveAddressSpace(bytes: reservationBytes)
            appendLog("probe: 2 GiB VM reservation \(reserved ? "OK" : "FAILED")")
            if let compilerEngine {
                appendLog("probe: compiler engine loaded: \(compilerEngine.version)")
                appendLog("probe: Clang frontend \(compilerEngine.supportsClangFrontend ? "READY" : "missing")")
                appendLog("probe: Mach-O LLD \(compilerEngine.supportsMachOLLD ? "READY" : "missing")")
            } else {
                appendLog("probe: compiler engine not bundled")
            }
            appendLog(reserved ? "probe: READY for embedded compiler bridge" : "probe: memory capability needs investigation")
        } catch {
            appendLog("probe failed: \(String(describing: error))")
        }
    }

    private func prepareHelloCompilerJob() {
        guard let toolchain else {
            appendLog("hello: no Darwin SDK selected")
            return
        }

        do {
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                appendLog("hello: Application Support unavailable")
                return
            }

            let workspace = applicationSupport.appendingPathComponent(
                "CompilerProbe",
                isDirectory: true
            )
            let plan = try MobileCompilerPlan.helloWorld(
                toolchain: toolchain,
                workspace: workspace
            )
            helloPlan = plan

            appendLog("hello: source written: \(plan.sourceURL.path)")
            appendLog("hello: target: \(plan.targetTriple)")
            appendLog("hello: output: \(plan.objectURL.path)")
            appendLog("hello: frontend job prepared")
            appendLog("hello argv:")
            for argument in plan.arguments {
                appendLog("  \(argument)")
            }
            appendLog(
                compilerEngine == nil
                    ? "hello: awaiting bundled compiler engine"
                    : "hello: ready to execute performFrontend in-process"
            )
        } catch {
            appendLog("hello preparation failed: \(String(describing: error))")
        }
    }

    private func compileHello() {
        guard let plan = helloPlan else {
            appendLog("compile: prepare Hello.swift first")
            return
        }
        guard let engine = compilerEngine else {
            appendLog("compile: compiler engine is not bundled")
            return
        }

        isCompilingHello = true
        appendLog("compile: entering in-process Swift frontend...")

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try engine.run(plan)
                }.value

                appendCompilerDiagnostics(result.standardError)

                guard result.succeeded else {
                    appendLog("compile: frontend exited with code \(result.exitCode)")
                    isCompilingHello = false
                    return
                }

                guard FileManager.default.fileExists(atPath: plan.objectURL.path) else {
                    appendLog("compile: frontend returned success but Hello.o is missing")
                    isCompilingHello = false
                    return
                }

                let attributes = try FileManager.default.attributesOfItem(
                    atPath: plan.objectURL.path
                )
                let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                appendLog("compile: SUCCESS")
                appendLog("compile: Hello.o produced (\(byteCount) bytes)")
                appendLog("compile: \(plan.objectURL.path)")
                isCompilingHello = false
            } catch {
                appendLog("compile failed: \(String(describing: error))")
                isCompilingHello = false
            }
        }
    }

    private func runClangLLDProbe() {
        guard let toolchain else {
            appendLog("native probe: no Darwin SDK selected")
            return
        }
        guard let engine = compilerEngine else {
            appendLog("native probe: compiler engine is not bundled")
            return
        }
        guard engine.supportsClangFrontend else {
            appendLog("native probe: embedded Clang frontend is missing")
            return
        }
        guard engine.supportsMachOLLD else {
            appendLog("native probe: embedded Mach-O LLD is missing")
            return
        }

        do {
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                appendLog("native probe: Application Support unavailable")
                return
            }

            let workspace = applicationSupport.appendingPathComponent(
                "NativeCompilerProbe",
                isDirectory: true
            )
            let plan = try MobileClangLLDProbePlan.helloC(
                toolchain: toolchain,
                workspace: workspace
            )

            isRunningNativeProbe = true
            appendLog("native probe: source: \(plan.sourceURL.path)")
            appendLog("native probe: target: \(plan.targetTriple)")
            appendLog("native probe: entering in-process Clang frontend...")
            appendLog("clang argv:")
            for argument in plan.clangArguments {
                appendLog("  \(argument)")
            }

            Task {
                do {
                    let clangResult = try await Task.detached(priority: .userInitiated) {
                        try engine.runClangFrontend(arguments: plan.clangArguments)
                    }.value

                    appendNativeDiagnostics(label: "clang", data: clangResult.standardError)
                    guard clangResult.succeeded else {
                        appendLog("native probe: Clang exited with code \(clangResult.exitCode)")
                        isRunningNativeProbe = false
                        return
                    }

                    guard FileManager.default.fileExists(atPath: plan.objectURL.path) else {
                        appendLog("native probe: Clang returned success but HelloC.o is missing")
                        isRunningNativeProbe = false
                        return
                    }

                    let objectAttributes = try FileManager.default.attributesOfItem(
                        atPath: plan.objectURL.path
                    )
                    let objectBytes = (objectAttributes[.size] as? NSNumber)?.int64Value ?? 0
                    appendLog("native probe: Clang SUCCESS — HelloC.o (\(objectBytes) bytes)")
                    appendLog("native probe: entering in-process Mach-O LLD...")
                    appendLog("lld argv:")
                    for argument in plan.lldArguments {
                        appendLog("  \(argument)")
                    }

                    let lldResult = try await Task.detached(priority: .userInitiated) {
                        try engine.runMachOLLD(arguments: plan.lldArguments)
                    }.value

                    appendNativeDiagnostics(label: "lld", data: lldResult.standardError)
                    guard lldResult.succeeded else {
                        appendLog("native probe: LLD exited with code \(lldResult.exitCode)")
                        isRunningNativeProbe = false
                        return
                    }

                    guard FileManager.default.fileExists(atPath: plan.executableURL.path) else {
                        appendLog("native probe: LLD returned success but Mach-O output is missing")
                        isRunningNativeProbe = false
                        return
                    }

                    let executableAttributes = try FileManager.default.attributesOfItem(
                        atPath: plan.executableURL.path
                    )
                    let executableBytes = (executableAttributes[.size] as? NSNumber)?.int64Value ?? 0
                    appendLog("native probe: LLD SUCCESS — arm64 iOS Mach-O (\(executableBytes) bytes)")
                    appendLog("native probe: \(plan.executableURL.path)")
                    appendLog("native probe: C + LLD IN-PROCESS BOOTSTRAP COMPLETE")
                    isRunningNativeProbe = false
                } catch {
                    appendLog("native probe failed: \(String(describing: error))")
                    isRunningNativeProbe = false
                }
            }
        } catch {
            appendLog("native probe preparation failed: \(String(describing: error))")
            isRunningNativeProbe = false
        }
    }

    private func appendCompilerDiagnostics(_ data: Data) {
        guard !data.isEmpty else {
            appendLog("compile diagnostics: <none captured>")
            return
        }

        appendLog("compile diagnostics:")
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            appendLog("  \(line)")
        }
    }

    private func appendNativeDiagnostics(label: String, data: Data) {
        guard !data.isEmpty else {
            appendLog("\(label) diagnostics: <none captured>")
            return
        }

        appendLog("\(label) diagnostics:")
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            appendLog("  \(line)")
        }
    }

    private func sdkDisplayName(_ toolchain: PreparedToolchain) -> String {
        (try? toolchain.iPhoneOSSDK().lastPathComponent) ?? "Missing"
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
    }

    private func releaseSecurityScope(for url: URL?) {
        url?.stopAccessingSecurityScopedResource()
    }
}
