import Foundation
import Combine

/// Persisted configuration for the app, backed by UserDefaults.
/// This is the GUI equivalent of the `MASTER_VM` / `UTMCTL` config
/// lines at the top of utm-client.sh — set here instead of edited by hand.
final class AppSettings: ObservableObject {
    /// Every VM name treated as a Master. Most setups have one, but this is
    /// a list so a client can be linked to whichever Master is relevant to
    /// it — see `clientMasterAssignments`.
    @Published var masterVMNames: [String] {
        didSet { UserDefaults.standard.set(masterVMNames, forKey: Keys.masterVMNames) }
    }
    /// Which Master each client is linked to, by name. Only meaningful once
    /// more than one Master exists — with a single Master every client
    /// implicitly belongs to it regardless of what's recorded here (see
    /// `master(for:)`). Changing this doesn't touch the client's disk by
    /// itself; the next relink/open clones from the newly-assigned Master.
    @Published var clientMasterAssignments: [String: String] {
        didSet { UserDefaults.standard.set(clientMasterAssignments, forKey: Keys.clientMasterAssignments) }
    }
    @Published var utmctlPath: String {
        didSet { UserDefaults.standard.set(utmctlPath, forKey: Keys.utmctlPath) }
    }
    @Published var pollIntervalSeconds: Double {
        didSet { UserDefaults.standard.set(pollIntervalSeconds, forKey: Keys.pollInterval) }
    }
    /// Each poll tick spawns `utmctl list`. On some machines utmctl briefly
    /// touches AppKit/the Dock per invocation (outside our control — it's
    /// UTM's own binary), which can show up as a flashing Dock icon on that
    /// cadence. This lets that be turned off entirely; status still updates
    /// on manual refresh and after every action.
    @Published var autoRefreshEnabled: Bool {
        didSet { UserDefaults.standard.set(autoRefreshEnabled, forKey: Keys.autoRefreshEnabled) }
    }
    /// Names of client VMs the app has created/knows about, so they survive
    /// even if a status refresh briefly misses them (e.g. right after creation).
    @Published var knownClients: [String] {
        didSet { UserDefaults.standard.set(knownClients, forKey: Keys.knownClients) }
    }
    /// VMs explicitly marked off-limits to link/relink/remove/push. Every
    /// non-Master VM UTM reports shows up as a manageable "client" by
    /// default — including VMs this app never created — so this is the only
    /// thing standing between an unrelated VM and an accidental relink
    /// (which deletes and replaces its real disk) or remove.
    @Published var excludedVMNames: [String] {
        didSet { UserDefaults.standard.set(excludedVMNames, forKey: Keys.excludedVMNames) }
    }

    private enum Keys {
        static let masterVMNames = "masterVMNames"
        static let legacyMasterVMName = "masterVMName"
        static let clientMasterAssignments = "clientMasterAssignments"
        static let utmctlPath = "utmctlPath"
        static let pollInterval = "pollIntervalSeconds"
        static let autoRefreshEnabled = "autoRefreshEnabled"
        static let knownClients = "knownClients"
        static let excludedVMNames = "excludedVMNames"
    }

    init() {
        let d = UserDefaults.standard
        let resolvedMasterNames: [String]
        if let names = d.stringArray(forKey: Keys.masterVMNames) {
            resolvedMasterNames = names
        } else if let legacy = d.string(forKey: Keys.legacyMasterVMName) {
            resolvedMasterNames = [legacy]
        } else {
            resolvedMasterNames = ["Master"]
        }
        self.masterVMNames = resolvedMasterNames
        // didSet doesn't fire for the assignment above (it's the
        // initializer's own property setup, not a later external write),
        // so without this the migrated/defaulted value would only live in
        // memory for this launch and silently reset on the next one.
        d.set(resolvedMasterNames, forKey: Keys.masterVMNames)
        d.removeObject(forKey: Keys.legacyMasterVMName)
        self.clientMasterAssignments = d.dictionary(forKey: Keys.clientMasterAssignments) as? [String: String] ?? [:]
        self.utmctlPath = d.string(forKey: Keys.utmctlPath) ?? AppSettings.autoDetectUtmctlPath() ?? "utmctl"
        // A prior version let this be persisted (and separately, an
        // auto-detect fallback chain could land on an external file
        // outside the app), which broke the moment the .app was copied
        // anywhere the external file wasn't also present — see scriptPath
        // below for why it's now resolved fresh every time instead.
        d.removeObject(forKey: "scriptPath")
        self.pollIntervalSeconds = d.object(forKey: Keys.pollInterval) as? Double ?? 5.0
        self.autoRefreshEnabled = d.object(forKey: Keys.autoRefreshEnabled) as? Bool ?? true
        self.knownClients = d.stringArray(forKey: Keys.knownClients) ?? []
        self.excludedVMNames = d.stringArray(forKey: Keys.excludedVMNames) ?? []
    }

    /// Wipes ALL persisted state for this app — not just the settings this
    /// class exposes by name, but the whole UserDefaults domain, including
    /// window size/position and sidebar layout that AppKit/SwiftUI persist
    /// automatically outside this class's knowledge. A "factory reset"
    /// should mean genuinely fresh, not "fresh except for whatever wasn't
    /// on this list." Only touches this app's own UserDefaults domain —
    /// never UTM.app itself, its preferences, or any actual VM.
    func resetToFactoryDefaults() {
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        // Re-seed in-memory state to match a fresh install (same defaults
        // as init()). Each assignment's didSet re-persists that one key —
        // window/layout state stays wiped since nothing here touches it.
        masterVMNames = ["Master"]
        clientMasterAssignments = [:]
        utmctlPath = AppSettings.autoDetectUtmctlPath() ?? "utmctl"
        pollIntervalSeconds = 5.0
        autoRefreshEnabled = true
        knownClients = []
        excludedVMNames = []
    }

    func rememberClient(_ name: String) {
        if !knownClients.contains(name) {
            knownClients.append(name)
        }
    }

    func forgetClient(_ name: String) {
        knownClients.removeAll { $0 == name }
        clientMasterAssignments.removeValue(forKey: name)
    }

    // MARK: - Masters

    func isMaster(_ name: String) -> Bool {
        masterVMNames.contains(name)
    }

    func addMaster(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !masterVMNames.contains(trimmed) else { return }
        masterVMNames.append(trimmed)
    }

    func removeMaster(_ name: String) {
        masterVMNames.removeAll { $0 == name }
        clientMasterAssignments = clientMasterAssignments.filter { $0.value != name }
    }

    /// Which Master `client` is linked to. Falls back to the first
    /// configured Master when there's no explicit assignment (the normal
    /// case with a single Master) or the assigned one no longer exists.
    func master(for client: String) -> String? {
        if let assigned = clientMasterAssignments[client], masterVMNames.contains(assigned) {
            return assigned
        }
        return masterVMNames.first
    }

    func setMaster(_ masterName: String, for client: String) {
        clientMasterAssignments[client] = masterName
    }

    func isExcluded(_ name: String) -> Bool {
        excludedVMNames.contains(name)
    }

    func exclude(_ name: String) {
        if !excludedVMNames.contains(name) {
            excludedVMNames.append(name)
        }
    }

    func unexclude(_ name: String) {
        excludedVMNames.removeAll { $0 == name }
    }

    /// The copy of utm-client.sh bundled inside this app's own
    /// Contents/Resources (build_app.sh puts it there) — resolved fresh on
    /// every access, never persisted, never user-configurable. That's
    /// deliberate: the whole point of bundling the script is that it
    /// travels with the app, so copying the .app anywhere should just
    /// work. Making this a stored/persisted setting (as a prior version
    /// did) meant it could silently drift to an external path — e.g. if
    /// auto-detection ever landed on a dev-tree sibling file during
    /// Xcode-run testing — and that value would then stick around even
    /// after moving to a machine where the external file didn't exist.
    var scriptPath: String {
        AppSettings.resolveScriptPath() ?? ""
    }

    private static func resolveScriptPath() -> String? {
        let fm = FileManager.default

        // Primary, and the only thing that matters for a packaged .app.
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("utm-client.sh").path
            if fm.fileExists(atPath: bundled) { return bundled }
        }

        // Fallback for running the raw executable directly (Xcode's Run
        // button, `swift run`) during development, before it's ever been
        // packaged into a real .app with a Resources folder: walk up from
        // the executable looking for the source tree's sibling script.
        var dir = Bundle.main.bundleURL
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("utm-client.sh").path
            if fm.fileExists(atPath: candidate) { return candidate }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    /// `/usr/local/bin` is deliberately not in this list: on Apple Silicon
    /// (the only architecture this app runs on — see App.swift) that prefix
    /// is never Homebrew's own location, only something a user manually put
    /// there, so it's not a meaningful "common" candidate here. Homebrew on
    /// Apple Silicon always uses /opt/homebrew.
    static func autoDetectUtmctlPath() -> String? {
        let fm = FileManager.default
        let common = [
            "/opt/homebrew/bin/utmctl",
            "\(NSHomeDirectory())/Applications/UTM.app/Contents/MacOS/utmctl",
            "/Applications/UTM.app/Contents/MacOS/utmctl"
        ]
        for path in common where fm.fileExists(atPath: path) {
            return path
        }
        return nil
    }
}
