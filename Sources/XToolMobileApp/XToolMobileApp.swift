import SwiftUI
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

    var body: some View {
        NavigationStack {
            Form {
                Section("Runtime") {
                    LabeledContent("Architecture", value: capabilities.architecture)
                    LabeledContent("iOS family", value: capabilities.isRunningOnIOSFamily ? "Yes" : "No")
                    LabeledContent("OS", value: capabilities.operatingSystemVersion)
                    LabeledContent("Physical memory", value: ByteCountFormatter.string(fromByteCount: Int64(capabilities.physicalMemory), countStyle: .memory))
                }

                Section("Compiler") {
                    Label("XToolMobileCore loaded", systemImage: "checkmark.circle.fill")
                    Text("Next milestone: import a prepared Darwin toolchain and compile one Swift source file entirely on-device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("xtool")
        }
    }
}
