import Foundation
import AppKit

@MainActor
final class AppViewModel: ObservableObject {
    @Published var vms: [VirtualMachine] = []
    @Published var logLines: [String] = []
    @Published var busyOperation: String?
    @Published var lastError: String?
    @Published var isRefreshing = false
    /// Set by the menu bar extra's "New Client…" item; the main window
    /// observes this and presents the sheet once it's frontmost.
    @Published var pendingNewClientRequest = false
    /// Tracked so the menu bar extra can tell whether it needs to call
    /// `openWindow(id: "main")` at all — that action targets a WindowGroup,
    /// which spawns a NEW window on every call rather than focusing an
    /// existing one, so calling it unconditionally opens a pile of
    /// duplicate windows if the main window is already open. Toggled by
    /// ContentView's onAppear/onDisappear.
    @Published var isMainWindowOpen = false
    /// Whether each known client's disk is at least as fresh as its
    /// assigned Master's — keyed by VM name. Populated lazily (see
    /// refreshCloneKind) rather than on every poll tick, since it shells
    /// out per client.
    @Published var cloneKinds: [String: CloneKind] = [:]

    let settings: AppSettings
    private var pollTimer: Timer?
    private var updateCheckTimer: Timer?
    private var cloneChecksInFlight: Set<String> = []
    private var isAppActive = true
    private var activationObservers: [NSObjectProtocol] = []

    init(settings: AppSettings) {
        self.settings = settings
        observeAppActivation()
        startUpdateChecking()
        primeFileAccessPermissionsOnce()
    }

    deinit {
        let center = NotificationCenter.default
        for observer in activationObservers {
            center.removeObserver(observer)
        }
    }

    var masterVMs: [VirtualMachine] {
        vms.filter { $0.isMaster }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    /// Every non-Master VM UTM reports, MINUS ones explicitly excluded in
    /// Settings. This is the set link/relink/remove/push are allowed to
    /// touch — see `guardCanModify`.
    var clientVMs: [VirtualMachine] {
        vms.filter { !$0.isMaster && !settings.isExcluded($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    /// VMs marked off-limits — shown read-only, with no action buttons.
    var protectedVMs: [VirtualMachine] {
        vms.filter { !$0.isMaster && settings.isExcluded($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Clients currently linked to a specific Master (by name), for that
    /// Master's own detail pane.
    func clients(ofMaster masterName: String) -> [VirtualMachine] {
        clientVMs.filter { (settings.master(for: $0.name) ?? "") == masterName }
    }

    // MARK: - Polling

    /// Call once at launch (and again if the user changes the interval or
    /// the auto-refresh toggle in Settings). Does an immediate refresh
    /// regardless, then schedules the recurring timer only if auto-refresh
    /// is on and the app is currently active — see `observeAppActivation`
    /// for why "active" matters here.
    func startPolling() {
        Task { await refresh() }
        rescheduleTimer()
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func rescheduleTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard settings.autoRefreshEnabled, isAppActive else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: settings.pollIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// Each poll spawns a subprocess (`utmctl list`), which on some machines
    /// causes a brief Dock icon flash (utmctl itself briefly touches AppKit —
    /// not something we control). Pausing the recurring timer while this app
    /// isn't the active one means that flash only ever happens while you're
    /// actually looking at this app, not randomly while working elsewhere.
    /// Menu bar content still refreshes on demand each time it's opened, so
    /// it doesn't go stale while paused.
    private func observeAppActivation() {
        let center = NotificationCenter.default
        activationObservers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.isAppActive = false
                    self?.rescheduleTimer()
                }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.isAppActive = true
                    await self.refresh()
                    self.rescheduleTimer()
                }
            }
        ]
    }

    // MARK: - Update checking

    /// Checks once immediately (covers "every time the app is opened" —
    /// this runs from `init`, so exactly once per actual launch, not once
    /// per time the main window happens to open/close) and then again every
    /// 24 hours for as long as the app stays running.
    private func startUpdateChecking() {
        Task { await checkForUpdates(manual: false) }
        updateCheckTimer?.invalidate()
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkForUpdates(manual: false) }
        }
    }

    /// `manual` distinguishes an explicit "Check for Updates…" click from
    /// the automatic background checks: only the manual path says anything
    /// when there's nothing new, so the automatic ones stay silent unless
    /// there's actually something to tell you.
    func checkForUpdates(manual: Bool) async {
        let update = await UpdateChecker.checkForUpdate()
        if let update {
            presentUpdateAvailableAlert(update)
        } else if manual {
            presentUpToDateAlert()
        }
    }

    /// A plain NSAlert rather than SwiftUI's `.alert`, so this reliably
    /// shows up regardless of whether the main window happens to be open —
    /// menu-bar-only use is a first-class way to run this app, and a
    /// SwiftUI alert tied to ContentView simply wouldn't exist to show
    /// anything if that view isn't in the hierarchy. Modal, but only until
    /// one click — the app is fully usable again immediately after, whether
    /// or not you update (that was explicitly the point, not a mandatory
    /// update gate).
    private func presentUpdateAvailableAlert(_ update: UpdateChecker.AvailableUpdate) {
        let alert = NSAlert()
        alert.messageText = "UTM Studio \(update.version) is available"
        alert.informativeText = "You're currently on version \(UpdateChecker.currentVersion)."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(update.releaseURL)
        }
    }

    private func presentUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "UTM Studio \(UpdateChecker.currentVersion) is the latest version."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - First-launch permission priming

    /// Locating a VM's .utm bundle (for cloning a client's disk, and for
    /// "Show in Finder") means searching ~/Documents and UTM's own
    /// sandboxed container — left alone, macOS only asks for access to
    /// either the first time some real action actually touches them, which
    /// otherwise looks exactly like that action silently failed with no
    /// explanation. Do that touching right at first launch instead, once
    /// ever, so both prompts are out of the way before they'd be confusing.
    private func primeFileAccessPermissionsOnce() {
        let key = "hasPrimedFileAccessPermissions"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let home = NSHomeDirectory()
            // Triggers macOS's standard, auto-shown "would like to access
            // files in your Documents folder" prompt immediately, if this
            // Mac hasn't already answered it for this app.
            _ = try? fm.contentsOfDirectory(atPath: "\(home)/Documents")
            await MainActor.run { Self.presentFullDiskAccessNotice() }
        }
    }

    /// Unlike Documents above, reading another app's sandboxed container
    /// (~/Library/Containers/com.utmapp.UTM, where UTM itself usually keeps
    /// VM bundles) needs Full Disk Access — a category macOS never prompts
    /// for on its own. There's no reliable way to detect whether it's
    /// already granted from inside the app, so this is shown once,
    /// unconditionally, rather than risk staying silent for a setup that
    /// actually needs it.
    private static func presentFullDiskAccessNotice() {
        let alert = NSAlert()
        alert.messageText = "One-time setup: Full Disk Access"
        alert.informativeText = "UTM Studio finds VM files by searching your Documents folder and UTM's own app data — cloning a client's disk, and \"Show in Finder\", both depend on it. If a VM ever can't be found once you're using the app, grant Full Disk Access here.\n\nSystem Settings → Privacy & Security → Full Disk Access → enable UTM Studio."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Logging

    private func log(_ line: String) {
        guard !line.isEmpty else { return }
        logLines.append(line)
        if logLines.count > 500 {
            logLines.removeFirst(logLines.count - 500)
        }
    }

    func clearLog() {
        logLines.removeAll()
    }

    private func baseEnv() -> [String: String] {
        ["UTMCTL": settings.utmctlPath, "PATH": ProcessEnvironment.augmentedPATH(extraToolPaths: [settings.utmctlPath])]
    }

    /// `MASTER_VM` is resolved per call rather than once globally, since
    /// different clients can now be linked to different Masters — each
    /// script invocation only ever needs to know about the ONE Master
    /// relevant to whichever client it's operating on.
    private func env(masterName: String) -> [String: String] {
        var e = baseEnv()
        e["MASTER_VM"] = masterName
        return e
    }

    // MARK: - Status refresh

    func refresh() async {
        guard !settings.utmctlPath.isEmpty else {
            lastError = "utmctl path not set. Configure it in Settings."
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        // `list` doesn't reference MASTER_VM at all, so no master-scoped env needed here.
        let result = await ProcessRunner.run(executable: settings.utmctlPath, arguments: ["list"], environment: baseEnv())
        guard result.exitCode == 0 else {
            lastError = "Could not list VMs: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            return
        }
        lastError = nil

        var parsed = Self.parseList(result.output)
        let parsedNames = Set(parsed.map(\.name))
        for known in settings.knownClients where !parsedNames.contains(known) {
            parsed.append(VirtualMachine(name: known, status: .unknown, isMaster: false))
        }
        // Same idea for configured Masters that aren't (yet, or no longer)
        // an actual VM UTM knows about — surface that clearly rather than
        // having them silently vanish from the sidebar.
        let namesSoFar = Set(parsed.map(\.name))
        for masterName in settings.masterVMNames where !namesSoFar.contains(masterName) {
            parsed.append(VirtualMachine(name: masterName, status: .unknown, isMaster: false))
        }
        parsed = parsed.map { vm in
            var vm = vm
            vm.isMaster = settings.isMaster(vm.name)
            return vm
        }
        vms = parsed

        // Lazily discover clone freshness for any client we haven't checked
        // yet, without blocking the list refresh itself.
        for client in parsed where !client.isMaster && cloneKinds[client.name] == nil {
            Task { await refreshCloneKind(for: client.name) }
        }
    }

    // MARK: - Clone-kind inspection

    /// Determines (or re-determines) whether `name`'s disk is at least as
    /// fresh as its assigned Master's, by comparing disk modification times.
    func refreshCloneKind(for name: String) async {
        guard !cloneChecksInFlight.contains(name) else { return }
        guard let masterName = settings.master(for: name) else {
            cloneKinds[name] = .unknown("no Master configured")
            return
        }
        cloneChecksInFlight.insert(name)
        let kind = await CloneInspector.inspect(clientName: name, masterName: masterName, settings: settings)
        cloneKinds[name] = kind
        cloneChecksInFlight.remove(name)
    }

    /// Parses `utmctl list` output. Verified against real output from a
    /// live UTM install (`UUID  Status  Name`, one VM per line, always with
    /// a UUID) — a genuine row always has a UUID-shaped token, so lines
    /// without one are something else (warnings, Apple Event permission
    /// errors, etc. that utmctl can print interleaved with the table) and
    /// are skipped rather than mistaken for a VM. Status is still matched
    /// best-effort in case a status word is ever missing/renamed. If UTM's
    /// real output ever doesn't match this shape, the Console pane's raw
    /// text shows exactly what came back so it's obvious what to adjust.
    static func parseList(_ raw: String) -> [VirtualMachine] {
        let uuidPattern = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#
        let statusKeywords: Set<String> = [
            "started", "stopped", "paused", "starting", "stopping", "pausing", "resuming", "saving"
        ]

        var results: [VirtualMachine] = []
        for rawLine in raw.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()
            if lower.contains("uuid") && (lower.contains("name") || lower.contains("status")) {
                continue // looks like a header row
            }

            var tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard !tokens.isEmpty else { continue }

            guard let uuidIndex = tokens.firstIndex(where: { $0.range(of: uuidPattern, options: .regularExpression) != nil }) else {
                continue // no UUID on this line — not a VM row (likely a warning/error utmctl printed)
            }
            tokens.remove(at: uuidIndex)

            var status: VMStatus = .unknown
            if let statusIndex = tokens.firstIndex(where: { statusKeywords.contains($0.lowercased()) }) {
                status = VMStatus.parse(tokens[statusIndex])
                tokens.remove(at: statusIndex)
            }

            let name = tokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            results.append(VirtualMachine(name: name, status: status, isMaster: false))
        }
        return results
    }

    // MARK: - Actions (all delegate to utm-client.sh; see performScript)

    /// `persistent` is a deliberate exception to the app's normal
    /// always-fresh design — the session's changes are kept on the
    /// client's disk instead of discarded, so its disk diverges from
    /// Master until an explicit Relink resets it. Off by default
    /// everywhere in the UI; callers that want it ask for it explicitly.
    func startClient(_ name: String, persistent: Bool = false) async {
        let masterName = settings.master(for: name) ?? ""
        // Starting a client re-clones its disk from its Master's current
        // state first (see utm-client.sh's open_client). For that clone to
        // be a clean, consistent snapshot, that Master shouldn't be
        // actively writing to its own disk at that exact moment — so
        // refuse rather than risk an inconsistent clone, and give a clear
        // reason instead of letting it fail deep inside the clone/start
        // sequence.
        if let master = vms.first(where: { $0.name == masterName }), master.status == .started || master.status.isTransitional {
            lastError = "Can't start '\(name)': its Master ('\(masterName)') is currently running, and starting a client re-clones its disk from Master's current state first. Stop '\(masterName)' in UTM, then try again."
            return
        }
        var args = ["open", name]
        if persistent { args.append("--persistent") }
        let busyLabel = persistent ? "Starting '\(name)' (keeping changes)…" : "Starting '\(name)'…"
        await performScript(args, busyLabel: busyLabel, masterName: masterName)
        settings.rememberClient(name)
        await refresh()
    }

    func stopClient(_ name: String) async {
        await performScript(["stop", name], busyLabel: "Stopping '\(name)'…", masterName: settings.master(for: name) ?? "")
        await refresh()
    }

    func relinkClient(_ name: String) async {
        guard guardCanModify(name) else { return }
        if let client = vms.first(where: { $0.name == name }), client.status == .started || client.status.isTransitional {
            lastError = "Can't relink '\(name)' while it's running — stop it first. Relinking replaces its disk, which would abruptly interrupt anything running inside it."
            return
        }
        let masterName = settings.master(for: name) ?? ""
        await performScript(["relink", name], busyLabel: "Relinking '\(name)' to '\(masterName)'…", masterName: masterName)
        cloneKinds[name] = nil
        await refresh()
        await refreshCloneKind(for: name)
    }

    func removeClient(_ name: String) async {
        guard guardCanModify(name) else { return }
        await performScript(["remove", name], busyLabel: "Removing '\(name)'…", masterName: settings.master(for: name) ?? "")
        settings.forgetClient(name)
        cloneKinds[name] = nil
        await refresh()
    }

    /// Confirms before deleting a client's disk entirely — irreversible, so
    /// every entry point (sidebar, detail pane, menu bar) routes through
    /// this rather than calling `removeClient` directly. A plain NSAlert,
    /// same reasoning as the update-check alerts above: this has to work
    /// reliably from the menu bar too, where there may be no SwiftUI window
    /// in the hierarchy for a `.confirmationDialog` to attach to.
    func confirmAndRemoveClient(_ name: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove '\(name)'?"
        alert.informativeText = "This deletes '\(name)' and its disk entirely — it can't be undone. You can create a fresh client from Master again afterward, but nothing about this one's own state survives."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove")
        alert.buttons.last?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Task { await removeClient(name) }
    }

    /// Relink/remove replace or delete a VM's real disk — destructive
    /// enough that a Master (never allowed, regardless of the script's own
    /// guard_not_master) or a VM explicitly marked protected (Settings →
    /// Protected VMs) must never reach them, even from a stale selection or
    /// a future call site that forgets to filter against clientVMs itself.
    private func guardCanModify(_ name: String) -> Bool {
        if settings.isMaster(name) {
            lastError = "'\(name)' is a Master VM and can't be linked, relinked, or removed through this app."
            return false
        }
        guard !settings.isExcluded(name) else {
            lastError = "'\(name)' is protected — excluded from linking, relinking, and removal. Unprotect it in Settings → Protected VMs first if this was intentional."
            return false
        }
        return true
    }

    func createLinkedClient(_ name: String, startAfter: Bool, masterName: String) async {
        guard guardCanModify(name) else { return }
        settings.setMaster(masterName, for: name)
        await performScript(["link", name], busyLabel: "Creating '\(name)' from '\(masterName)'…", masterName: masterName)
        settings.rememberClient(name)
        if startAfter {
            await startClient(name)
        } else {
            await refresh()
        }
        await refreshCloneKind(for: name)
    }

    /// Switches which Master `name` is linked to. This only updates the
    /// assignment (metadata) — the client's disk itself stays as-is until
    /// the next relink or Start, which will clone from the newly-assigned
    /// Master automatically. Refused while the client is running, same as
    /// relink itself, since the assignment is what the next disk refresh
    /// will act on.
    func setMaster(_ masterName: String, for clientName: String) {
        if let client = vms.first(where: { $0.name == clientName }), client.status == .started || client.status.isTransitional {
            lastError = "Can't change '\(clientName)'s Master while it's running — stop it first."
            return
        }
        settings.setMaster(masterName, for: clientName)
        cloneKinds[clientName] = nil
        Task { await refreshCloneKind(for: clientName) }
    }

    func pushToAllClients(forMaster masterName: String) async {
        let names = clients(ofMaster: masterName).map(\.name)
        guard !names.isEmpty else { return }
        await performScript(["push-all"] + names, busyLabel: "Pushing '\(masterName)'s changes to \(names.count) client(s)…", masterName: masterName)
        for name in names { cloneKinds[name] = nil }
        await refresh()
        for name in names { await refreshCloneKind(for: name) }
    }

    /// Master hardware/config changes still have to happen in UTM itself —
    /// this just brings UTM to the front so the user can select a Master there.
    func openMasterInUTM() {
        let utmURL = URL(fileURLWithPath: "/Applications/UTM.app")
        NSWorkspace.shared.open(utmURL)
    }

    /// Reveals a VM's .utm bundle in Finder — reuses the same lookup
    /// utm-client.sh itself uses (Spotlight, falling back to a filesystem
    /// walk), so it finds the same bundle any script/app action would act
    /// on. Read-only; safe for Masters, clients, and protected VMs alike.
    func revealInFinder(_ name: String) async {
        guard let path = await CloneInspector.findBundlePath(named: name) else {
            lastError = "Could not locate '\(name)'.utm on disk."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Resets UTM Studio's own settings and in-memory state back to a
    /// fresh-install state (see `AppSettings.resetToFactoryDefaults`).
    /// Never touches UTM.app itself or any actual VM — only this app's own
    /// configuration and cached state.
    func resetToFactoryDefaults() {
        settings.resetToFactoryDefaults()
        cloneKinds = [:]
        logLines = []
        lastError = nil
        busyOperation = nil
        Task { await refresh() }
        startPolling()
    }

    private func performScript(_ args: [String], busyLabel: String, masterName: String) async {
        guard !settings.scriptPath.isEmpty else {
            lastError = "utm-client.sh isn't in this app bundle's Contents/Resources — the .app was likely built without it (build_app.sh now fails loudly if this happens, but an older build could still be missing it). Rebuild with build_app.sh, or reinstall from a build that has it."
            return
        }
        busyOperation = busyLabel
        log("$ utm-client.sh \(args.joined(separator: " "))")
        let result = await ProcessRunner.run(
            executable: "/bin/bash",
            arguments: [settings.scriptPath] + args,
            environment: env(masterName: masterName),
            onOutput: { [weak self] line in self?.log(line) }
        )
        busyOperation = nil
        lastError = result.exitCode != 0
            ? "'\(args.first ?? "")' failed (exit \(result.exitCode)). See log for details."
            : nil
    }
}
