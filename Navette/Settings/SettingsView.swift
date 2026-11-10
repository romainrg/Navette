import AppKit
import NavetteCore
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Downloads") {
                LabeledContent("Download folder") {
                    HStack {
                        Text(settings.downloadFolder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                    }
                }
            }
            Section("Transfers") {
                Picker("When a file already exists", selection: $settings.conflictPolicy) {
                    ForEach(ConflictPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Stepper(value: $settings.maxConcurrentTransfers, in: 1...8) {
                    Text("Simultaneous transfers per server: \(settings.maxConcurrentTransfers)")
                }
                LabeledContent("Speed limit") {
                    HStack {
                        TextField(String(), value: $settings.rateLimitKB, format: .number).frame(width: 80).multilineTextAlignment(.trailing)
                        Text("kB/s (0 for no limit)").foregroundStyle(.secondary)
                    }
                }
            }
            Section("Browser") {
                Toggle("Show hidden files in new tabs", isOn: $settings.showHiddenFiles)
            }
            Section {
                Text("Passwords are stored in your Keychain, in a single item named Navette. Navette contacts only the servers you configure and sends no usage data.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onChange(of: settings.conflictPolicy) { model.applyTransferSettings() }
        .onChange(of: settings.maxConcurrentTransfers) { model.applyTransferSettings() }
        .onChange(of: settings.rateLimitKB) { model.applyTransferSettings() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = model.settings.downloadFolder
        if panel.runModal() == .OK, let url = panel.url { model.settings.downloadFolder = url }
    }
}
