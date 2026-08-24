import SwiftUI
import AppKit

struct SettingsSheet: View {
    @EnvironmentObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: AppSettings
    @State private var newExcludedName = ""
    @State private var newMasterName = ""
    @State private var showingResetConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "gearshape.fill").font(.title2).foregroundStyle(.secondary)
                Text("Settings").font(.headline)
            }

            Form {
                Section {
                    if settings.masterVMNames.isEmpty {
                        Text("None configured — add at least one Master VM's exact name below.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        ForEach(settings.masterVMNames, id: \.self) { name in
                            HStack {
                                Image(systemName: "star.fill").font(.caption).foregroundStyle(Theme.masterAccent)
                                Text(name)
                                Spacer()
                                Button("Remove") { settings.removeMaster(name) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    HStack {
                        TextField("Exact VM name", text: $newMasterName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addMaster)
                        Button("Add", action: addMaster)
                            .disabled(newMasterName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("Each name must exactly match a VM's name in UTM. Clients can be linked to any one of these — pick which when creating a client, or switch it later from that client's detail pane.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(settings.masterVMNames.count > 1 ? "Master VMs" : "Master VM").font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("utm-client.sh")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(settings.scriptPath.isEmpty ? "Not found — the app bundle may be damaged." : settings.scriptPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(settings.scriptPath.isEmpty ? .red : .primary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    pathRow(
                        label: "utmctl",
                        path: $settings.utmctlPath,
                        chooseDirectory: false
                    )
                } header: {
                    Text("Tool locations").font(.caption).foregroundStyle(.secondary)
                } footer: {
                    Text("utm-client.sh always uses the copy bundled inside this app — not configurable, so copying the app elsewhere just works.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Open Full Disk Access Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Text("Needed to locate VM files for cloning a client's disk and for \"Show in Finder\" — macOS never prompts for this on its own, so if a VM can't be found, check that UTM Studio is enabled here.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Permissions").font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Auto-refresh", isOn: $settings.autoRefreshEnabled)
                        .onChange(of: settings.autoRefreshEnabled) { _, _ in
                            vm.startPolling()
                        }
                    Stepper(value: $settings.pollIntervalSeconds, in: 2...60, step: 1) {
                        Text("Refresh every \(Int(settings.pollIntervalSeconds))s")
                    }
                    .disabled(!settings.autoRefreshEnabled)
                    .onChange(of: settings.pollIntervalSeconds) { _, _ in
                        vm.startPolling()
                    }
                    Text("Each refresh spawns utmctl. On some machines that briefly flashes a Dock icon (utmctl's own behavior, not this app's) — auto-refresh already pauses while this app isn't the active one, so it only happens while you're actually looking at it. Turn it off here to poll manually only (the toolbar refresh button, and after every action, still work).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Status polling").font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    if settings.excludedVMNames.isEmpty {
                        Text("None. Every other VM UTM reports is manageable as a client by default — protect anything that isn't actually part of this Master/client setup.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(settings.excludedVMNames, id: \.self) { name in
                            HStack {
                                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                                Text(name)
                                Spacer()
                                Button("Unprotect") { settings.unexclude(name) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    HStack {
                        TextField("Exact VM name", text: $newExcludedName)
                            .textFieldStyle(.roundedBorder)
                        Button("Protect") {
                            let trimmed = newExcludedName.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty else { return }
                            settings.exclude(trimmed)
                            newExcludedName = ""
                        }
                        .disabled(newExcludedName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("Protected VMs never appear as a manageable client — link, relink, remove, and push all refuse to touch them, so their disk can't be overwritten by an accidental name collision. You can also right-click any client row to protect it.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Protected VMs").font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Button("Reset to Factory Settings…", role: .destructive) {
                        showingResetConfirmation = true
                    }
                    Text("Clears every UTM Studio setting back to defaults — Master VMs, protected VMs, saved window size, everything. Doesn't touch UTM.app or any of your actual VMs.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Reset").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 280)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .confirmationDialog(
            "Reset UTM Studio to factory settings?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                vm.resetToFactoryDefaults()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears Master VMs, protected VMs, and all other settings back to defaults. It can't be undone, though you can reconfigure everything again afterward. UTM.app and your actual VMs are not affected.")
        }
    }

    private func addMaster() {
        let trimmed = newMasterName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        settings.addMaster(trimmed)
        newMasterName = ""
    }

    @ViewBuilder
    private func pathRow(label: String, path: Binding<String>, chooseDirectory: Bool) -> some View {
        HStack {
            TextField(label, text: path)
                .textFieldStyle(.roundedBorder)
            Button("Browse…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = chooseDirectory
                panel.allowsMultipleSelection = false
                panel.treatsFilePackagesAsDirectories = false
                if panel.runModal() == .OK, let url = panel.url {
                    path.wrappedValue = url.path
                }
            }
        }
    }
}
