# UTM Studio

A small native macOS app for managing disposable, space-efficient clones of
a [UTM](https://mac.getutm.app) virtual machine — spin up a client-named VM
from a Master in a couple of clicks, let it discard all changes on shutdown,
and never touch UTM's own window for day-to-day use.

Built for a specific workflow: keep one "Master" VM as the source of truth
(OS, apps, settings), and spin up disposable, identically-configured clones
of it on demand — each one starts fresh from Master's current state and
throws away anything written to it once it's stopped. Useful for anything
where you want a clean, consistent, per-session VM without paying the disk
cost of a full copy each time.

## Features

- **One-click disposable clients** — create a named clone of a Master VM,
  launch it, and its disk resets to match Master again next time
- **Space-efficient by design** — clones share physical disk blocks with
  Master via APFS copy-on-write (`cp -c`), not a full copy; cloning a 30+ GB
  disk takes milliseconds and costs near-zero extra space
- **Multiple Masters** — link different clients to different Master VMs,
  switch a client's Master later, each Master gets its own view of its own
  clients
- **Protected VMs** — explicitly exclude unrelated VMs in the same UTM
  library from ever being touched by link/relink/remove
- **Menu bar access** — start/stop/create clients without opening the main
  window, so UTM's own app window is only needed for editing a Master's
  hardware/OS-level settings
- **A thin GUI over a standalone script** — [`utm-client.sh`](utm-client.sh)
  does the actual work via UTM's `utmctl` CLI and is fully usable on its own
  from the command line; the app is a UTM-styled wrapper around it
- **Start non-disposably when you actually want to keep changes** — an
  explicit, confirmed exception to the default disposable behavior
- **Show in Finder** — jump straight to any VM's `.utm` bundle
- **Update notifications** — checks GitHub for a newer release on launch and
  every 24 hours, with a Download/Cancel prompt (never a forced update — the
  app stays fully usable either way). "Check for Updates…" is also available
  on demand from the app menu or menu bar

## Requirements

- macOS 14+, **Apple Silicon only** — enforced, not just untested elsewhere:
  `build_app.sh` refuses to build on an Intel machine, and the app itself
  won't launch as its real self on anything but arm64 (see
  [`DEVELOPMENT.md`](DEVELOPMENT.md) for why)
- [UTM](https://mac.getutm.app) installed, with its `utmctl` CLI available
  (bundled with the app; add it to your PATH from UTM's own preferences, or
  point Settings → utmctl at `UTM.app/Contents/MacOS/utmctl` directly)
- A Master VM already set up in UTM, using the QEMU backend (not Apple
  Virtualization) with a `.qcow2` disk

## Install

No releases yet — build from source:

```bash
git clone https://github.com/<you>/utm-studio.git
cd utm-studio
./build_app.sh
```

This produces `dist/UTM Studio.app` and `dist/UTM Studio-<version>.dmg`,
versioned from the nearest git tag automatically (see
[`DEVELOPMENT.md`](DEVELOPMENT.md#versioning--releases)). Drag the app to
`/Applications` and launch it (right-click → Open the first time, since a
plain build isn't notarized — see
[`DEVELOPMENT.md`](DEVELOPMENT.md#signing--notarization) for producing a
signed, notarized `.dmg` that skips that step entirely).

You can also open `Package.swift` in Xcode and hit Run directly, for
development.

## First-time setup

Open the gear icon (Settings) and check/set:

- **Master VMs** — one or more; each name must exactly match a VM's name in
  UTM. Add more than one if you want different clients linked to different
  Masters (see "Multiple Masters" below).
- **utmctl** — path to UTM's CLI, auto-detected in common locations
  (`/opt/homebrew/bin`, inside `UTM.app`) or set manually. This field stays
  configurable because UTM.app's own install location can vary (e.g.
  `~/Applications` vs `/Applications`), not because of CPU architecture —
  see [`DEVELOPMENT.md`](DEVELOPMENT.md) for why.

Settings → **Reset to Factory Settings…** clears everything here back to
defaults (Master VMs, protected VMs, saved window size) if you ever want a
clean slate. It only touches this app's own settings — never UTM.app itself
or any of your actual VMs.

`utm-client.sh` itself isn't a setting — the app always uses the copy
bundled inside it, so the whole `.app` (or this whole source folder) is
self-contained.

## Using it day to day

- **Sidebar**: your Master(s) pinned at top; every other VM UTM knows about
  shows up as a client, with a live status dot.
- **+ button**: create a new client — name it, pick a Master if more than
  one is configured, optionally start it immediately (off by default).
- **Row hover play/stop**, or the detail pane: start/stop a client. Starting
  an existing client refreshes its disk from its Master's current state
  first, automatically.
- **Start (Keep Changes)…**: right-click a client, or use the detail pane,
  to start it non-disposably — this session's changes are saved to its disk
  instead of discarded, diverging it from Master until you explicitly
  Relink. A confirmation dialog explains the tradeoff every time, since it's
  a deliberate exception to the normal disposable/always-fresh behavior.
- **Show in Finder**: right-click any VM (Master, client, or protected) to
  reveal its `.utm` bundle in Finder.
- **Relink**: refreshes a client's disk without starting it — mainly for
  pre-warming a client, or resetting one that drifted from being booted
  non-disposable. Refused while the client is running, at both the app and
  script level, since it replaces the disk out from under it.
- **Remove**: deletes a client entirely.
- **Push Updates to All Clients** (on a Master's detail pane): full re-clone
  of every client linked to that Master — a slower fallback; normal use
  doesn't need it, since Start/Relink already keep clients current.
- **Open in UTM…**: the only time you should need UTM's own window — for
  editing a Master's hardware/OS-level settings.
- **Menu bar icon**: the same start/stop/create/push actions, without the
  main window open.
- **Freshness indicator**: shows whether a client's disk was cloned at or
  after its Master's last change — purely informational, since Start
  refreshes automatically regardless.
- **Protected VMs**: right-click any client → "Exclude from Master
  linking…" to take a VM out of reach of link/relink/remove/push entirely —
  worth doing for anything in the same UTM library that isn't actually part
  of this Master/client setup.

## Multiple Masters

Add more than one Master under Settings, and link different clients to
different ones:

- Pick a Master when creating a client (shown only once more than one
  Master exists); switch it later from the client's detail pane or via
  right-click → "Switch Master" in the sidebar.
- Switching only updates which Master a client is *assigned* to — the next
  Relink or Start is what actually clones from the newly-assigned Master.
- Disabled while the client is running, for the same reason Relink is.
- Each Master gets its own detail pane, scoped to its own clients.

## Moving to another Mac

- **Copy the built `.app`** — works, but it's ad-hoc signed, so on recent
  macOS you may need System Settings → Privacy & Security → "Open Anyway"
  (the right-click bypass doesn't always show up for unsigned apps anymore),
  or strip quarantine directly: `xattr -cr "/path/to/UTM Studio.app"`.
- **Copy this whole folder and rebuild there** (`./build_app.sh`) — a
  locally-built binary is never quarantined, and it's native to whatever
  Mac builds it (this repo's own binary is arm64-only, not universal).

Either way you'll need UTM installed there with your Master(s) imported,
Settings pointed at the right Master VM name(s) (stored per-machine), and a
one-time system prompt to allow "UTM Studio" to control UTM the first time
it calls `utmctl`.

## Development notes

The bug history, architecture decisions, and known platform quirks that
shaped this (sandbox permission investigation, why disk cloning works the
way it does, etc.) are written up in [`DEVELOPMENT.md`](DEVELOPMENT.md).
Worth reading before making changes — several things here look like the
"obvious" simpler approach until you hit the specific reason they don't
work.

## License

[MIT](LICENSE).
