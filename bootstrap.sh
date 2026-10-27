#!/usr/bin/env bash
# bootstrap.sh — Termux side of opencode-android
#
# Installs proot-distro + Ubuntu, drops the opencode-android files into the
# container, and runs setup-opencode.sh inside it — in one shot.
#
# One-liner (replace YOUR-USER with the repo owner):
#   curl -fsSL https://raw.githubusercontent.com/YOUR-USER/opencode-android/main/bootstrap.sh | bash
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
BRANCH="${OC_ANDROID_BRANCH:-main}"

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
if [ ! -d "$PREFIX/var/lib/proot-distro/installed-rootfs/$DISTRO" ]; then
  log "Installing proot distro: $DISTRO (downloads ~200-400 MB)"
  proot-distro install "$DISTRO" || { fail "proot-distro install $DISTRO failed"; exit 1; }
else
  log "proot distro '$DISTRO' already installed"
fi
ROOTFS="$PREFIX/var/lib/proot-distro/installed-rootfs/$DISTRO"

# Move the repo files into the container if they are next to this script,
# otherwise clone inside the container.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || SCRIPT_DIR=""
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/setup-opencode.sh" ]; then
  log "Copying opencode-android files into the container"
  rm -rf "$ROOTFS/root/opencode-android"
  mkdir -p "$ROOTFS/root/opencode-android"
  cp -R "$SCRIPT_DIR/." "$ROOTFS/root/opencode-android/"
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
    git clone --depth 1 -b $BRANCH $REPO_URL /root/opencode-android
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
