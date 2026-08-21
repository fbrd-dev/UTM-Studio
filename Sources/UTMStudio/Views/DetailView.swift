import SwiftUI

private func isStale(_ kind: CloneKind) -> Bool {
    if case .stale = kind { return true }
    return false
}

struct DetailView: View {
    @EnvironmentObject var vm: AppViewModel
    let selection: String?
    @Binding var showingNewClientSheet: Bool

    private var selectedVM: VirtualMachine? {
        vm.vms.first { $0.id == selection }
    }

    var body: some View {
        Group {
            if let selected = selectedVM {
                if selected.isMaster {
                    MasterDetailView(masterName: selected.name)
                } else if vm.settings.isExcluded(selected.name) {
                    ProtectedDetailView(client: selected)
                } else {
                    ClientDetailView(client: selected)
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Select a VM")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button(action: { showingNewClientSheet = true }) {
                Label("New Client…", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct MasterDetailView: View {
    let masterName: String
    @EnvironmentObject var vm: AppViewModel

    private var master: VirtualMachine? { vm.vms.first { $0.name == masterName } }
    private var ownClients: [VirtualMachine] { vm.clients(ofMaster: masterName) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill").foregroundStyle(Theme.masterAccent)
                        Text(masterName).font(.title2.weight(.semibold))
                    }
                    if let master {
                        HStack(spacing: 6) {
                            StatusDot(status: master.status)
                            Text(master.status.label).foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                }

                if let master, master.status == .started || master.status.isTransitional {
                    GroupBox {
                        Label("'\(masterName)' is running. Starting one of its clients re-clones its disk from this Master's current state first, which needs a consistent snapshot — stop '\(masterName)' in UTM before starting any of its clients.", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Master is the source of truth for every client's Windows install, apps, and settings.", systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Hardware and OS-level changes (RAM, disks, network, installed software) still need to happen in UTM itself. Everything else — spinning up, resetting, or tearing down clients — can be done from here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            vm.openMasterInUTM()
                        } label: {
                            Label("Open in UTM…", systemImage: "arrow.up.forward.app")
                        }
                        .help("Opens UTM.app so you can edit '\(masterName)'s hardware/settings")

                        Button {
                            Task { await vm.revealInFinder(masterName) }
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }
                    }

                    Button {
                        Task { await vm.pushToAllClients(forMaster: masterName) }
                    } label: {
                        Label("Push Updates to All Clients", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(ownClients.isEmpty || vm.busyOperation != nil)
                    .help("Full re-clone of every client linked to '\(masterName)'")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                if !ownClients.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: "Clients linked to this Master")
                        ForEach(ownClients) { client in
                            HStack {
                                StatusDot(status: client.status)
                                Text(client.name)
                                if let kind = vm.cloneKinds[client.name] {
                                    Image(systemName: kind.symbolName)
                                        .font(.caption2)
                                        .foregroundStyle(isStale(kind) ? .orange : .secondary)
                                        .help(kind.detailLabel)
                                }
                                Spacer()
                                Text(client.status.label).foregroundStyle(.secondary).font(.caption)
                            }
                            .font(.callout)
                            .padding(.vertical, 2)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(24)
        }
    }
}

private struct ClientDetailView: View {
    let client: VirtualMachine
    @EnvironmentObject var vm: AppViewModel
    @State private var showingPersistentConfirm = false

    private var isBusy: Bool { vm.busyOperation?.contains("'\(client.name)'") == true }
    private var isRunning: Bool { client.status == .started || client.status.isTransitional }
    private var currentMaster: String? { vm.settings.master(for: client.name) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "desktopcomputer")
                        Text(client.name).font(.title2.weight(.semibold))
                    }
                    HStack(spacing: 6) {
                        StatusDot(status: client.status)
                        Text(client.status.label).foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }

                if let busyLabel = vm.busyOperation, isBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(busyLabel).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            Task { isRunning ? await vm.stopClient(client.name) : await vm.startClient(client.name) }
                        } label: {
                            Label(isRunning ? "Stop" : "Start (disposable)", systemImage: isRunning ? "stop.fill" : "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isRunning ? .red : Theme.masterAccent)

                        Button {
                            showingPersistentConfirm = true
                        } label: {
                            Label("Start (Keep Changes)", systemImage: "play.circle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isRunning)

                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .help("Start without discarding this session's changes — the client's disk will diverge from Master until you explicitly Relink it")

                        Spacer()

                        Button(role: .destructive) {
                            vm.confirmAndRemoveClient(client.name)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack(spacing: 10) {
                        Button {
                            Task { await vm.relinkClient(client.name) }
                        } label: {
                            Label("Relink to Master", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isRunning)
                        .help(isRunning
                            ? "Stop '\(client.name)' first — relinking replaces its disk, which would abruptly interrupt it"
                            : "Refresh this client's disk to \(currentMaster.map { "'\($0)'" } ?? "Master")'s current state without starting it")

                        Spacer()

                        Button {
                            Task { await vm.revealInFinder(client.name) }
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .controlSize(.large)
                .disabled(vm.busyOperation != nil)

                if vm.masterVMs.count > 1 {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Linked to Master").font(.callout)
                                Spacer()
                                Picker("", selection: Binding(
                                    get: { currentMaster ?? vm.masterVMs.first?.name ?? "" },
                                    set: { vm.setMaster($0, for: client.name) }
                                )) {
                                    ForEach(vm.masterVMs) { master in
                                        Text(master.name).tag(master.name)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 200)
                                .disabled(isRunning)
                            }
                            if isRunning {
                                Text("Stop '\(client.name)' to switch Masters.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Takes effect on the next Relink or Start — switching doesn't touch the disk by itself.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            let kind = vm.cloneKinds[client.name]
                            Image(systemName: kind?.symbolName ?? "ellipsis.circle")
                                .foregroundStyle(kind.map(isStale) == true ? .orange : .secondary)
                            Text(kind?.detailLabel ?? "Checking clone freshness…")
                                .font(.callout)
                            Spacer()
                            Button {
                                Task { await vm.refreshCloneKind(for: client.name) }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .help("Re-check freshness")
                        }
                        Text("Always launched disposable, and its disk is refreshed from Master automatically on every Start — so this is informational, not something you need to act on before starting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .task(id: client.name) {
            if vm.cloneKinds[client.name] == nil {
                await vm.refreshCloneKind(for: client.name)
            }
        }
        .confirmationDialog(
            "Start '\(client.name)' and keep this session's changes?",
            isPresented: $showingPersistentConfirm,
            titleVisibility: .visible
        ) {
            Button("Start (Keep Changes)") {
                Task { await vm.startClient(client.name, persistent: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unlike a normal disposable start, this session's changes will be saved to the client's disk — it'll diverge from Master until you explicitly Relink it.")
        }
    }
}

/// Shown instead of ClientDetailView for a VM marked protected in Settings —
/// deliberately offers no link/relink/remove/start/stop actions at all, so
/// there's no path from this screen to touching its disk.
private struct ProtectedDetailView: View {
    let client: VirtualMachine
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                        Text(client.name).font(.title2.weight(.semibold))
                    }
                    HStack(spacing: 6) {
                        StatusDot(status: client.status)
                        Text(client.status.label).foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Protected — excluded from Master linking.", systemImage: "checkmark.shield.fill")
                            .font(.callout)
                        Text("This VM won't be touched by link, relink, remove, or push, even if its name is accidentally reused. Unprotect it to manage it as a client again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Show in Finder") {
                                Task { await vm.revealInFinder(client.name) }
                            }
                            Button("Allow Master Linking Again") {
                                vm.settings.unexclude(client.name)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                Spacer(minLength: 0)
            }
            .padding(24)
        }
    }
}
