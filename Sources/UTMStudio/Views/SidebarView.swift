import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var vm: AppViewModel
    @Binding var selection: String?
    @Binding var showingNewClientSheet: Bool
    @State private var pendingPersistentStart: String?

    var body: some View {
        List(selection: $selection) {
            if vm.masterVMs.isEmpty {
                Section {
                    Label("No Master found in UTM", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    SectionLabel(text: "Masters")
                }
            } else {
                Section {
                    ForEach(vm.masterVMs) { master in
                        VMRowView(vm: master, onQuickToggle: {})
                            .tag(master.id)
                            .contextMenu {
                                Button("Show in Finder") { Task { await vm.revealInFinder(master.name) } }
                            }
                    }
                } header: {
                    SectionLabel(text: vm.masterVMs.count > 1 ? "Masters" : "Master")
                }
            }

            Section {
                if vm.clientVMs.isEmpty {
                    Text("No clients yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                } else {
                    ForEach(vm.clientVMs) { client in
                        let isRunning = client.status == .started || client.status.isTransitional
                        VMRowView(
                            vm: client,
                            isBusy: vm.busyOperation?.contains("'\(client.name)'") == true,
                            cloneKind: vm.cloneKinds[client.name],
                            masterName: vm.masterVMs.count > 1 ? vm.settings.master(for: client.name) : nil,
                            onQuickToggle: {
                                Task {
                                    if client.status == .started {
                                        await vm.stopClient(client.name)
                                    } else {
                                        await vm.startClient(client.name)
                                    }
                                }
                            }
                        )
                        .tag(client.id)
                        .contextMenu {
                            Button("Start (disposable)") { Task { await vm.startClient(client.name) } }
                                .disabled(isRunning)
                            Button("Start (Keep Changes)…") { pendingPersistentStart = client.name }
                                .disabled(isRunning)
                            Button("Stop") { Task { await vm.stopClient(client.name) } }
                                .disabled(!isRunning)
                            Divider()
                            Button("Relink to Master") { Task { await vm.relinkClient(client.name) } }
                                .disabled(isRunning)
                            if vm.masterVMs.count > 1 {
                                Menu("Switch Master") {
                                    ForEach(vm.masterVMs) { master in
                                        Button(master.name) { vm.setMaster(master.name, for: client.name) }
                                    }
                                }
                                .disabled(isRunning)
                            }
                            Divider()
                            Button("Show in Finder") { Task { await vm.revealInFinder(client.name) } }
                            Button("Exclude from Master linking…") { vm.settings.exclude(client.name) }
                            Divider()
                            Button("Remove…", role: .destructive) { vm.confirmAndRemoveClient(client.name) }
                        }
                    }
                }
            } header: {
                HStack {
                    SectionLabel(text: "Clients")
                    Spacer()
                    Button(action: { showingNewClientSheet = true }) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("New client…")
                }
            }

            if !vm.protectedVMs.isEmpty {
                Section {
                    ForEach(vm.protectedVMs) { other in
                        HStack(spacing: 10) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(other.name).font(.system(size: 13)).lineLimit(1)
                                HStack(spacing: 4) {
                                    StatusDot(status: other.status)
                                    Text(other.status.label).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 4)
                        }
                        .padding(.vertical, 3)
                        .tag(other.id)
                        .contextMenu {
                            Button("Show in Finder") { Task { await vm.revealInFinder(other.name) } }
                            Divider()
                            Button("Allow Master Linking Again") { vm.settings.unexclude(other.name) }
                        }
                    }
                } header: {
                    SectionLabel(text: "Other VMs (protected)")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if vm.isRefreshing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Refreshing…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            }
        }
        .confirmationDialog(
            "Start '\(pendingPersistentStart ?? "")' and keep this session's changes?",
            isPresented: Binding(
                get: { pendingPersistentStart != nil },
                set: { if !$0 { pendingPersistentStart = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Start (Keep Changes)") {
                if let name = pendingPersistentStart {
                    Task { await vm.startClient(name, persistent: true) }
                }
                pendingPersistentStart = nil
            }
            Button("Cancel", role: .cancel) { pendingPersistentStart = nil }
        } message: {
            Text("Unlike a normal disposable start, this session's changes will be saved to the client's disk — it'll diverge from Master until you explicitly Relink it.")
        }
    }
}
