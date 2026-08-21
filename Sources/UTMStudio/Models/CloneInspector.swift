import Foundation

/// Whether a client's disk is at least as fresh as Master's — since
/// `link`/`relink`/`open` all now produce a full, standalone APFS
/// copy-on-write clone (see utm-client.sh's `clone_disks_from_master`),
/// there's no backing-file metadata left to inspect; every client's disk is
/// the same kind of file, indistinguishable from a plain qcow2 by any
/// on-disk trait. What's actually useful to know is whether Master has
/// changed since this client's disk was last cloned.
enum CloneKind: Equatable {
    case upToDate(clonedAt: Date)
    case stale(clonedAt: Date, masterModifiedAt: Date)
    case unknown(String)

    var symbolName: String {
        switch self {
        case .upToDate: return "checkmark.circle.fill"
        case .stale: return "clock.arrow.circlepath"
        case .unknown: return "questionmark.circle"
        }
    }

    var shortLabel: String {
        switch self {
        case .upToDate: return "Up to date"
        case .stale: return "Outdated"
        case .unknown: return "Unknown"
        }
    }

    var detailLabel: String {
        switch self {
        case .upToDate(let clonedAt):
            return "Cloned from Master \(Self.relative(clonedAt)) — up to date."
        case .stale(let clonedAt, let masterModifiedAt):
            return "Cloned \(Self.relative(clonedAt)), but Master changed \(Self.relative(masterModifiedAt)). Starting this client refreshes it automatically, so this is informational only."
        case .unknown(let reason):
            return "Unknown — \(reason)"
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Locates VM bundles the same way utm-client.sh's `find_bundle` does, and
/// compares disk modification times to answer "is this client's disk at
/// least as fresh as Master's current one?"
enum CloneInspector {
    static func findBundlePath(named vmName: String) async -> String? {
        let suffix = "/\(vmName).utm"
        let mdfindResult = await ProcessRunner.run(executable: "mdfind", arguments: ["-name", "\(vmName).utm"])
        if let hit = mdfindResult.output.split(separator: "\n").first(where: { $0.hasSuffix(suffix) }) {
            return String(hit)
        }

        let home = NSHomeDirectory()
        let roots = ["\(home)/Library/Containers/com.utmapp.UTM", "\(home)/Documents"]
        let findResult = await ProcessRunner.run(
            executable: "find",
            arguments: roots + ["-maxdepth", "6", "-iname", "\(vmName).utm", "-print"]
        )
        return findResult.output.split(separator: "\n").first.map(String.init)
    }

    static func inspect(clientName: String, masterName: String, settings: AppSettings) async -> CloneKind {
        guard let clientBundle = await findBundlePath(named: clientName) else {
            return .unknown("could not locate \(clientName).utm on disk")
        }
        guard let masterBundle = await findBundlePath(named: masterName) else {
            return .unknown("could not locate \(masterName).utm on disk")
        }

        let clientDataDir = URL(fileURLWithPath: clientBundle).appendingPathComponent("Data")
        let masterDataDir = URL(fileURLWithPath: masterBundle).appendingPathComponent("Data")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: clientDataDir, includingPropertiesForKeys: nil) else {
            return .unknown("no Data folder inside \(clientName).utm")
        }
        let clientDisks = entries.filter { $0.pathExtension.lowercased() == "qcow2" }
        guard !clientDisks.isEmpty else {
            return .unknown("no .qcow2 disks found (not a QEMU-backend VM?)")
        }

        guard let clonedAt = clientDisks.compactMap({ modificationDate(of: $0) }).max() else {
            return .unknown("could not read \(clientName)'s disk modification date")
        }

        var masterModifiedAt: Date?
        for clientDisk in clientDisks {
            let masterDisk = masterDataDir.appendingPathComponent(clientDisk.lastPathComponent)
            if let date = modificationDate(of: masterDisk) {
                masterModifiedAt = max(masterModifiedAt ?? date, date)
            }
        }
        guard let masterModifiedAt else {
            return .unknown("no matching Master disk found to compare against")
        }

        return clonedAt >= masterModifiedAt
            ? .upToDate(clonedAt: clonedAt)
            : .stale(clonedAt: clonedAt, masterModifiedAt: masterModifiedAt)
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
