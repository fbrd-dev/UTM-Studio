import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var selection: String?
    @State private var showingNewClientSheet = false
    @State private var showingSettingsSheet = false
    @State private var consoleExpanded = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, showingNewClientSheet: $showingNewClientSheet)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            VStack(spacing: 0) {
                DetailView(selection: selection, showingNewClientSheet: $showingNewClientSheet)
                ConsoleView(isExpanded: $consoleExpanded)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await vm.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh VM list now")

                Button {
                    showingNewClientSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("New client…")

                Button {
                    showingSettingsSheet = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $showingNewClientSheet) {
            NewClientSheet()
        }
        .sheet(isPresented: $showingSettingsSheet) {
            SettingsSheet(settings: vm.settings)
        }
        .onAppear {
            vm.isMainWindowOpen = true
            vm.startPolling()
        }
        .onDisappear {
            vm.isMainWindowOpen = false
        }
        .onChange(of: vm.vms) { _, newVMs in
            guard let selection, !newVMs.contains(where: { $0.id == selection }) else { return }
            self.selection = newVMs.first { $0.isMaster }?.id
        }
        .onChange(of: vm.pendingNewClientRequest) { _, requested in
            guard requested else { return }
            showingNewClientSheet = true
            vm.pendingNewClientRequest = false
        }
    }
}
