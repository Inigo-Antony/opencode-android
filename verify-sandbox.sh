#!/usr/bin/env bash
# verify-sandbox.sh : acceptance tests for opencode-android
#
# Goal being proven:
#   1. Code and agents inside the proot container cannot read or write your
#      Android shared storage (/sdcard) or your Termux home.
#   2. The generated project config does not leak secrets and does not pull in
#      mutable remote code or prompts without you noticing.
#   3. The setup is light enough for a tablet (start time, peak memory).
#
# Modes
#   termux    Run in Termux (NOT inside proot). Plants canary files in Termux home
#             and /sdcard, then logs into the container twice (default login and
#             --isolated) and runs the "inside" checks in each.
#   inside    Run inside the container. Called by "termux" mode, or by hand.
#   project   Run inside the container, from your project directory. Checks
#             opencode.json, secrets, plugin pinning and the opencode binary.
#   bench     Run inside the container, from your project directory. Measures
#             wall time and peak memory of one trivial opencode run.
#
# Environment
#   LOGIN_FLAGS   Flags you use for daily logins. Default: --isolated. The exit
#                 code of "termux" mode follows this login mode only.
#   OC_ANDROID_DISTRO   Distro name. Default: ubuntu
#   OC_ANDROID_USER     Container user you run opencode as (for example dev).
#                       Test with the same user you use daily. Default: root
#   KEEP=1        Keep the canary files after the run.
#
# Exit code: 0 only when every FAIL level check passed.

set -uo pipefail

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
FAILS=0
WARNS=0

pass() { printf '  [PASS] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n         %s\n' "$1" "${2:-}"; FAILS=$((FAILS + 1)); }
warn() { printf '  [WARN] %s\n         %s\n' "$1" "${2:-}"; WARNS=$((WARNS + 1)); }
info() { printf '  [INFO] %s\n' "$1"; }
skip() { printf '  [SKIP] %s\n' "$1"; }
die()  { printf 'error: %s\n' "$1" >&2; exit 2; }

TERMUX_HOME_PATH="/data/data/com.termux/files/home"

# ---------------------------------------------------------------------------
# inside: what the container must NOT be able to see or touch
# ---------------------------------------------------------------------------
inside_checks() {
  local token="${1:-}" p hits tmp rc d wrote=0 leaked=0
  tmp="$(mktemp)"
  echo "inside-container checks ($(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown distro}"))"

  if [ -z "$token" ]; then
    warn "no canary token supplied" "Run via 'termux' mode, or pass the token as the 2nd argument. Path checks still run."
  fi

  # 1. Known Android paths where a leaked mount would expose the canaries
  for p in /sdcard/OC_CANARY_SDCARD.txt \
           /storage/emulated/0/OC_CANARY_SDCARD.txt \
           /storage/self/primary/OC_CANARY_SDCARD.txt \
           "$TERMUX_HOME_PATH/OC_CANARY_TERMUX_HOME.txt"; do
    if [ -e "$p" ]; then
      leaked=1
      fail "canary visible at $p" "The container can see host files. Log in with: proot-distro login --isolated <distro>"
    fi
  done
  [ "$leaked" = 0 ] && pass "canary files not reachable at the usual Android paths"

  # 2. Search by name across the container tree (skips /proc /sys /dev)
  # Skipped when a leak is already proven: walking real shared storage is slow.
  if [ "$leaked" = 1 ]; then
    skip "filesystem search (leak already proven above; it would walk your real storage)"
  else
    timeout 120 find / \( -path /proc -o -path /sys -o -path /dev \) -prune -o -name 'OC_CANARY_*' -print >"$tmp" 2>/dev/null
    rc=$?
    hits="$(head -5 "$tmp")"
    if [ -n "$hits" ]; then
      fail "canary file found by filesystem search" "$(echo "$hits" | tr '\n' ' ')"
    elif [ "$rc" = 124 ]; then
      warn "filesystem search timed out" "Result inconclusive. Re-run, or search a smaller tree by hand."
    else
      pass "no canary file found anywhere in the container filesystem"
    fi
  fi

  # 3. Search by content in the places host storage usually shows up
  if [ -n "$token" ] && [ "$leaked" = 0 ]; then
    hits="$(timeout 60 grep -rIl -- "$token" /sdcard /storage /mnt /media /data 2>/dev/null | head -5)"
    if [ -n "$hits" ]; then
      fail "canary token found inside host-backed directories" "$(echo "$hits" | tr '\n' ' ')"
    else
      pass "canary token not found under /sdcard /storage /mnt /media /data"
    fi
  fi

  # 4. Write probe (the probe file is removed immediately)
  # Only probe directories where the canary is readable. That proves the
  # directory is real host storage. An empty /sdcard left over inside the rootfs
  # from an earlier non-isolated login is a harmless mountpoint, and writing to
  # it touches nothing on your device.
  for d in /sdcard /storage/emulated/0 /storage/self/primary; do
    if [ -e "$d/OC_CANARY_SDCARD.txt" ] && touch "$d/.oc_write_probe" 2>/dev/null; then
      rm -f "$d/.oc_write_probe"
      wrote=1
      fail "container can WRITE to $d (real shared storage)" "An agent could create, edit or delete your files."
    fi
  done
  if [ "$wrote" = 0 ]; then
    if [ -z "$token" ]; then
      info "write probe skipped (needs the canary, run 'termux' mode)"
    else
      pass "container cannot write to shared storage"
    fi
  fi

  # 5. Termux private data directory
  # A skeleton of empty directories (cache, files) is leftover mountpoints that
  # proot created inside the rootfs. Real Termux data has its prefix, a
  # populated home and app directories such as shared_prefs.
  local t=/data/data/com.termux
  if [ -d "$t/shared_prefs" ] || [ -d "$t/code_cache" ] || [ -e "$t/files/usr/bin/bash" ] \
     || [ -e "$t/files/usr/bin/pkg" ] || [ -n "$(ls -A "$t/files/home" 2>/dev/null)" ]; then
    fail "real Termux data is visible under $t" "Termux home, prefix or app data are exposed."
  elif [ -d "$t" ]; then
    info "$t is an empty skeleton of leftover mountpoints: $(ls -A "$t" 2>/dev/null | tr '\n' ' ')"
  else
    pass "$t is not accessible"
  fi

  # 6. Host environment leakage (names only, never values)
  hits="$(env | sed -n 's/^\(PREFIX\|TERMUX_[A-Z_]*\|ANDROID_DATA\|ANDROID_ROOT\|EXTERNAL_STORAGE\)=.*/\1/p' | tr '\n' ' ')"
  if [ -n "$hits" ]; then
    warn "host environment variables visible: $hits" "Not a file leak, but the container inherits Android context."
  else
    pass "no Termux or Android environment variables inherited"
  fi

  # 7. Facts to keep in mind, not failures
  info "uid inside container: $(id -u) (proot fake root, not real root)"
  if timeout 6 curl -sS -m 5 -o /dev/null https://example.com 2>/dev/null; then
    info "outbound network is open (expected). Nothing here restricts exfiltration."
  else
    info "outbound network check failed (offline or DNS issue)"
  fi

  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# project: config hygiene, run from inside the container in the project dir
# ---------------------------------------------------------------------------
project_checks() {
  local tmp rc line lvl name detail f
  tmp="$(mktemp)"
  echo "project checks in $(pwd)"

  command -v node >/dev/null 2>&1 || die "node is required for the config checks"

  # opencode binary and live config validation
  if command -v opencode >/dev/null 2>&1; then
    pass "opencode installed: $(opencode --version 2>/dev/null | head -1)"
    if opencode debug --help 2>&1 | grep -qw config; then
      timeout 60 opencode debug config >/dev/null 2>"$tmp"
      rc=$?
      if [ "$rc" = 0 ]; then
        pass "opencode accepts the resolved config (schema and {file:} refs valid)"
      else
        fail "opencode rejected the config" "$(head -3 "$tmp" | tr '\n' ' ')"
      fi
    else
      skip "this opencode has no 'debug config' command; launch opencode once and watch for 'Configuration is invalid'"
    fi
  else
    fail "opencode is not on PATH" "export PATH=\"\$HOME/.opencode/bin:\$PATH\""
  fi

  # opencode.json analysis (node prints LEVEL<TAB>name<TAB>detail)
  node - >"$tmp" <<'JS'
const fs = require('fs');
const out = (l, n, d = '') => console.log([l, n, d].join('\t'));
let c;
try { c = JSON.parse(fs.readFileSync('opencode.json', 'utf8')); }
catch (e) { out('WARN', 'opencode.json missing or not strict JSON', e.message + ' (further config checks skipped)'); process.exit(0); }

// 1. literal secrets (never print values)
const secretShape = /\b(tvly|exa|sk|gsk|ghp|github_pat|xox[bp])[-_][A-Za-z0-9_-]{16,}/;
let leaked = 0;
for (const [name, m] of Object.entries(c.mcp || {})) {
  for (const bag of [m.headers, m.environment]) {
    for (const [k, v] of Object.entries(bag || {})) {
      if (typeof v === 'string' && v && !/\{(env|file):/.test(v)) {
        leaked++; out('FAIL', `literal value in mcp.${name} ${k}`, 'Use "{env:VAR}" so the key never lands in a committable file.');
      }
    }
  }
}
(function walk(o, path) {
  if (typeof o === 'string') { if (secretShape.test(o)) { leaked++; out('FAIL', `secret-shaped string at ${path}`, '(value hidden)'); } }
  else if (o && typeof o === 'object') for (const [k, v] of Object.entries(o)) walk(v, path + '.' + k);
})(c, 'opencode.json');
if (!leaked) out('PASS', 'no literal secrets in opencode.json');

// 2. share and permission posture
if (c.share !== 'disabled') out('WARN', `share is "${c.share || 'default'}"`, 'Set "share": "disabled" to stop session sharing.');
else out('PASS', 'share is disabled');
if (!c.permission) out('WARN', 'no permission block', 'opencode defaults apply.');
else if (c.permission['*'] === 'allow' || c.permission === 'allow')
  out('WARN', 'global permission "*": allow', 'Everything not listed runs without asking. The container is your only hard boundary.');
else out('PASS', 'no global allow-all permission');

// 3. plugins must be pinned (they run with full agent privileges)
const plugins = [...new Set([...(c.plugins || []), ...(c.plugin || [])])].filter(p => typeof p === 'string');
for (const p of plugins) {
  if (/^[./]/.test(p)) continue;
  const at = p.lastIndexOf('@');
  if (!(at > 0 && /^\d/.test(p.slice(at + 1)))) out('WARN', `unpinned plugin: ${p}`, 'Pin it, e.g. name@1.2.3, so an upstream update cannot change what runs on your device.');
}

// 4. remote instructions are prompts someone else can rewrite
for (const i of (Array.isArray(c.instructions) ? c.instructions : [])) {
  if (/^https?:\/\//.test(i)) {
    const mutable = /\/(trunk|main|master|HEAD)\//.test(i);
    out('WARN', `remote instruction file: ${i}`, mutable ? 'Mutable branch ref. Vendor the file or pin a commit SHA.' : 'Remote prompt content is loaded every session.');
  }
}

// 5. overlap and size
const mcp = Object.keys(c.mcp || {});
const search = mcp.filter(n => /(tavily|exa|parallel|search|brave|serper)/i.test(n));
if (search.length > 1) out('WARN', `${search.length} overlapping search MCPs: ${search.join(', ')}`, 'Every MCP tool schema is sent on every request. Keep one.');
const n = o => Object.keys(o || {}).length;
out('INFO', `agents=${n(c.agent)} commands=${n(c.command)} mcp=${mcp.length} plugins=${plugins.length} instructions=${(c.instructions || []).length}`);
JS
  while IFS=$'\t' read -r lvl name detail; do
    case "$lvl" in
      PASS) pass "$name" ;;
      FAIL) fail "$name" "$detail" ;;
      WARN) warn "$name" "$detail" ;;
      INFO) info "$name" ;;
    esac
  done <"$tmp"

  # secrets files and git hygiene
  if [ -f .env ]; then
    if git check-ignore -q .env 2>/dev/null; then pass ".env is git-ignored"; else fail ".env is NOT git-ignored" "Add .env to .gitignore."; fi
  else
    info "no .env in this project"
  fi
  if git rev-parse --git-dir >/dev/null 2>&1 && ! git check-ignore -q opencode.json 2>/dev/null; then
    info "opencode.json is tracked by git: it must never contain secrets (see checks above)"
  fi
  f="$HOME/.local/share/opencode/auth.json"
  if [ -f "$f" ]; then
    if [ "$(stat -c %a "$f" 2>/dev/null)" = "600" ]; then pass "auth.json mode is 600"; else warn "auth.json mode is $(stat -c %a "$f" 2>/dev/null)" "chmod 600 $f"; fi
  else
    info "no auth.json yet (no provider connected)"
  fi

  # plugins that hook permission prompts can silently change your ask rules
  hits="$(grep -rIl --include='*.js' --include='*.ts' --include='*.mjs' -e 'permission.ask' "$HOME/.cache/opencode" "$HOME/.config/opencode" .opencode 2>/dev/null | grep -v '/\.git/' | head -5 | tr '\n' ' ')"
  if [ -n "${hits:-}" ]; then
    warn "a plugin registers a permission.ask hook" "$hits Run manual test M1 to confirm 'ask' rules still prompt you."
  else
    pass "no installed plugin registers a permission.ask hook (plugins may not be downloaded until first launch)"
  fi

  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# bench: start time and peak memory of one trivial run
# ---------------------------------------------------------------------------
bench() {
  command -v opencode >/dev/null 2>&1 || die "opencode is not on PATH"
  local out start end pid peak=0 v p mem rc
  out="$(mktemp)"
  mem="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)"
  echo "bench in $(pwd) (device RAM ${mem} MB)"
  start="$(date +%s.%N)"
  opencode run "Reply with exactly: OK" >"$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    for p in "$pid" $(pgrep -P "$pid" 2>/dev/null); do
      v="$(awk '/VmHWM/{print $2}' "/proc/$p/status" 2>/dev/null)"
      if [ -n "$v" ] && [ "$v" -gt "$peak" ]; then peak="$v"; fi
    done
    sleep 0.5
  done
  wait "$pid"; rc=$?
  end="$(date +%s.%N)"
  info "exit code: $rc"
  info "wall time: $(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.1f s", b-a}')"
  info "peak resident memory (opencode and children, sampled): $((peak / 1024)) MB"
  info "output tail: $(tail -c 200 "$out" | tr '\n' ' ')"
  [ "$rc" = 0 ] && pass "opencode run completed" || fail "opencode run failed" "$(tail -c 300 "$out" | tr '\n' ' ')"
  # Proposed budget, tune it for your hardware: peak under a quarter of RAM
  if [ "$((peak / 1024))" -gt "$((mem / 4))" ]; then
    warn "peak memory above 25% of device RAM" "Disable plugins or MCPs and compare."
  else
    pass "peak memory within 25% of device RAM"
  fi
  echo
  echo "Token overhead: run this mode on your full install and on a baseline"
  echo "(SKIP_GSD=1 SKIP_ECC=1 SKIP_MCP=1 SKIP_EXTRAS=1 SKIP_GRAPHIFY=1 bash setup-opencode.sh),"
  echo "then compare the input tokens of the first turn ('opencode stats' or the TUI header)."
  rm -f "$out"
}

# ---------------------------------------------------------------------------
# termux: orchestrates canaries and two container logins
# ---------------------------------------------------------------------------
termux_mode() {
  [ -n "${TERMUX_VERSION:-}" ] || [ -d /data/data/com.termux ] || die "run 'termux' mode in Termux, not inside proot"
  command -v proot-distro >/dev/null 2>&1 || die "proot-distro not found"

  local distro="${OC_ANDROID_DISTRO:-ubuntu}" daily="${LOGIN_FLAGS---isolated}"
  local token home_canary sd_canary sd=0 rc_default rc_isolated mode
  token="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  home_canary="$HOME/OC_CANARY_TERMUX_HOME.txt"
  sd_canary="/sdcard/OC_CANARY_SDCARD.txt"
  # shellcheck disable=SC2064
  [ "${KEEP:-0}" = 1 ] || trap "rm -f '$home_canary' '$sd_canary'" EXIT

  echo "$token" >"$home_canary"
  if [ -d /sdcard ] && echo "$token" >"$sd_canary" 2>/dev/null; then sd=1; fi

  echo "layer 1: Android storage permission (enforced by the OS, independent of proot)"
  if [ "$sd" = 0 ]; then
    pass "Termux cannot write to /sdcard. Shared storage is protected no matter how you log in."
    info "To also prove the proot layer itself, run this test once after 'termux-setup-storage', expect default login to FAIL and --isolated to PASS, then revoke the permission again."
  else
    warn "Termux has shared storage access" "Containment now relies on proot flags alone. Hardening: Android Settings > Apps > Termux > Permissions > deny Files and media."
  fi

  echo
  echo "layer 2: proot container (canaries planted in Termux home$( [ "$sd" = 1 ] && echo ' and /sdcard'))"
  for mode in default isolated; do
    echo
    echo "--- login mode: $mode ---"
    if [ "$mode" = isolated ]; then
      proot-distro login --isolated ${OC_ANDROID_USER:+--user "$OC_ANDROID_USER"} "$distro" -- bash -s inside "$token" <"$SCRIPT_PATH"
      rc_isolated=$?
    else
      proot-distro login ${OC_ANDROID_USER:+--user "$OC_ANDROID_USER"} "$distro" -- bash -s inside "$token" <"$SCRIPT_PATH"
      rc_default=$?
    fi
  done

  echo
  echo "summary"
  printf '  default login:    %s\n' "$([ "${rc_default:-1}" = 0 ] && echo 'no leak found' || echo 'LEAK or failure (this is what you get if you forget --isolated)')"
  printf '  --isolated login: %s\n' "$([ "${rc_isolated:-1}" = 0 ] && echo 'no leak found' || echo 'LEAK or failure')"
  echo "  your daily login command should be: proot-distro login ${daily} ${distro}"

  if [ "$daily" = "--isolated" ]; then [ "${rc_isolated:-1}" = 0 ]; else [ "${rc_default:-1}" = 0 ]; fi
}

usage() {
  sed -n '2,/^set -uo/p' "$SCRIPT_PATH" | sed '$d' | sed 's/^# \{0,1\}//'
  exit 2
}

case "${1:-}" in
  termux)  termux_mode; exit $? ;;
  inside)  shift; inside_checks "${1:-}" ;;
  project) project_checks ;;
  bench)   bench ;;
  *)       usage ;;
esac

echo
echo "RESULT: $FAILS fail, $WARNS warn"
[ "$FAILS" -eq 0 ]
