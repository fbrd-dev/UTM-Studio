# Development notes

Architecture decisions, bug history, and platform quirks — the "why" behind
things that would otherwise look like an odd choice. Most of this was found
by testing directly against a real, sandboxed UTM install rather than by
reasoning about it in the abstract; where that mattered, it's called out.

## Versioning & releases

The git tag *is* the version — there's deliberately no separate place to
remember to update it. `build_app.sh` runs `git describe --tags` at build
time and stamps whatever it finds into the *built app's* `Info.plist`
(never the source file, so it doesn't create a diff on every build). To cut
a release: tag a commit (`git tag v1.2.0`), build, done — the app's version
matches automatically. Without any reachable tag, it falls back to the
static version in the source `Info.plist`, which is what a raw
Xcode-run/`swift run` dev build always shows too (that path embeds
`Info.plist` at link time via `Package.swift`, unrelated to `build_app.sh`,
so it doesn't get the git-derived value — not worth the added complexity
for a dev-only path).

**Before publishing a release**, set `UpdateChecker.githubRepo` (in
`Sources/UTMStudio/Models/UpdateChecker.swift`) to the real `owner/repo` —
it ships as a placeholder (`YOUR_GITHUB_USERNAME/utm-studio`) that just
means every update check 404s and silently finds nothing, which is safe but
means the whole point of the feature is inert until that's set.

`UpdateChecker` hits GitHub's public `releases/latest` API (no auth
needed), compares `tag_name` numerically (not lexicographically — 1.10.0
correctly beats 1.9.0), and fails silently on any network/parse error, since
a background version check must never be able to disrupt normal use of the
app. The actual prompt is a plain `NSAlert`, not a SwiftUI `.alert` — the
menu-bar-only workflow is a first-class way to run this app, and a
SwiftUI alert bound to the main window's view hierarchy simply wouldn't
exist to show anything if that window isn't open. It's deliberately not a
self-updater (no auto-download-and-replace) — see "Why not auto-update"
below for the reasoning.

## Signing & notarization

Plain `./build_app.sh` ad-hoc signs (`codesign --sign -`), which is fine for
running the app yourself or AirDropping it between your own Macs, but
Gatekeeper still warns anyone else who opens it (they need the right-click
> Open bypass), since it's not from an identified developer. Getting to a
`.dmg` other people can just download and open with no warning needs a
one-time setup, then one command per release after that.

**One-time setup** (all of this is tied to your own Apple ID/company —
nothing here can be done on someone else's behalf):

1. Enroll in the [Apple Developer Program](https://developer.apple.com/programs/enroll)
   ($99/year). Individual enrollment is faster (identity verification only);
   Organization enrollment additionally needs a D-U-N-S number and shows a
   company name instead of a personal one on the certificate — worth it if
   this becomes a real commercial release, not needed just to get signing
   working.
2. Generate a **Developer ID Application** certificate: Xcode → Settings →
   Accounts → select your Apple ID → Manage Certificates → **+** → Developer
   ID Application. This creates both the certificate and its private key in
   your keychain — no separate download/import step.
3. Find the exact identity string `codesign` expects:
   `security find-identity -v -p codesigning` — it looks like
   `"Developer ID Application: Your Name (ABCDE12345)"`, where `ABCDE12345`
   is your Team ID.
4. Generate an app-specific password at
   [appleid.apple.com](https://appleid.apple.com) (Sign-In and Security →
   App-Specific Passwords) — this is what authenticates `notarytool`, not
   your real Apple ID password.
5. Store notarization credentials once, in the keychain, under a name of
   your choosing:
   ```
   xcrun notarytool store-credentials "utm-studio-notary" \
     --apple-id "you@example.com" --team-id "ABCDE12345" \
     --password "<the app-specific password>"
   ```

**Every release after that:**

```bash
SIGNING_IDENTITY="Developer ID Application: Your Name (ABCDE12345)" \
NOTARY_PROFILE="utm-studio-notary" \
./build_app.sh
```

This signs with the hardened runtime and a secure timestamp (both required
for notarization to accept the signature at all — the ad-hoc path skips
them since a `-` identity can't produce a valid one anyway), submits the
app to Apple and waits for approval, staples the ticket, builds the `.dmg`
(the `.app` plus an `Applications` symlink, via plain `hdiutil` — no extra
dependency), then notarizes and staples the `.dmg` itself too. Both the app
and the disk image need their own ticket: Gatekeeper checks the outer
container once it's carried a quarantine flag from a browser download, not
just the app inside it.

Neither variable is required — leave both unset and the script behaves
exactly as before (ad-hoc signed, `.dmg` still produced but not notarized).
Distributing the result (e.g. attaching it to a GitHub Release matching the
git tag) is a separate, later step once you actually have a signed build to
publish.

## Why not auto-update

Worth recording the reasoning, since "just add Sparkle" is the obvious next
question: a real silent/one-click updater needs a story for verifying that
a downloaded update is actually legitimate (Sparkle does this with an
EdDSA-signed appcast feed) — doing that half-heartedly would be a genuine
security hole (a compromised release or a MITM'd update-check request could
push arbitrary code), not a convenience. For a small, currently
ad-hoc-signed personal tool, that's a meaningfully bigger commitment than
the check-and-link-to-release-page approach here warrants. If this grows
into something with real distribution/commercial weight, Sparkle is the
standard, well-trodden thing to adopt at that point — this isn't a decision
that needs to be made now.

## How client disks stay space efficient

This went through two designs before landing somewhere that actually works
against a real, sandboxed UTM install:

**First attempt — qcow2 backing-file overlay.** A client's disk was a thin
qcow2 overlay whose header pointed at Master's disk as a "backing file."
This is the standard, textbook way to do space-efficient VM clones. It
doesn't work here: UTM is sandboxed, and only pre-authorizes the ONE disk
file explicitly listed in a VM's own `config.plist` when launching it (via a
security-scoped bookmark handed to its `QEMUHelper` XPC service — confirmed
directly from the unified system log, which shows UTM resolving and
consuming a bookmark for exactly that one file before spawning QEMU). A
qcow2 backing-file reference is resolved from *inside* QEMU's own code,
entirely outside that authorization, and fails to open with "Operation not
permitted" — verified this happens no matter where the backing file lives:
Master's own bundle, hard-linked into the client's bundle, or even a
brand-new standalone file created fresh inside the client's own bundle. All
three were tested live against a real sandboxed UTM install and all three
failed identically. So this isn't a location or hard-link problem — a qcow2
backing-file chain is fundamentally incompatible with a sandboxed UTM, full
stop, regardless of distribution channel (this affects UTM installed outside
the App Store too — the `~/Library/Containers/com.utmapp.UTM/...` path is a
sandbox artifact independent of where the app came from).

**Current approach — APFS clonefile.** `clone_disks_from_master` in
`utm-client.sh` uses `cp -c` (`clonefile(2)`) instead. This produces a
complete, standalone qcow2 file — normal for UTM's per-VM authorization
model, so no sandbox issue — that happens to share physical disk blocks with
Master's file at the filesystem level until either one is written to.
Verified live: cloning a 31 GB disk took 25ms (physically impossible for a
real copy — only explainable by copy-on-write block sharing), and the
resulting VM started successfully with no permission error. `qemu-img info`
or Finder will still report the clone's *logical* size as matching Master's
(virtual/allocated size, same as any qcow2 clone) — that's expected and
correct, not a bug; it reflects the disk capacity the guest OS sees, not
real consumption. Since cloning is cheap enough to be near-free regardless
of disk size, `open_client` runs it before every start (not just for
brand-new clients) — restoring the "a client always reflects Master's
current state" property the backing-file design offered, but through a
mechanism that actually works.

This requires APFS (universal on any modern Mac's boot volume) and doesn't
need `qemu-img` at all — `cp -c` is a plain built-in tool. **The app has no
functional dependency on `qemu-img`/QEMU tools anymore** — an earlier
version used `qemu-img` for both disk creation and clone-freshness
inspection; both were replaced (the former by `cp -c`, the latter by
comparing file modification times in `CloneInspector.swift`) specifically
because the qcow2-backing-file approach didn't survive contact with a real
sandboxed install. If a client's bundle ever ends up on a different volume
than Master's, `cp -c` transparently falls back to a real byte-for-byte
copy — still correct, just not space-efficient, and slower.

## Known quirks and how the app handles them

- **Settings → utm-client.sh could silently point at an external file
  instead of the copy bundled inside the app**, which meant copying the
  `.app` to another machine broke unless that external file also existed
  there — defeating the point of bundling it at all. Root cause: it used to
  be a persisted, auto-detected setting, and the auto-detect fallback chain
  could land on a dev-tree sibling file (e.g. during Xcode-run testing,
  before the app is ever packaged with a real Resources folder) — and once
  persisted, that value stuck around even after moving to a machine where
  only the bundled copy existed. Fixed by making `scriptPath` a computed,
  non-persisted property (`AppSettings.swift`) that always resolves fresh:
  primarily `Bundle.main.resourceURL`'s `utm-client.sh` (the only thing that
  matters for a packaged `.app`), with a source-tree-walking fallback used
  only when running the raw executable directly during development. It's no
  longer a Settings field you can edit or Browse to — Settings just shows
  the resolved path, read-only, for transparency.

- **`utm-client.sh` used to live one level up from the app's project
  folder** (from before the app existed — it started as a standalone script
  and the app grew up around it), which meant copying/AirDropping just the
  project folder — the natural thing to grab — silently left the script
  behind, since it wasn't actually contained inside the folder being
  copied. `build_app.sh`'s hard-fail (below) caught this when it happened,
  but the real fix is architectural: the canonical `utm-client.sh` now lives
  inside the project folder itself, so there's no sibling relationship left
  to accidentally break.

- **The VM list could show fake entries like "Error from event: ... (OSStatus
  -1743)" or "NOTE: utmctl does not work from SSH sessions..." as if they
  were clients — and starting the packaged `.app` (but not running via
  Xcode) failed outright.** Two separate bugs that compounded:

  1. OSStatus **-1743** is `errAEEventNotPermitted` — macOS's "not authorized
     to send Apple Events to target application" error. `utmctl` talks to
     the running UTM.app via Apple Events, and the app's `Info.plist` was
     missing `NSAppleEventsUsageDescription`. Without that key, macOS can't
     properly evaluate/prompt for Automation permission for the request at
     all — it just denies it outright. Confirmed via the unified log
     (`tccd`): before adding the key, `utmctl`'s `AESendMessage` calls to
     UTM never got a reply; after adding it and rebuilding, the exact same
     call path completed a full send/reply cycle with `authValue: 2`
     (allowed) and zero denials. Fixed by adding the key to `Info.plist`
     (used both for the embedded binary section and the app bundle). The
     "doesn't work from SSH / before logging in" line is just `utmctl`'s
     generic boilerplate hint for any Apple Event failure — not a literal
     diagnosis; it's misleading here since nothing involves SSH or a
     pre-login session.
  2. Independent of that: `AppViewModel.parseList` accepted *any* non-empty
     line from `utmctl list`'s output as a VM entry if it didn't happen to
     match a UUID or status pattern — so when `utmctl` printed the Apple
     Event error text interleaved with the real table (one block per VM it
     was trying to query), each line of that error text became its own fake
     "client" row. Fixed by requiring a UUID-shaped token on the line before
     accepting it as a VM row at all (verified real `utmctl list` output
     always includes one), rather than falling back to treating the leftover
     text as a name. This is a good general hardening regardless of cause #1
     — any stray line utmctl ever prints (warnings, hints, etc.) is now
     ignored instead of becoming a phantom VM.

- **"Open Main Window" in the menu bar could open a pile of duplicate
  windows.** `openWindow(id: "main")` targets a `WindowGroup`, which is
  built for multi-instance document windows — it spawns a *new* window on
  every call, with no built-in "focus if already open" behavior. Fixed by
  tracking whether the main window is actually open
  (`AppViewModel.isMainWindowOpen`, toggled by `ContentView`'s
  `onAppear`/`onDisappear`) and only calling `openWindow` when it isn't —
  otherwise just activating the app so the existing window comes forward.

- **A small icon can flash in the Dock every poll interval.** Each refresh
  spawns `utmctl list`. On some machines, `utmctl` itself (Apple/UTM's own
  compiled binary, not this app's code) briefly touches AppKit per
  invocation and doesn't suppress its own Dock presence, so it can flash a
  generic icon for a fraction of a second. Can't patch utmctl's own binary,
  so the app mitigates it instead: the background refresh timer
  automatically pauses whenever the app isn't the active (frontmost) one
  (`AppViewModel.observeAppActivation`), so the flash, if it happens at all,
  only occurs while you're already looking at the app. The menu bar dropdown
  still refreshes itself on demand each time it opens, so pausing doesn't
  make it stale. "Auto-refresh" in Settings → Status polling turns it off
  entirely if it's still bothersome — the toolbar refresh button and
  post-action refreshes keep working regardless.

- **GUI apps don't inherit your shell's PATH.** A Finder/Dock/Xcode-launched
  GUI process gets a bare minimal PATH, not the one `.zprofile`/Homebrew
  `shellenv` sets up interactively — this can silently break bare command
  lookups in the script or its subprocesses. `AppViewModel.env()` works
  around it by explicitly prepending `/opt/homebrew/bin`,
  `/opt/homebrew/sbin`, `/usr/local/bin`, and the directory `utmctl`'s
  configured path points into, onto PATH before invoking the script (see
  `ProcessEnvironment.swift`).

- **Some file-transfer paths strip the executable bit** from
  `Contents/MacOS/UTMStudio` (confirmed with a zip round-trip through one
  particular transfer path — AirDrop and a plain Finder-created zip were
  fine in testing, but it's worth knowing this class of problem exists). If
  a transferred `.app` won't launch at all, check
  `ls -l "Contents/MacOS/UTMStudio"` — it should start with `-rwx`; if it's
  `-rw-`, `chmod +x` it and re-sign
  (`codesign --force --deep --sign - "UTM Studio.app"`).

- **Finder can show a stale/generic icon** for an app rebuilt repeatedly at
  the same path — a LaunchServices caching quirk, not a broken `.icns`.
  `build_app.sh` re-registers the app with LaunchServices after every build
  to reduce how often this happens; if it still shows up, moving the app to
  a new location (e.g. into `/Applications`) or `killall Finder` clears it.

## Notes / caveats carried over from the script

- Master should be stopped when a client's disk is refreshed (link/relink/
  open) — the app enforces this (refuses to start a client while its Master
  is running, with a clear message) so the clone captures a consistent
  snapshot rather than racing a concurrent write.
- Don't move/rename a Master's `.utm` bundle — client operations locate it
  by name each time via Spotlight/`find`, so a rename just means the next
  operation looks in the wrong place, not silent corruption.
- `utmctl list` output format is parsed defensively in
  `AppViewModel.parseList` (looks for a UUID token + a status keyword
  anywhere on the line, treats the rest as the name) rather than assuming a
  fixed column order, since it wasn't verifiable ahead of time. If the list
  view ever looks wrong, the Console pane's raw output shows exactly what
  `utmctl list` returned.

## Multiple Masters — implementation

`utm-client.sh` needed no changes to support this — it already took
`MASTER_VM` as a per-invocation environment variable rather than a single
global, so the app just resolves and passes the right one
(`AppSettings.master(for:)`) for whichever client a given script call is
about. All the actual multi-Master logic lives in the Swift app
(`AppSettings`'s `masterVMNames`/`clientMasterAssignments`, and
`AppViewModel`'s per-client environment resolution). Upgrading from a single
Master is automatic — the old single `masterVMName` setting migrates into
the new list on first launch, and every existing client keeps working
exactly as before (with no explicit assignment recorded, a client falls back
to whichever Master is first in the list, which is the migrated one).

## Apple Silicon-only, and the utmctl path setting

Two related decisions made together:

- **Apple Silicon is a hard requirement, not just the only thing tested.**
  `build_app.sh` checks `uname -m` before building and refuses on an Intel
  host, then re-checks the actual output binary's architecture with `file`
  before it's bundled. `App.swift` wraps the real app in `#if arch(arm64)`,
  with a minimal `#else` fallback scene that just says "Apple Silicon
  Required" and quits — no dependency on `AppViewModel`/`AppSettings`/UTM at
  all, so it can't itself be the thing that breaks. In practice a pure arm64
  binary can't even launch on an Intel Mac (the OS refuses it outright), so
  the compile-time gate mainly guards against a future change to the build
  setup accidentally producing a universal or x86_64 binary. Nothing about
  the actual client-cloning approach (`cp -c` / APFS clonefile) is
  Apple-Silicon-specific — this is a scope decision, not a technical
  limitation of the disk-cloning design.

- **The utmctl path setting stays configurable, but its auto-detect
  candidate list dropped `/usr/local/bin`.** That path is specifically the
  Intel-Homebrew prefix convention — Homebrew on Apple Silicon always
  installs to `/opt/homebrew`, so once Intel support is off the table,
  `/usr/local/bin/utmctl` isn't a meaningful "common location" to check
  anymore, only something a user could have put there by hand. The setting
  itself wasn't removed, though: UTM.app's own install location genuinely
  varies independent of CPU architecture (`~/Applications` vs
  `/Applications`, or a custom location entirely), so auto-detect is a
  best-effort default, not a guarantee, and Settings → utmctl is the escape
  hatch when it guesses wrong.
