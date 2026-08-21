import SwiftUI

struct NewClientSheet: View {
    @EnvironmentObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var startAfterCreate: Bool = false
    @State private var selectedMaster: String = ""
    @State private var isCreating = false
    @FocusState private var nameFieldFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var nameIsTaken: Bool { vm.vms.contains { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame } }
    private var canCreate: Bool { !trimmedName.isEmpty && !nameIsTaken && !isCreating && !selectedMaster.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "plus.square.on.square")
                    .font(.title2)
                    .foregroundStyle(Theme.masterAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Client").font(.headline)
                    Text("Creates a space-efficient clone of a Master VM.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if vm.masterVMs.isEmpty {
                Label("No Master configured yet — add one in Settings first.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Client name").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. Acme Corp", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFieldFocused)
                    .onSubmit { if canCreate { create() } }
                if nameIsTaken {
                    Label("A VM with this name already exists.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if vm.masterVMs.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Master").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $selectedMaster) {
                        ForEach(vm.masterVMs) { master in
                            Text(master.name).tag(master.name)
                        }
                    }
                    .labelsHidden()
                }
            }

            Toggle("Start immediately after creating", isOn: $startAfterCreate)
                .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    create()
                } label: {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            nameFieldFocused = true
            if selectedMaster.isEmpty {
                selectedMaster = vm.masterVMs.first?.name ?? ""
            }
        }
    }

    private func create() {
        guard canCreate else { return }
        isCreating = true
        let clientName = trimmedName
        let start = startAfterCreate
        let masterName = selectedMaster
        Task {
            await vm.createLinkedClient(clientName, startAfter: start, masterName: masterName)
            isCreating = false
            dismiss()
        }
    }
}
