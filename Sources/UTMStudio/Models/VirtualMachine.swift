import SwiftUI

enum VMStatus: String {
    case started, stopped, paused, starting, stopping, pausing, resuming, saving, unknown

    var label: String {
        switch self {
        case .started: return "Running"
        case .stopped: return "Stopped"
        case .paused: return "Paused"
        case .starting: return "Starting…"
        case .stopping: return "Stopping…"
        case .pausing: return "Pausing…"
        case .resuming: return "Resuming…"
        case .saving: return "Saving…"
        case .unknown: return "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .started: return .green
        case .paused: return .yellow
        case .starting, .resuming, .stopping, .pausing, .saving: return .orange
        case .stopped: return .secondary
        case .unknown: return .gray
        }
    }

    var isTransitional: Bool {
        switch self {
        case .starting, .stopping, .pausing, .resuming, .saving: return true
        default: return false
        }
    }

    static func parse(_ raw: String) -> VMStatus {
        VMStatus(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .unknown
    }
}

struct VirtualMachine: Identifiable, Hashable {
    var name: String
    var status: VMStatus
    var isMaster: Bool

    var id: String { name }
}
