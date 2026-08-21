import SwiftUI

/// Quick-access dropdown so day-to-day client start/stop never requires
/// opening the main window (or UTM.app) at all.
struct MenuBarContent: View {
    @EnvironmentObject var vm: AppViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            content
        }
        .onAppear {
            // Background polling pauses while this app isn't active (see
            // AppViewModel.observeAppActivation), so make sure opening the
            // menu itself always shows current state.
            Task { await vm.refresh() }
        }
    }

    @ViewBuilder
    private var content: some View {
        ForEach(vm.masterVMs) { master in
            Menu {
                Button("Show in Finder") { Task { await vm.revealInFinder(master.name) } }
            } label: {
                Label("\(master.name) — \(master.status.label)", systemImage: "star.fill")
            }
        }

        Divider()

        if vm.clientVMs.isEmpty {
            Text("No clients yet")
        } else {
            ForEach(vm.clientVMs) { client in
                let isRunning = client.status == .started || client.status.isTransitional
                Menu(client.name) {
                    Button(client.status == .started ? "Stop" : "Start (disposable)") {
                        Task {
                            if client.status == .started {
                                await vm.stopClient(client.name)
                            } else {
                                await vm.startClient(client.name)
                            }
                        }
                    }
                    Button("Start (Keep Changes)") {
                        Task { await vm.startClient(client.name, persistent: true) }
                    }
                    .disabled(isRunning)
                    Button("Relink to Master") { Task { await vm.relinkClient(client.name) } }
                        .disabled(isRunning)
                    Divider()
                    Button("Show in Finder") { Task { await vm.revealInFinder(client.name) } }
                    Divider()
                    Button("Remove…") { vm.confirmAndRemoveClient(client.name) }
                }
            }
        }

        Divider()

        Button("New Client…") {
            openOrFocusMainWindow()
            vm.pendingNewClientRequest = true
        }
        if vm.masterVMs.count > 1 {
            Menu("Push Updates") {
                ForEach(vm.masterVMs) { master in
                    Button("\(master.name)'s Clients") {
                        Task { await vm.pushToAllClients(forMaster: master.name) }
                    }
                    .disabled(vm.clients(ofMaster: master.name).isEmpty)
                }
            }
        } else if let master = vm.masterVMs.first {
            Button("Push Updates to All Clients") {
                Task { await vm.pushToAllClients(forMaster: master.name) }
            }
            .disabled(vm.clientVMs.isEmpty)
        }
        Button("Refresh") { Task { await vm.refresh() } }

        Divider()

        Button("Open Main Window") { openOrFocusMainWindow() }
        Button("Check for Updates…") { Task { await vm.checkForUpdates(manual: true) } }
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// `openWindow(id:)` targets a WindowGroup, which spawns a new window
    /// instance on every call — it has no built-in "focus if already open"
    /// behavior. Only call it when the main window genuinely isn't open;
    /// otherwise just activate the app so the existing window comes forward.
    private func openOrFocusMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if !vm.isMainWindowOpen {
            openWindow(id: "main")
        }
    }
}
