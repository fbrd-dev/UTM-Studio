import SwiftUI

struct VMRowView: View {
    let vm: VirtualMachine
    var isBusy: Bool = false
    var cloneKind: CloneKind? = nil
    /// Shown as a small subtitle when there's more than one Master
    /// configured, so it's clear at a glance which one this client belongs
    /// to without opening its detail pane.
    var masterName: String? = nil
    var onQuickToggle: () -> Void

    private var isRunning: Bool { vm.status == .started }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(vm.isMaster ? Theme.masterAccent.opacity(0.18) : Color.secondary.opacity(0.12))
                    .frame(width: 28, height: 28)
                Image(systemName: vm.isMaster ? "star.fill" : "desktopcomputer")
                    .font(.system(size: 13))
                    .foregroundStyle(vm.isMaster ? Theme.masterAccent : .secondary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(vm.name)
                    .font(.system(size: 13, weight: vm.isMaster ? .semibold : .regular))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    StatusDot(status: vm.status)
                    Text(vm.isMaster ? "Master · \(vm.status.label)" : vm.status.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let cloneKind, !vm.isMaster {
                        let stale: Bool = { if case .stale = cloneKind { true } else { false } }()
                        Image(systemName: cloneKind.symbolName)
                            .font(.system(size: 9))
                            .foregroundStyle(stale ? .orange : .secondary)
                            .help(cloneKind.detailLabel)
                    }
                }
                if let masterName {
                    Text("→ \(masterName)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else if !vm.isMaster {
                Button(action: onQuickToggle) {
                    Image(systemName: isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isRunning ? .red : Theme.masterAccent)
                .help(isRunning ? "Stop" : "Start (disposable)")
            }
        }
        .padding(.vertical, 3)
        .opacity(vm.status == .unknown ? 0.6 : 1.0)
    }
}
