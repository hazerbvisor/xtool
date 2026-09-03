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
    @State private var projectScopeURL: URL?
    @State private var toolchainScopeURL: URL?
    @State private var showingProjectImporter = false
    @State private var showingToolchainImporter = false
    @State private var logLines: [String] = ["xtool mobile ready"]

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
                        Text("Select a SwiftPM project folder containing Package.swift.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Darwin SDK") {
                    Button {
                        showingToolchainImporter = true
                    } label: {
                        Label("Import Darwin SDK", systemImage: "shippingbox")
                    }

                    if let toolchain {
                        LabeledContent("Developer", value: toolchain.developerDirectory.lastPathComponent)
                        LabeledContent("iPhoneOS SDK", value: sdkDisplayName(toolchain))
                        LabeledContent(
                            "Standalone frontend",
                            value: toolchain.hasBundledSwiftFrontend ? "Present" : "Not required"
                        )
                    } else {
                        Text("Select darwin.artifactbundle or its Developer folder. The Linux swift-frontend binary is not needed on iPad.")
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

                    LabeledContent("Compiler bridge", value: "Next milestone")
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

                Section("Build Log") {
                    ScrollView {
                        Text(logLines.joined(separator: "\n"))
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                    .frame(minHeight: 180)
                }
            }
            .navigationTitle("xtool")
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
            appendLog("Darwin SDK tree: valid")
            appendLog("SDK: \(sdk.lastPathComponent)")
            appendLog(
                selected.hasBundledSwiftFrontend
                    ? "standalone swift-frontend: present (not used by mobile backend)"
                    : "standalone swift-frontend: absent as expected"
            )
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
