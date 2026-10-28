#!/usr/bin/env bash
# setup-opencode.sh  —  v3 (proot-distro / Termux / Android friendly)
#
# Usage:      bash setup-opencode.sh
# Re-runs:    idempotent and safe; repairs opencode.json on every run.
#
# Options (env vars):
#   SKIP_OPENCODE=1 SKIP_GSD=1 SKIP_GRAPHIFY=1 SKIP_ECC=1 SKIP_MCP=1 SKIP_EXTRAS=1
#   OPENCODE_MODEL=...            force main model (e.g. opencode-go/glm-5.3-flash)
#   OPENCODE_SMALL_MODEL=...      force small model
#   GO_MODEL=glm-5.3-flash        main model used when OpenCode Go auth is detected
#   GO_SMALL_MODEL=glm-5.3-flash  small model used when OpenCode Go auth is detected
#   GO_PLAN_MODEL=glm-5.3         plan agent model (reasoning, still cheap)
#   GO_BUILD_MODEL=glm-5.3-flash  build agent model (fast coder)
#   OPENCODE_PLAN_MODEL=...       force the plan agent model
#   OPENCODE_BUILD_MODEL=...      force the build agent model
#   SECURITY_PROFILE=secure|keep  secure (default) locks destructive bash + outside
#                                 reads; keep leaves your permission settings alone
#   UNLOCK=1                      power-user mode: allow everything, ask nothing
#   ECC_SKILLS=core|all|none      core = 11 essentials (default); all = 300+ skills
#   ENABLE_CONTEXT7=1 ENABLE_PARALLEL=1   remote MCPs (docs + web search).
#                                 tavily/exa are retired and pruned on every run.
#   ENABLE_DCP=1 ENABLE_SHELL_STRATEGY=1   phone QoL extras (context pruning,
#                                 anti-hang shell rules). 0 disables either.
#   DOCTOR_ONLY=1                 only repair + validate opencode.json
#
# Layout it produces, per project:
#   opencode.json                merged/validated config (doctor pass)
#   .opencode/{prompts,commands,skills,instructions}
#   .opencode/plugins/graphify.js (graphify installer)
#   .opencode/plugins/env-doctor.js (first-command PATH probe)
#   .env (optional)              extra env for MCPs/services, never committed
#
# Model policy (Go-first, no hardcoded keys):
#   - If OpenCode Go auth is found (open opencode and run: /connect), the default
#     model becomes opencode-go/$GO_MODEL and small_model opencode-go/$GO_SMALL_MODEL
#     (both default to glm-5.3-flash).
#   - Primary agents get their own defaults: plan = $GO_PLAN_MODEL (glm-5.3,
#     standard frontier and cheap), build = $GO_BUILD_MODEL (glm-5.3-flash, fast
#     coder). Tab in the TUI switches between them.
#   - Otherwise falls back to opencode/big-pickle (free, no key).
#   - OPENCODE_MODEL always wins.

set -uo pipefail

ECC_REPO="${ECC_REPO:-https://github.com/affaan-m/everything-claude-code.git}"
ECC_SKILLS="${ECC_SKILLS:-core}"
CORE_SKILLS="tdd-workflow security-review coding-standards frontend-patterns frontend-slides backend-patterns e2e-testing verification-loop api-design strategic-compact eval-harness"
SHELL_STRATEGY_URL="https://raw.githubusercontent.com/JRedeker/opencode-shell-strategy/trunk/shell_strategy.md"

RESULTS=()
log()    { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()     { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn()   { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
fail()   { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; }
need()   { command -v "$1" >/dev/null 2>&1; }
record() { RESULTS+=("$1: $2"); }

# ---------- preflight ----------
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$ROOT" ]; then
  fail "Not inside a git repository. cd into your project (or run: git init) first."
  exit 1
fi
cd "$ROOT" || exit 1
log "Project root: $ROOT"

# The directory this script lives in (repo checkout of opencode-android)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

# ...and persist that PATH to shell startup files. The export above only covers
# this script's own process; graphify (pipx/uv/pip --user) and opencode land in
# ~/.local/bin / ~/.opencode/bin, and every shell started after setup — including
# the non-interactive ones opencode spawns for agents, and the GSD graphify
# pre-flight (`gsd-tools.cjs graphify build`) — inherits PATH from the login
# shell. Without this, a fresh login hits false "graphify is not installed".
persist_path() {
  local line='export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"'
  local marker='# opencode-android tool PATH'
  local rc
  for rc in "$HOME/.bashrc" "$HOME/.profile"; do
    # One unwritable rc (read-only home, immutable dotfile) must not skip the other.
    touch "$rc" 2>/dev/null || { echo "  ! cannot write $rc" >&2; continue; }
    if [ -s "$rc" ] && [ -n "$(tail -c 1 "$rc" 2>/dev/null)" ]; then echo >> "$rc"; fi
    # Guard on the marker as well as the exact line, so a hand-written PATH export
    # never yields a second marked block on re-runs.
    grep -qF "$line" "$rc" || printf '%s\n' "$line" >> "$rc"
    grep -qF "$marker" "$rc" || printf '%s\n' "$marker" >> "$rc"
  done
}

# proot often has no writable/working /tmp or TMPDIR from Termux; use a private one
WORK="$(mktemp -d 2>/dev/null || true)"
if [ -z "$WORK" ] || [ ! -w "$WORK" ]; then
  WORK="$ROOT/.opencode/.tmp-setup"; rm -rf "$WORK"; mkdir -p "$WORK"
fi
export TMPDIR="$WORK"
trap 'rm -rf "$WORK"' EXIT

# ---------- checks: tools, node, platform, DNS ----------
missing_tools=()
for bin in curl git node npm npx; do need "$bin" || missing_tools+=("$bin"); done
if [ ${#missing_tools[@]} -gt 0 ]; then
  fail "Missing: ${missing_tools[*]}"
  echo "  Inside proot Ubuntu:  apt update && apt install -y curl git python3-pip pipx"
  echo "  Node 20 LTS:          curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt install -y nodejs"
  exit 1
fi
if ! node -e 'process.exit(+process.versions.node.split(".")[0] >= 18 ? 0 : 1)'; then
  fail "Node 18+ required (found $(node -v)). Install Node 20 via NodeSource (see above)."
  exit 1
fi
# Termux ships a Node that reports platform "android"; most tooling (Playwright,
# npm platform checks, plugins) breaks on it. Everything must run on a *Linux*
# Node inside the proot distro, never on Termux's Android-hostile Node.
if [ "$(node -p 'process.platform')" = "android" ]; then
  fail "Node here reports platform=android (Termux Node). This setup must run inside"
  echo "  proot-distro with a Linux Node:  proot-distro login ubuntu"
  echo "  then:  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt install -y nodejs"
  exit 1
fi

if [ "${DOCTOR_ONLY:-0}" != "1" ]; then
  # DNS inside proot is the #1 cause of silent clone/install failures
  if ! curl -fsS --max-time 10 -o /dev/null https://github.com; then
    fail "Cannot reach github.com. Inside proot, fix DNS with:"
    echo "  echo 'nameserver 8.8.8.8' > /etc/resolv.conf"
    exit 1
  fi
  # optional .env with API keys (never committed)
  # shellcheck disable=SC1091
  if [ -f .env ]; then set -a; . ./.env; set +a; fi
fi

# ---------- config helper (one node script, several subcommands) ----------
CFG="$WORK/cfg.cjs"
cat > "$CFG" <<'JS'
const fs = require('fs');
const F = 'opencode.json';
const [, , cmd, ...args] = process.argv;

// Read opencode.json tolerantly: strips // and /* */ comments, merges multiple
// top-level objects (e.g. a block appended with >>) into one.
function splitRoots(s) {
  const out = []; let depth = 0, start = -1, inStr = false, esc = false;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i], nx = s[i + 1];
    if (inStr) { if (esc) esc = false; else if (ch === '\\') esc = true; else if (ch === '"') inStr = false; continue; }
    if (ch === '/' && nx === '/') { while (i < s.length && s[i] !== '\n') i++; continue; }
    if (ch === '/' && nx === '*') { i = s.indexOf('*/', i + 2); if (i < 0) break; i++; continue; }
    if (ch === '"') inStr = true;
    else if (ch === '{') { if (depth++ === 0) start = i; }
    else if (ch === '}') { if (--depth === 0) out.push(s.slice(start, i + 1)); }
  }
  return out;
}
const stripComments = s => s.replace(/("(?:\\.|[^"\\])*")|\/\/[^\n]*|\/\*[\s\S]*?\*\//g, (m, str) => str || '');
const stripTrailingCommas = s => s.replace(/("(?:\\.|[^"\\])*")|,(\s*[}\]])/g, (m, str, tail) => str || tail);
function merge(a, b) {
  for (const [k, v] of Object.entries(b)) {
    if (Array.isArray(v) && Array.isArray(a[k])) a[k] = [...new Set([...a[k], ...v])];
    else if (v && typeof v === 'object' && !Array.isArray(v) && a[k] && typeof a[k] === 'object' && !Array.isArray(a[k])) merge(a[k], v);
    else a[k] = v;
  }
  return a;
}
function load(file = F) {
  if (!fs.existsSync(file)) return {};
  const roots = splitRoots(fs.readFileSync(file, 'utf8'))
    .map(r => JSON.parse(stripTrailingCommas(stripComments(r))));
  if (roots.length > 1) console.error(`[info] merged ${roots.length} top-level objects in ${file}`);
  return roots.reduce((acc, r) => merge(acc, r), {});
}
const save = c => fs.writeFileSync(F, JSON.stringify(c, null, 2) + '\n');

// Keep the two plugin keys identical. OpenCode 1 reads "plugin", OpenCode 2
// (Sept 2026) reads "plugins"; setting both makes the config portable across
// both versions and re-runs.
function syncPlugins(c) {
  const p = [...new Set([...(c.plugin || []), ...(c.plugins || [])])];
  if (!p.length) return null;
  c.plugin = p; c.plugins = p;
  return p;
}

// Secure profile. Rules are evaluated last-match-wins, glob style.
// The proot container is the real boundary; this is the seatbelt in front of it.
const SECURE_PERMISSION = {
  '*': 'allow',
  bash: {
    '*': 'allow',
    'rm -rf /*': 'deny',
    'rm -rf ~*': 'deny',
    'rm -rf $HOME*': 'deny',
    'rm -fr /*': 'deny',
    'chmod -R 777 *': 'deny',
    'dd *': 'deny',
    'mkfs*': 'deny',
    'shutdown*': 'deny',
    'reboot*': 'deny'
  },
  external_directory: {
    '*': 'ask',
    '/tmp/*': 'allow',
    '/var/tmp/*': 'allow'
  }
};
const UNLOCKED_PERMISSION = {
  '*': 'allow',
  bash: { '*': 'allow' },
  external_directory: { '*': 'allow', '/tmp/*': 'allow' }
};

try {
  if (cmd === 'base') {
    const [model, smallModel, flag, defModel] = args; const c = load();
    c.$schema ??= 'https://opencode.ai/config.json';
    // --replace-default: when the only model present is our own no-key fallback
    // (e.g. user ran /connect for OpenCode Go after the first setup), upgrade it.
    // Any other existing model is a deliberate choice and is kept.
    if (flag === '--replace-default' && defModel && (!c.model || c.model === defModel)) {
      c.model = model; c.small_model = smallModel || model;
    }
    else {
      // any other existing model is a deliberate choice — never clobber it
      c.model ??= model; c.small_model ??= (smallModel || model);
    }
    save(c);
  }
  else if (cmd === 'ecc') {               // args: path to ECC's .opencode/opencode.json
    const c = load(); const src = args[0] && fs.existsSync(args[0]) ? load(args[0]) : {};
    const p = syncPlugins({ plugin: [...(c.plugin || []), ...(c.plugins || []), 'ecc-universal'] }) || [];
    c.plugin = p; c.plugins = p;
    c.default_agent ??= 'build';
    for (const k of ['agent', 'command']) if (src[k]) c[k] = { ...src[k], ...(c[k] || {}) };
    // Only ECC's short core instructions file is always-on; skills load on demand.
    const ins = '.opencode/instructions/INSTRUCTIONS.md';
    if (fs.existsSync(ins)) c.instructions = [...new Set([...(c.instructions || []), ins])];
    save(c);
  }
  else if (cmd === 'mcp') {               // args: name url [--bearer-env ENVVAR] [--header NAME ENVVAR]...
    const [name, url] = args; const c = load();
    c.mcp ??= {};
    if (c.mcp[name]) { process.stdout.write('  exists: mcp/' + name + '\n'); save(c); process.exit(0); }
    const entry = { type: 'remote', url, enabled: true };
    for (let i = 2; i < args.length; i++) {
      if (args[i] === '--bearer-env' || args[i] === '--header') {
        const envvar = args[i] === '--bearer-env' ? args[i + 1] : args[i + 2];
        const val = envvar ? process.env[envvar] : '';
        if (val) {
          entry.headers ??= {};
          entry.headers[args[i] === '--bearer-env' ? 'Authorization' : args[i + 1]] =
            args[i] === '--bearer-env' ? `Bearer ${val}` : val;
        }
        i += args[i] === '--bearer-env' ? 1 : 2;
      }
    }
    c.mcp[name] = entry;
    save(c);
  }
  else if (cmd === 'mcp-rm') {            // args: name  (prune a retired server)
    const [name] = args; const c = load();
    // hasOwn: inherited keys (__proto__, constructor) must not report a removal.
    if (c.mcp && Object.hasOwn(c.mcp, name)) { delete c.mcp[name]; save(c); console.log('removed: mcp/' + name); }
  }
  else if (cmd === 'agent-model') {       // args: name model  (never clobber)
    const [name, model] = args; const c = load();
    if (!name || !model) { console.error('usage: cfg agent-model <name> <model>'); process.exit(2); }
    c.agent ??= {}; c.agent[name] ??= {}; c.agent[name].model ??= model; save(c);
  }
  else if (cmd === 'security') {          // args: secure|unlock|keep
    const [mode] = args; const c = load();
    c.$schema ??= 'https://opencode.ai/config.json';
    if (mode === 'unlock') {
      c.permission = UNLOCKED_PERMISSION;
      c.share = 'disabled'; c.autoupdate = false;
      c.server ??= {}; c.server.mdns = false;
    }
    else if (mode === 'secure') {
      c.permission ??= SECURE_PERMISSION;      // explicit user settings win
      c.share ??= 'disabled';
      c.autoupdate ??= false;
      c.server ??= {}; c.server.mdns ??= false;
    }
    // 'keep' changes nothing; only used to report the current profile.
    let profile = 'custom';
    if (JSON.stringify(c.permission) === JSON.stringify(UNLOCKED_PERMISSION)) profile = 'unlocked';
    else if (c.permission && JSON.stringify(c.permission.external_directory) === JSON.stringify(SECURE_PERMISSION.external_directory)) profile = 'secure';
    console.log('profile=' + profile);
    save(c);
  }
  else if (cmd === 'instruction') {       // args: --add value | --strip-skill-md
    const [flag, ...rest] = args; const c = load();
    if (flag === '--add' && rest[0]) {
      const v = rest[0];
      const arr = Array.isArray(c.instructions) ? c.instructions : (c.instructions ? [c.instructions] : []);
      if (!arr.includes(v)) { arr.push(v); c.instructions = arr; }
    }
    if (flag === '--strip-skill-md' && Array.isArray(c.instructions)) {
      const before = c.instructions.length;
      c.instructions = c.instructions.filter(p =>
        (fs.existsSync(p) || /^https?:\/\//.test(p)) && !/\/SKILL\.md$/.test(p));
      if (before !== c.instructions.length) console.error(`[info] removed ${before - c.instructions.length} skill/missing entries from "instructions"`);
      if (!c.instructions.length) delete c.instructions;
    }
    save(c);
  }
  else if (cmd === 'plugin') {            // args: add value
    const [flag, value] = args; const c = load();
    if (flag === 'add' && value) {
      const p = syncPlugins({ plugin: [...(c.plugin || []), ...(c.plugins || []), value] }) || [];
      c.plugin = p; c.plugins = p;
    }
    save(c);
  }
  else if (cmd === 'doctor') {
    let c = load();
    // Old setups listed every SKILL.md as an always-on instruction (huge token
    // cost). Skills in .opencode/skills/ are discovered on demand, so drop them.
    // Remote (https://) instruction files are kept.
    if (Array.isArray(c.instructions)) {
      const before = c.instructions.length;
      c.instructions = c.instructions.filter(p =>
        (fs.existsSync(p) || /^https?:\/\//.test(p)) && !/\/SKILL\.md$/.test(p));
      if (before !== c.instructions.length) console.error(`[info] removed ${before - c.instructions.length} skill/missing entries from "instructions"`);
      if (!c.instructions.length) delete c.instructions;
    }
    // Point every {file:x} at a location that exists (repo root or .opencode/).
    syncPlugins(c);
    const missing = [];
    const out = JSON.stringify(c).replace(/\{file:([^}]+)\}/g, (m, p) => {
      const base = p.replace(/^\.opencode\//, '');
      if (fs.existsSync(p)) return m;
      if (fs.existsSync('.opencode/' + base)) return '{file:.opencode/' + base + '}';
      if (fs.existsSync(base)) return '{file:' + base + '}';
      missing.push(p); return m;
    });
    c = JSON.parse(out);
    save(c);
    const n = o => Object.keys(o || {}).length;
    const prof = JSON.stringify(c.permission) === JSON.stringify(UNLOCKED_PERMISSION)
      ? 'unlocked'
      : (c.permission && JSON.stringify(c.permission.external_directory) === JSON.stringify(SECURE_PERMISSION.external_directory) ? 'secure' : 'custom');
    console.log(`model=${c.model}  agents=${n(c.agent)}  commands=${n(c.command)}  mcp=${Object.keys(c.mcp || {}).join(',') || 'none'}  plugins=${(c.plugins || c.plugin || []).join(',') || 'none'}  security=${prof}  share=${c.share || 'default'}`);
    if (missing.length) { console.error('[fail] unresolved {file:} refs:\n  ' + missing.join('\n  ')); process.exit(3); }
  }
  else { console.error('unknown subcommand ' + cmd); process.exit(1); }
} catch (e) {
  console.error('[fail] opencode.json could not be parsed: ' + e.message);
  process.exit(2);
}
JS
cfg() { node "$CFG" "$@"; }

backup_config() {
  [ -f opencode.json ] || return 0
  local b
  b="opencode.json.bak.$(date +%Y%m%d-%H%M%S)"
  cp opencode.json "$b" && log "Backed up existing config to $b"
}

# ---------- 1. opencode ----------
install_opencode() {
  if need opencode; then
    log "opencode already installed: $(opencode --version 2>/dev/null || echo unknown)"
    return 0
  fi
  log "Installing opencode"
  curl -fsSL https://opencode.ai/install | bash || npm install -g opencode-ai || return 1
  hash -r
  need opencode || { fail "opencode not on PATH. Add: export PATH=\"\$HOME/.opencode/bin:\$PATH\""; return 1; }
}

# ---------- 2 + model selection ----------
# OpenCode Go detection: creds live in auth.json (written by `/connect`).
detect_go_auth() {
  local f="$HOME/.local/share/opencode/auth.json"
  [ -f "$f" ] && grep -q '"opencode-go"\|"opencode\.go"' "$f" 2>/dev/null && return 0
  need opencode && opencode auth list 2>/dev/null | grep -qi 'opencode-go\|opencode\.go' && return 0
  return 1
}

write_base_config() {
  local model small_model
  if [ -n "${OPENCODE_MODEL:-}" ]; then
    model="$OPENCODE_MODEL" small_model="${OPENCODE_SMALL_MODEL:-$OPENCODE_MODEL}"
    log "Writing base config (forced model: $model)"
  elif detect_go_auth; then
    model="opencode-go/${GO_MODEL:-glm-5.3-flash}"
    small_model="opencode-go/${GO_SMALL_MODEL:-glm-5.3-flash}"
    log "Writing base config (OpenCode Go detected: $model)"
  else
    model="opencode/big-pickle" small_model="$model"
    log "Writing base config (model: $model — free; run /connect in opencode for OpenCode Go)"
  fi
  # upgrade a previously-written keyless default if a better auth now exists
  cfg base "$model" "$small_model" --replace-default "opencode/big-pickle"
}

# ---------- 3. GSD ----------
install_gsd() {
  log "Installing GSD for OpenCode (project-local)"
  npx --yes get-shit-done-cc@latest --opencode --local && return 0
  warn "Local GSD install failed; falling back to global (~/.config/opencode)"
  npx --yes get-shit-done-cc@latest --opencode --global
}

# ---------- 4. graphify ----------
install_graphify() {
  log "Installing graphify"
  if ! need graphify; then
    if need uv; then
      uv tool install graphifyy || uv tool upgrade graphifyy
    elif need pipx; then
      pipx install graphifyy
    elif need pip3 || need pip; then
      local pip_bin; pip_bin="$(command -v pip3 || command -v pip)"
      "$pip_bin" install --user graphifyy \
        || "$pip_bin" install --user --break-system-packages graphifyy
    else
      fail "No uv, pipx or pip. Run: apt install -y pipx"
      return 1
    fi
    hash -r
  fi
  need graphify || { fail "graphify not on PATH (expected in ~/.local/bin)."; return 1; }
  graphify install --platform opencode || return 1   # global skill (NEVER bare: targets claude)
  graphify opencode install || return 1              # AGENTS.md + plugin in this repo
  if [ -f .opencode/plugins/graphify.js ]; then
    cfg plugin add ".opencode/plugins/graphify.js"
    cfg instruction --add AGENTS.md
  fi
}

# ---------- 4b. repo instructions (token diet) ----------
# ECC ships a 343-line generic doc (React/Zod/coverage rules) that does not apply
# to a Bash-only repo but is loaded into every turn and every subagent. Replace
# it with a short repo-specific ruleset. install_ecc copies with `cp -Rn` (no
# clobber), so this file survives later ECC updates; a re-run repairs it if ECC
# ever overwrites it. Keep it under ~90 lines — it is a per-turn token budget.
write_repo_instructions() {
  mkdir -p .opencode/instructions
  cat > .opencode/instructions/INSTRUCTIONS.md <<'MD'
# Repo rules (distilled)

Bash-only: `bootstrap.sh` (Termux) and `setup-opencode.sh` (container, embeds
one Node script `cfg.cjs`). No package manifests, no linters, no CI. Keep this
file short: it is loaded on every turn.

## Verify before claiming done
- `bash -n <file>.sh` for every shell file you edited.
- `bash tests/run-tests.sh` → final line `PASS=<n> FAIL=0`.
- `DOCTOR_ONLY=1 bash setup-opencode.sh` when config generation changed.
- Any behavior fix gets a check in `tests/run-tests.sh`. Bug → test, so the
  class cannot come back.

## Security (non-negotiable)
- No secrets in code or in `opencode.json`. Use env vars, `{env:VAR}`,
  `--bearer-env`, or `--header`; values resolve at runtime.
- Quote shell variables; never interpolate untrusted paths unquoted.
- Never add `--termux-home` binds: the proot container is the security boundary.
- Keep secure defaults (share disabled, autoupdate off, mdns off, destructive
  bash denied). `UNLOCK=1` is the only opt-in.
- Found a security issue? Stop, fix it, report it.

## Editing rules
- `.opencode/` and `opencode.json` are generated and gitignored. Change the
  generator (`setup-opencode.sh`); never hand-edit the artifact.
- Setup must stay idempotent: re-runs repair config and never clobber a user's
  model or permission choices (`cfg` uses `??=` deliberately).
- Read `opencode.json` tolerantly: JSONC comments, trailing commas, and
  multiple concatenated root objects are merged.
- Keep `plugin` and `plugins` identical (`syncPlugins()`); OpenCode 1 vs 2.
- Small, focused edits. No drive-by refactors.

## Token hygiene
- If `graphify-out/graph.json` exists, query it before grepping source
  (see AGENTS.md). Prefer targeted reads (`offset`/`limit`) and `rg` over
  dumping whole files. Summarize tool output instead of pasting it back.

## Git
- Commit only when asked. Conventional messages: `type: summary`.
- Never commit secrets, `.opencode/`, `opencode.json`, or `graphify-out/`.

## Agents (use when the job matches)
- `planner`: multi-file or architectural work, before coding.
- `tdd-guide`: new behavior, failing test first.
- `code-reviewer` / `security-reviewer`: after writing code, before commit.
MD
  cfg instruction --add .opencode/instructions/INSTRUCTIONS.md
}

# ---------- 5. everything-claude-code ----------
copy_nc() { mkdir -p "$2"; cp -Rn "$1/." "$2/" 2>/dev/null || true; }

install_ecc() {
  log "Installing everything-claude-code (skills: $ECC_SKILLS)"
  local e="$WORK/ecc"
  rm -rf "$e"
  git clone --depth 1 -q "$ECC_REPO" "$e" || { fail "git clone of ECC failed"; return 1; }

  for d in prompts commands instructions; do
    [ -d "$e/.opencode/$d" ] && copy_nc "$e/.opencode/$d" ".opencode/$d"
  done

  case "$ECC_SKILLS" in
    all)  copy_nc "$e/skills" ".opencode/skills" ;;
    none) ;;
    *)    for s in $CORE_SKILLS; do
            [ -d "$e/skills/$s" ] && copy_nc "$e/skills/$s" ".opencode/skills/$s"
          done ;;
  esac

  # sanity check: these are what broke last time
  local np nc
  np=$(find .opencode/prompts -type f 2>/dev/null | wc -l)
  nc=$(find .opencode/commands -type f 2>/dev/null | wc -l)
  if [ "$np" -gt 0 ] && [ "$nc" -gt 0 ]; then :; else
    fail "ECC prompts/commands were not copied"
    return 1
  fi
  log "  prompts: $np  commands: $nc  skills: $(find .opencode/skills -name SKILL.md 2>/dev/null | wc -l)"

  cfg ecc "$e/.opencode/opencode.json"
}

# ---------- 5b. per-agent models ----------
# Plan reasons over a standard frontier model; build writes code with the fast
# coder. Defaults only: cfg agent-model uses ??=, so a model picked in /models
# survives re-runs. Runs after ECC so the model lands inside ECC's build agent
# entry instead of an entry that would shadow it.
write_agent_models() {
  local plan_model build_model
  if [ -n "${OPENCODE_PLAN_MODEL:-}" ]; then
    plan_model="$OPENCODE_PLAN_MODEL"
  elif detect_go_auth; then
    plan_model="opencode-go/${GO_PLAN_MODEL:-glm-5.3}"
  else
    plan_model="opencode/big-pickle"
  fi
  if [ -n "${OPENCODE_BUILD_MODEL:-}" ]; then
    build_model="$OPENCODE_BUILD_MODEL"
  elif detect_go_auth; then
    build_model="opencode-go/${GO_BUILD_MODEL:-glm-5.3-flash}"
  else
    build_model="opencode/big-pickle"
  fi
  cfg agent-model plan  "$plan_model"
  cfg agent-model build "$build_model"
}

# ---------- 6. MCP servers (all remote, no JSON-inlined secrets) ----------
install_mcp() {
  log "Adding MCP servers (context7 + parallel-search)"
  # Tavily and Exa only duplicated parallel-search (search + fetch) while each
  # added a permanent per-turn tool-schema cost. Prune them on every run so a
  # re-run migrates existing configs, not just fresh installs.
  cfg mcp-rm tavily >/dev/null || true
  cfg mcp-rm exa >/dev/null || true
  [ "${ENABLE_CONTEXT7:-1}" = "1" ] && cfg mcp context7        "https://mcp.context7.com/mcp"
  [ "${ENABLE_PARALLEL:-1}" = "1" ] && cfg mcp parallel-search "https://search.parallel.ai/mcp"
  return 0
}

# ---------- 6b. env doctor plugin ----------
# First-command PATH probe. The graphify install bug (binary present, but no
# shell PATH entry) cost a whole diagnostic session; this turns that class into
# one visible line. Written every run, so re-runs repair it. Keep the probe
# POSIX sh and free of backticks/$( ): it runs inline before the first command.
write_env_doctor() {
  mkdir -p .opencode/plugins
  cat > .opencode/plugins/env-doctor.js <<'JS'
// env-doctor OpenCode plugin
// Prepends a PATH probe to the first shell command of a session. Prints one
// line per missing tool, nothing when healthy. Guards the installer bug class
// where a binary is written but no shell can find it (see persist_path).
//
// One file for both runtimes: OpenCode 2 reads `id` + `setup()`; OpenCode 1
// reads `server()`. Nothing is imported from an opencode package.
// Runs regardless of graph presence; the probe is POSIX sh (Linux/Termux).
//
// Keep the probe free of backticks and $(...) — it is executed inline.
const REMINDER =
  'for c in node opencode graphify; do command -v "$c" >/dev/null 2>&1 || echo "[env-doctor] $c is missing from PATH - run: DOCTOR_ONLY=1 bash setup-opencode.sh"; done ; ';

const location = [...import.meta.url].reduce((hash, ch) => (Math.imul(hash, 31) + ch.charCodeAt(0)) >>> 0, 7);
const checked = (globalThis.__envDoctorChecked ??= new Set());

export default {
  id: `env-doctor-${location.toString(16)}`,

  async setup(ctx) {
    await ctx.tool.hook("execute.before", (event) => {
      if (event.tool !== "shell" || typeof event.input?.command !== "string") return;
      if (checked.has(event.sessionID)) return;
      event.input = { ...event.input, command: REMINDER + event.input.command };
      checked.add(event.sessionID);
    });
  },

  async server({ directory }) {
    return {
      "tool.execute.before": async (input, output) => {
        if (input.tool !== "bash" || typeof output.args?.command !== "string") return;
        if (checked.has(directory)) return;
        output.args.command = REMINDER + output.args.command;
        checked.add(directory);
      },
    };
  },
};
JS
  cfg plugin add ".opencode/plugins/env-doctor.js"
}

# ---------- 7. phone QoL extras ----------
install_extras() {
  log "Adding phone QoL extras"
  if [ "${ENABLE_DCP:-1}" = "1" ]; then
    # dynamic context pruning: prunes stale tool outputs (huge for small RAM / mobile sessions)
    cfg plugin add "@tarquinen/opencode-dcp" && log "  dcp enabled"
  fi
  if [ "${ENABLE_SHELL_STRATEGY:-1}" = "1" ]; then
    # non-interactive shell rules: stops agents hanging on TTY prompts (common in proot)
    cfg instruction --add "$SHELL_STRATEGY_URL" && log "  shell-strategy instructions enabled"
  fi
  return 0
}

# ---------- 8. security profile ----------
apply_security() {
  if [ "${UNLOCK:-0}" = "1" ]; then
    log "Security: UNLOCKED mode (allow everything — power-user flow)"
    record "security" "unlocked (by UNLOCK=1)"
    cfg security unlock
    return 0
  fi
  case "${SECURITY_PROFILE:-secure}" in
    keep) cfg security keep ;;
    *)    log "Security: secure profile (destructive bash denied, outside reads ask, no share/auto-update)"
          cfg security secure ;;
  esac
}

# ---------- 9. gitignore ----------
update_gitignore() {
  touch .gitignore
  # graphify-out/ is a rebuildable artifact (graphify update .) and .planning/graphs/
  # holds GSD copies of it; committing either would land an 800K+ diff per build.
  for line in 'opencode.json.bak.*' '.opencode/.tmp-setup/' '.opencode/node_modules/' '.env' 'graphify-out/' '.planning/graphs/'; do
    grep -qxF "$line" .gitignore || echo "$line" >> .gitignore
  done
}

# ---------- 10. doctor ----------
doctor() {
  log "Validating opencode.json"
  local summary rc
  summary="$(cfg doctor)"; rc=$?
  [ -n "$summary" ] && echo "  $summary"
  if [ $rc -eq 3 ]; then
    if [ -n "${DOCTOR_RETRIED:-}" ]; then return 1; fi
    warn "Missing ECC files; re-fetching them"
    DOCTOR_RETRIED=1
    install_ecc && doctor; return $?
  fi
  return $rc
}

# ---------- run ----------
run_step() {  # name, skip-var-value, function
  local name="$1" skip="$2" fn="$3" rc
  if [ "$skip" = "1" ]; then record "$name" "skipped"; return 0; fi
  if "$fn"; then record "$name" "ok"; else record "$name" "FAILED"; fi
}

backup_config

if [ "${DOCTOR_ONLY:-0}" != "1" ]; then
  run_step "opencode"               "${SKIP_OPENCODE:-0}"  install_opencode
  run_step "base config"            "0"                    write_base_config
  run_step "security profile"       "0"                    apply_security
  run_step "GSD"                    "${SKIP_GSD:-0}"       install_gsd
  run_step "graphify"               "${SKIP_GRAPHIFY:-0}"  install_graphify
  run_step "repo instructions"      "0"                    write_repo_instructions
  run_step "everything-claude-code" "${SKIP_ECC:-0}"       install_ecc
  run_step "agent models"           "0"                    write_agent_models
  run_step "MCP servers"            "${SKIP_MCP:-0}"       install_mcp
  run_step "env doctor plugin"      "0"                    write_env_doctor
  run_step "phone extras"           "${SKIP_EXTRAS:-0}"    install_extras
  run_step "gitignore"              "0"                    update_gitignore
  run_step "PATH persistence"       "0"                    persist_path
fi
run_step "config doctor" "0" doctor

echo
log "Summary"
for r in "${RESULTS[@]}"; do echo "  - $r"; done

if printf '%s\n' "${RESULTS[@]}" | grep -q 'config doctor: FAILED' || printf '%s\n' "${RESULTS[@]}" | grep -q 'security profile: FAILED'; then
  if [ "${UNLOCK:-0}" = "1" ]; then
    fail "Setup still has problems (see above). Backups: ls opencode.json.bak.*"
  else
    fail "opencode.json still has problems (see above). Backups: ls opencode.json.bak.*"
  fi
  exit 1
fi

cat <<EOF

Ready. Next:
  1. opencode                 # launch in this repo (first start installs the plugins)
  2. /connect                 # OpenCode Go users: paste your key, then /models
                              #   everyone else: Big Pickle is already set, no key
  3. /gsd-help                # verify GSD
  4. /graphify .              # build the knowledge graph
  5. /plan <task>  or  /tdd   # ECC commands; Tab switches primary agents, @planner calls a subagent

Tips:
  - Tab switches Build (glm-5.3-flash, fast coder) and Plan (glm-5.3, reasoning).
    Go models use the form opencode-go/<model>.
    Override anytime:  OPENCODE_MODEL=opencode-go/grok-4.7 bash setup-opencode.sh
  - MCPs: context7 (library docs) + parallel-search (web). Both keyless.
  - Session without approval prompts:  UNLOCK=1 bash setup-opencode.sh   (re-run doctor after: DOCTOR_ONLY=1 bash setup-opencode.sh)
  - Something broke later?  DOCTOR_ONLY=1 bash setup-opencode.sh
  - Keep this project out of reach? The proot container is your sandbox — do NOT
    add --termux-home binds if you care about your main files. (see docs/SECURITY.md)
EOF
