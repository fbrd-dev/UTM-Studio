# UTM Studio

A native macOS app for spinning up disposable, space-efficient clones of a
[UTM](https://mac.getutm.app) virtual machine — launch a fresh, identically
configured VM in a couple of clicks, let it discard everything on shutdown,
and never touch UTM's own window for day-to-day use.

Built around a simple idea: keep one **Master** VM as the source of truth
(OS, apps, settings), and spin up disposable clients from it on demand —
each one starts fresh from Master's current state and throws away anything
written to it once it's stopped. Useful anywhere you want a clean,
consistent, per-session VM — testing, throwaway environments, demos —
without paying the disk cost of a full copy every time.

## Requirements

- **macOS 14 or later, Apple Silicon (M1 or newer).** This is enforced, not
  just untested elsewhere — the app won't launch at all on an Intel Mac.
- **[UTM](https://mac.getutm.app)** installed, with its `utmctl`
  command-line tool available (UTM Studio can usually find it automatically;
  see First-time setup below).
- **A Master VM already set up in UTM**, using the QEMU backend (not Apple
  Virtualization), with a `.qcow2` disk. This is the VM UTM Studio clones
  clients from.

## Features

- **One-click disposable clients** — create a named clone of a Master VM,
  launch it, and its disk resets to match Master again next time.
- **Space-efficient by design** — clones share physical disk blocks with
  Master via APFS copy-on-write, not a full copy; cloning a 30+ GB disk
  takes milliseconds and costs near-zero extra space.
- **Start non-disposably** when you actually want to keep a session's
  changes — an explicit, confirmed exception to the default behavior.
- **Multiple Masters** — link different clients to different Master VMs,
  switch a client's Master later, each Master gets its own view of its own
  clients.
- **Protected VMs** — explicitly exclude unrelated VMs in the same UTM
  library from ever being touched.
- **Show in Finder** — jump straight to any VM's `.utm` bundle.
- **Menu bar access** — start, stop, and create clients without opening the
  main window; UTM's own window is only needed for editing a Master's
  hardware or OS-level settings.
- **A thin GUI over a standalone script** — [`utm-client.sh`](utm-client.sh)
  does the actual work via UTM's `utmctl` CLI and is fully usable on its own
  from the command line; the app is a UTM-styled wrapper around it.
- **Update notifications** — checks for a newer release on launch and every
  24 hours, with a Download/Cancel prompt. Never a forced update.

## Install

Grab the latest `.dmg` from the [Releases page](https://github.com/fbrd-dev/UTM-Studio/releases),
open it, and drag **UTM Studio** into Applications.

No release available yet, or you'd rather build it yourself?

```bash
git clone https://github.com/fbrd-dev/UTM-Studio.git
cd UTM-Studio
./build_app.sh
```

This produces `dist/UTM Studio.app` — drag it to `/Applications` and launch
it (right-click → Open the first time, since a self-built copy isn't
notarized).

## First-time setup

Open the gear icon (Settings) and check/set:

- **Master VMs** — one or more; each name must exactly match a VM's name in
  UTM. Add more than one if you want different clients linked to different
  Masters (see "Multiple Masters" below).
- **utmctl** — path to UTM's CLI, auto-detected in common locations or set
  manually if UTM Studio can't find it.

The first time UTM Studio talks to UTM, macOS will ask you to allow it to
control UTM — this is a one-time system prompt.

## Using it day to day

- **Sidebar**: your Master(s) pinned at top; every other VM UTM knows about
  shows up as a client, with a live status dot.
- **+ button**: create a new client — name it, pick a Master if more than
  one is configured, optionally start it immediately (off by default).
- **Row hover play/stop**, or the detail pane: start/stop a client. Starting
  an existing client refreshes its disk from its Master's current state
  first, automatically.
- **Start (Keep Changes)**: right-click a client, or use the detail pane,
  to start it non-disposably — this session's changes are saved to its disk
  instead of discarded, diverging it from Master until you explicitly
  Relink. A confirmation dialog explains the tradeoff every time.
- **Show in Finder**: right-click any VM to reveal its `.utm` bundle in
  Finder.
- **Relink**: refreshes a client's disk without starting it — mainly for
  pre-warming a client, or resetting one that drifted from being booted
  non-disposable.
- **Remove**: deletes a client entirely, after a confirmation prompt.
- **Push Updates to All Clients** (on a Master's detail pane): full re-clone
  of every client linked to that Master — a slower fallback; normal use
  doesn't need it, since Start/Relink already keep clients current.
- **Open in UTM…**: the only time you should need UTM's own window — for
  editing a Master's hardware or OS-level settings.
- **Menu bar icon**: the same start/stop/create/push actions, without the
  main window open.
- **Freshness indicator**: shows whether a client's disk was cloned at or
  after its Master's last change — purely informational, since Start
  refreshes automatically regardless.
- **Protected VMs**: right-click any client → "Exclude from Master
  linking…" to take a VM out of reach entirely — worth doing for anything
  in the same UTM library that isn't actually part of this Master/client
  setup.

## Multiple Masters

Add more than one Master under Settings, and link different clients to
different ones:

- Pick a Master when creating a client (shown only once more than one
  Master exists); switch it later from the client's detail pane or via
  right-click → "Switch Master" in the sidebar.
- Switching only updates which Master a client is *assigned* to — the next
  Relink or Start is what actually clones from the newly-assigned Master.
- Each Master gets its own detail pane, scoped to its own clients.

## Learn more

[`DEVELOPMENT.md`](DEVELOPMENT.md) covers the architecture, the reasoning
behind some of the less obvious design choices, and how to sign/notarize
your own build — worth a look if you're curious how it works under the
hood or want to contribute.

## License

[MIT](LICENSE).
