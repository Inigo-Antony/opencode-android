#!/usr/bin/env bash
# bootstrap.sh — Termux side of opencode-android
#
# Installs proot-distro + Ubuntu, drops the opencode-android files into the
# container, and runs setup-opencode.sh inside it — in one shot.
#
# One-liner (replace YOUR-USER with the repo owner). HEAD follows the repo's
# default branch, so forks work whether they use main, master or anything else:
#   curl -fsSL https://raw.githubusercontent.com/YOUR-USER/opencode-android/HEAD/bootstrap.sh | bash
#
# Repo override:
#   OC_ANDROID_REPO=https://github.com/YOUR-USER/opencode-android bootstrap.sh
#
# Security note: the container is mounted WITHOUT your Termux home (no
# --termux-home). That is the point — opencode and every command it runs
# cannot see or touch your main Termux/Android files. docs/SECURITY.md

set -uo pipefail

DISTRO="${OC_ANDROID_DISTRO:-ubuntu}"
REPO_URL="${OC_ANDROID_REPO:-https://github.com/YOUR-USER/opencode-android}"
# Empty = clone the remote's default branch (works for main, master, ...).
BRANCH="${OC_ANDROID_BRANCH:-}"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; }

# ---------- sanity ----------
if [ -z "${TERMUX_VERSION:-}" ] && [ ! -d "/data/data/com.termux" ]; then
  fail "This script must run in Termux (not inside a proot session, not on regular Linux)."
  exit 1
fi
command -v proot-distro >/dev/null 2>&1 || {
  log "Installing proot-distro"
  if pkg update -y && pkg install -y proot-distro; then :; else
    fail "pkg install proot-distro failed"
    exit 1
  fi
}

# ---------- distro ----------
# proot-distro's 2026 Python rewrite moved containers from
# installed-rootfs/<alias> to containers/<name>/rootfs (and migrates old
# ones on first login). Checking one path misses the other layout, whose
# `install` then dies with "container 'X' already exists" — ask both,
# then proot-distro itself as a last resort.
PD_ROOT="$PREFIX/var/lib/proot-distro"
container_installed() {
  [ -d "$PD_ROOT/containers/$DISTRO/rootfs" ] && return 0
  [ -d "$PD_ROOT/installed-rootfs/$DISTRO" ] && return 0
  proot-distro list --quiet 2>/dev/null | grep -qx "$DISTRO" && return 0
  return 1
}

if container_installed; then
  log "proot distro '$DISTRO' already installed"
else
  log "Installing proot distro: $DISTRO (downloads ~200-400 MB)"
  proot-distro install "$DISTRO" || { fail "proot-distro install $DISTRO failed"; exit 1; }
fi

# Locate the container rootfs on disk — layout depends on proot-distro
# version (containers/<name>/rootfs since the 2026 rewrite).
ROOTFS=""
for _rf in "$PD_ROOT/containers/$DISTRO/rootfs" "$PD_ROOT/installed-rootfs/$DISTRO"; do
  if [ -d "$_rf" ]; then ROOTFS="$_rf"; break; fi
done

# Move the repo files into the container if they are next to this script
# and the rootfs is locatable, otherwise clone inside the container
# (needs the repo public — see README).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || SCRIPT_DIR=""
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/setup-opencode.sh" ]; then
  if [ -n "$ROOTFS" ]; then
    log "Copying opencode-android files into the container"
    rm -rf "$ROOTFS/root/opencode-android"
    mkdir -p "$ROOTFS/root/opencode-android"
    cp -R "$SCRIPT_DIR/." "$ROOTFS/root/opencode-android/"
  else
    log "Container rootfs not found on disk (proot-distro layout unknown);"
    log "the container will clone $REPO_URL instead"
  fi
else
  log "No local repo next to the script; the container will clone $REPO_URL"
fi

# ---------- first login: deps + setup ----------
log "Setting up inside $DISTRO (this installs curl, git, Node and opencode — several minutes)"
proot-distro login "$DISTRO" -- /bin/bash -lc "set -e
  apt-get update -y || apt update -y
  apt-get install -y curl git ca-certificates python3-pip pipx || apt-get install -y curl git ca-certificates
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
  apt-get install -y nodejs
  if [ -d /root/opencode-android ]; then
    cd /root/opencode-android && bash setup-opencode.sh
  else
    if [ -n "$BRANCH" ]; then
      git clone --depth 1 -b "$BRANCH" "$REPO_URL" /root/opencode-android
    else
      git clone --depth 1 "$REPO_URL" /root/opencode-android
    fi
    cd /root/opencode-android && bash setup-opencode.sh
  fi
"

echo
log "Done. To use:"
echo "  proot-distro login $DISTRO        # enter the container"
echo "  opencode                          # start a coding agent in any project dir"
echo
echo "One-project-per-repo?  cd to the repo inside proot and re-run:  bash /root/opencode-android/setup-opencode.sh"
echo
echo "Phone tips:"
echo "  - run  termux-wake-lock  (or enable it in a Termux notification) so the"
echo "    Android phantom process killer does not SIGKILL long agent runs"
echo "  - keep Termux in the foreground during heavy tasks; RAM is the real limit"
echo "  - full notes: docs/ANDROID-TIPS.md in the repo"
