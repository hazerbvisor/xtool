import SwiftUI
import UniformTypeIdentifiers
import XToolMobileCore
import ZIPFoundation

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
    @State private var projectScopeURL: URL?
    @State private var toolchainScopeURL: URL?
    @State private var toolchainSource = "None"
    @State private var showingProjectImporter = false
    @State private var showingToolchainImporter = false
    @State private var logLines: [String] = ["xtool mobile ready"]
    @State private var attemptedBundledRuntimeDiscovery = false
    @State private var isPreparingBundledRuntime = false

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
                    .disabled(toolchain == nil)

                    if let helloPlan {
                        LabeledContent("Target", value: helloPlan.targetTriple)
                        LabeledContent("Source", value: helloPlan.sourceURL.lastPathComponent)
                        LabeledContent("Output", value: helloPlan.objectURL.lastPathComponent)
                        Text("The next native bridge milestone executes this prepared frontend job in-process and produces Hello.o.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
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

        // Fast path for every launch after the first successful extraction.
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
            withExtension: "zip"
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

                    try fileManager.unzipItem(
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
            appendLog("hello: awaiting native performFrontend bridge")
        } catch {
            appendLog("hello preparation failed: \(String(describing: error))")
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
