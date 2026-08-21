#!/bin/bash
#
# utm-client.sh — spin up client-named clones of a "Master" UTM VM.
#
#   push <name>      Re-clone <name> from Master as a FULL copy (deletes old client copy first)
#   push-all <names> Same as push, for several client names at once
#   link <name>      Create <name>, its disk a space-efficient clone of Master's current disk
#   relink <name>    Refresh an existing client's disk to match Master's current state
#   open <name> [--persistent]
#                     Start <name> in disposable mode by default (auto-links from
#                     Master if new, and always refreshes an existing client's disk
#                     first — see below). --persistent keeps this session's changes
#                     on disk instead — a deliberate exception to the normal
#                     disposable/always-fresh design; the client's disk will diverge
#                     from Master until an explicit relink resets it.
#   stop <name>      Gracefully shut a client VM down
#   remove <name>    Delete a client VM entirely
#   list             Show all VMs registered in UTM
#
# Requires: UTM.app installed and its "utmctl" CLI on your PATH.
#
# How client disks stay space-efficient: `cp -c` (APFS clonefile) instead of
# a qcow2 backing-file overlay. UTM is sandboxed and only pre-authorizes the
# ONE disk file explicitly listed in a VM's own config.plist when launching
# it (via a security-scoped bookmark handed to its QEMUHelper XPC service).
# A qcow2 backing-file chain needs a SECOND file opened from deep inside
# QEMU's own code, entirely outside that authorization, and fails with
# "Operation not permitted" — verified directly: this happens no matter
# where that second file lives (Master's own bundle, hard-linked into the
# client's bundle, even a brand new standalone file inside the client's own
# bundle — all denied identically). An APFS clone sidesteps this: it's a
# single, complete, standalone file — exactly what UTM's per-VM
# authorization model expects — that happens to share physical disk blocks
# with Master's file until either one is written to, via the filesystem's
# own copy-on-write support (near-instant regardless of disk size; a 30+ GB
# clone takes milliseconds). Because it's that cheap, `open` runs it before
# every start (not just for brand-new clients), so a client always boots
# from Master's current disk state without needing an explicit relink first
# — relink is still there for pre-warming a client's disk without starting
# it, or resetting one that drifted from being booted non-disposable.
#
# Requires APFS (universal on any modern Mac). If the client's bundle ever
# ends up on a different volume than Master's, `cp -c` transparently falls
# back to a real byte-for-byte copy — safe, just not space-efficient.
#
# For a fully consistent snapshot, Master should be stopped when a client's
# disk is refreshed (link/relink/open) — this app's Swift GUI already
# enforces that; from the raw CLI it's on you.
#
# Don't move/rename Master's .utm bundle — client operations locate it by
# name each time via Spotlight/find, so a rename just means the next
# operation looks in the wrong place, not silent corruption.

set -euo pipefail

# ---- Configuration -----------------------------------------------------
MASTER_VM="${MASTER_VM:-Master}"   # <- must exactly match your Master VM's name in UTM
                                    #    override with MASTER_VM="Name" env var
UTMCTL="${UTMCTL:-utmctl}"         # override with UTMCTL=/path/to/utmctl if not symlinked
# --------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage:
  $(basename "$0") push      "<ClientName>"          # FULL re-clone from Master
  $(basename "$0") push-all  "<Client A>" "<Client B>" ...
  $(basename "$0") link      "<ClientName>"          # space-efficient clone (disk-space saving)
  $(basename "$0") relink    "<ClientName>"          # refresh a client's disk from Master
  $(basename "$0") open      "<ClientName>" [--persistent]  # spin up (disposable by default) a client
  $(basename "$0") stop      "<ClientName>"
  $(basename "$0") remove    "<ClientName>"
  $(basename "$0") list
EOF
  exit 1
}

# Locate a VM's .utm bundle on disk by its exact name.
find_bundle() {
  local vmname="$1"
  local hit
  hit=$(mdfind -name "${vmname}.utm" 2>/dev/null | grep -F "/${vmname}.utm" | head -n1)
  if [ -z "$hit" ]; then
    hit=$(find "$HOME/Library/Containers/com.utmapp.UTM" "$HOME/Documents" \
          -maxdepth 6 -iname "${vmname}.utm" -print 2>/dev/null | head -n1)
  fi
  echo "$hit"
}

# Replace a client's disk(s) with fresh, space-efficient (APFS
# copy-on-write) clones of Master's current disk(s). See the file header
# for why this replaced a qcow2 backing-file overlay.
clone_disks_from_master() {
  local client="$1"

  local master_bundle client_bundle
  master_bundle=$(find_bundle "$MASTER_VM")
  client_bundle=$(find_bundle "$client")
  [ -n "$master_bundle" ] || { echo "Could not locate ${MASTER_VM}.utm on disk." >&2; exit 1; }
  [ -n "$client_bundle" ] || { echo "Could not locate ${client}.utm on disk." >&2; exit 1; }

  local found_any=0
  shopt -s nullglob
  for master_disk in "$master_bundle"/Data/*.qcow2; do
    fname="$(basename "$master_disk")"
    client_disk="$client_bundle/Data/$fname"
    if [ -f "$client_disk" ]; then
      found_any=1
      echo "  -> cloning $fname from Master (copy-on-write, near-zero extra disk space)..."
      rm -f "$client_disk"
      cp -c "$master_disk" "$client_disk"
    fi
  done
  shopt -u nullglob

  if [ "$found_any" -eq 0 ]; then
    echo "No matching .qcow2 disk files found — is this VM using the QEMU backend?" >&2
    exit 1
  fi
  echo "'$client' now has a fresh, space-efficient clone of Master's current disk(s)."
}

link_client() {
  local client="$1"
  guard_not_master "$client"
  if vm_exists "$client"; then
    echo "'$client' already exists. Use 'relink' to refresh its disk, or just 'open' it — that refreshes automatically." >&2
    exit 1
  fi
  echo "Creating '$client' from '$MASTER_VM'..."
  "$UTMCTL" clone "$MASTER_VM" --name "$client"
  clone_disks_from_master "$client"
}

relink_client() {
  local client="$1"
  guard_not_master "$client"
  if ! vm_exists "$client"; then
    echo "No client named '$client' yet. Use 'link' to create it first." >&2
    exit 1
  fi
  # Relink replaces the client's disk — doing that out from under a running
  # VM would abruptly interrupt it with no warning. Refuse instead of
  # force-killing it first (which is what this used to do).
  if [ "$(vm_status "$client")" != "stopped" ]; then
    echo "'$client' is currently running — stop it first, then relink." >&2
    exit 1
  fi
  clone_disks_from_master "$client"
}

vm_exists() {
  "$UTMCTL" status "$1" >/dev/null 2>&1
}

vm_status() {
  "$UTMCTL" status "$1" 2>/dev/null || echo "stopped"
}

guard_not_master() {
  if [ "$1" = "$MASTER_VM" ]; then
    echo "Refusing to touch the Master VM ('$MASTER_VM')." >&2
    exit 1
  fi
}

refresh() {
  local client="$1"
  guard_not_master "$client"

  if vm_exists "$client"; then
    if [ "$(vm_status "$client")" != "stopped" ]; then
      echo "Stopping '$client'..."
      "$UTMCTL" stop "$client" --kill >/dev/null 2>&1 || true
      for _ in $(seq 1 15); do
        [ "$(vm_status "$client")" = "stopped" ] && break
        sleep 1
      done
    fi
    echo "Deleting old copy of '$client'..."
    "$UTMCTL" delete "$client"
  fi

  echo "Cloning '$MASTER_VM' -> '$client'..."
  "$UTMCTL" clone "$MASTER_VM" --name "$client"
  echo "'$client' now matches the current state of '$MASTER_VM'."
}

open_client() {
  local client="$1"
  local mode="${2:-}"
  guard_not_master "$client"

  if ! vm_exists "$client"; then
    echo "'$client' doesn't exist yet — creating it from '$MASTER_VM' first..."
    link_client "$client"
  else
    # Cloning is near-instant (APFS copy-on-write), so refresh on every open
    # rather than only at link/relink time — a client then always boots from
    # Master's current state without needing an explicit relink first.
    if [ "$(vm_status "$client")" != "stopped" ]; then
      echo "Stopping '$client'..."
      "$UTMCTL" stop "$client" --kill >/dev/null 2>&1 || true
      for _ in $(seq 1 15); do
        [ "$(vm_status "$client")" = "stopped" ] && break
        sleep 1
      done
    fi
    clone_disks_from_master "$client"
  fi

  if [ "$mode" = "--persistent" ]; then
    echo "Starting '$client' (persistent — changes WILL be saved to its disk this session, unlike normal disposable starts)..."
    "$UTMCTL" start "$client"
  else
    echo "Starting '$client' (disposable — nothing will be saved to its disk)..."
    "$UTMCTL" start "$client" --disposable
  fi
}

stop_client() {
  local client="$1"
  "$UTMCTL" stop "$client" --request
}

remove_client() {
  local client="$1"
  guard_not_master "$client"
  "$UTMCTL" stop "$client" --kill >/dev/null 2>&1 || true
  "$UTMCTL" delete "$client"
  echo "Deleted '$client'."
}

[ $# -ge 1 ] || usage

case "$1" in
  push)
    shift; [ $# -eq 1 ] || usage
    refresh "$1"
    ;;
  push-all)
    shift; [ $# -ge 1 ] || usage
    for c in "$@"; do refresh "$c"; done
    ;;
  link)
    shift; [ $# -eq 1 ] || usage
    link_client "$1"
    ;;
  relink)
    shift; [ $# -eq 1 ] || usage
    relink_client "$1"
    ;;
  open)
    shift
    case $# in
      1) open_client "$1" ;;
      2) [ "$2" = "--persistent" ] || usage; open_client "$1" "$2" ;;
      *) usage ;;
    esac
    ;;
  stop)
    shift; [ $# -eq 1 ] || usage
    stop_client "$1"
    ;;
  remove)
    shift; [ $# -eq 1 ] || usage
    remove_client "$1"
    ;;
  list)
    "$UTMCTL" list
    ;;
  *)
    usage
    ;;
esac
