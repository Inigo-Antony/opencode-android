# MAINTAINING.md — opencode-android

Maintainer-facing reference: everything an agent or human needs before changing
`bootstrap.sh`, `setup-opencode.sh`, `tests/` or the generated artifacts.
`AGENTS.md` stays small (it is loaded every turn); this file holds the detail.

## The two entrypoints

- `bootstrap.sh` — Termux side. Hard-refuses to run anywhere except Termux
  (checks `TERMUX_VERSION` / `/data/data/com.termux`). Copies repo files into
  the container at `/root/opencode-android` and runs `setup-opencode.sh` there.
- `setup-opencode.sh` — container side. **Must run inside a git repo**
  (`git rev-parse --show-toplevel` or it exits), and refuses Node reporting
  `platform=android` (Termux Node; `bootstrap.sh` installs Node 20 from
  NodeSource). Installs opencode, GSD, graphify, ECC, MCP servers, then
  validates config. Also persists the tool PATH (`~/.opencode/bin`,
  `~/.local/bin`, `~/.npm-global/bin`) to `~/.bashrc` + `~/.profile` via
  `persist_path` — without it, post-setup and agent-spawned shells can't find
  graphify/opencode (GSD's graphify pre-flight false-negatives "not installed").

## Verification

```bash
bash tests/run-tests.sh     # the only automated test; exit 0 = pass
bash -n <script>.sh         # syntax check for any Bash edit
```

- `tests/run-tests.sh` **extracts the embedded `cfg.cjs` from
  `setup-opencode.sh` via awk** (heredoc between `cat > "$CFG" <<'JS'` and the
  line `JS`) and asserts against a temp `opencode.json`. Any edit to the
  embedded JS must stay inside those exact markers or the test silently tests
  stale code.
- New tests must be added **before** the README ratchet block (test 21), which
  computes `EXPECTED = PASS + 2` and enforces the README badge and layout line.
  After adding tests, update the check count in three places: README badge
  (line ~13), README layout line (~146), and this repo's `AGENTS.md` if it
  quotes a count.
- `tests/verify-sandbox.sh` has 4 modes: `termux` (canary leak checks; run
  **only in Termux**), `inside`, `project` (config hygiene: secrets, `share`,
  pinned plugins, `{file:}` refs), `bench` (time/memory). Full behavioral
  tests live in `tests/MANUAL-TESTS.md`.

## cfg.cjs / opencode.json invariants (tested — don't break)

- `opencode.json` is parsed **tolerantly**: JSONC comments, trailing commas,
  and **multiple concatenated `{...}` root objects are merged**. Never assume
  strict-JSON semantics when reading or writing it.
- **`plugin` and `plugins` keys must always be kept identical** in the
  generated config (`syncPlugins()`); OpenCode 1 reads `plugin`, OpenCode 2
  reads `plugins`. `syncPlugins` also normalizes bare ECC plugin names to
  their pinned form.
- `setup-opencode.sh` must stay **idempotent**: re-running repairs
  `opencode.json` every time. `cfg base` uses `??=` so an existing `model` is
  never clobbered (except `--replace-default` swaps the `opencode/big-pickle`
  fallback); `cfg security secure` uses `??=` so user permission rules win,
  and migrates the `~/.local/share/opencode/worktree/**` allow rule (ensemble
  carve-out) into existing configs per-key without overwriting anything the
  user set; `cfg security unlock` overwrites.
- **ECC agent/command diet:** `cfg ecc` filters ECC's ~26 subagents down to an
  allowlist (primaries `build`/`plan` + planner, architect, code-reviewer,
  security-reviewer, tdd-guide, build-error-resolver, python-reviewer,
  docs-lookup) and drops commands whose agent was filtered out. `ECC_AGENTS`
  env extends the allowlist (comma list) or disables filtering (`all`).
  Re-runs prune previously-copied ECC entries that are no longer allowed —
  but only when the entry still deep-equals ECC's definition, so user tweaks
  survive.
- **API keys must never appear literally in `opencode.json`** — MCP headers
  use `{env:VAR}`/`--bearer-env`/`--header` so the value lands at runtime, not
  in a committable file. `project` mode greps for leaks and tests assert this.
- **Backups:** `backup_config` snapshots `opencode.json` to
  `opencode.json.orig` (kept forever, the pristine original) plus a rolling
  `opencode.json.bak.*` (newest kept). Both are gitignored.
- The doctor (`DOCTOR_ONLY=1 bash setup-opencode.sh`) strips `SKILL.md`
  entries from `instructions` (token bloat), keeps `https://` entries, rewrites
  `{file:}` refs to an existing path, and **exits 3 on unresolved refs**.
  `persist_path` and the project-notes step also run under `DOCTOR_ONLY=1`,
  so the env-doctor's "missing from PATH" remediation actually works.
- `templates/security-profile.json` is an auditable mirror of
  `SECURE_PERMISSION` in `setup-opencode.sh` — kept in sync automatically
  (test compares them deep-equal on a fresh config; drift fails the suite).
- **Ensemble plugin is pinned** (`@hueyexe/opencode-ensemble@0.18.0` in
  `install_extras`, behind `ENABLE_ENSEMBLE`): unpinned npm plugins are cached
  once and never auto-update (opencode #6774). Ensemble is default-ON by
  owner decision — each teammate is a full agent context in its own worktree,
  which multiplies RAM and token usage; `ENABLE_ENSEMBLE=0` is the documented
  off-switch for small devices. Never flip the default silently.
- **obsidian-skills is global** at `~/.config/opencode/skills/obsidian-skills`
  — NOT the upstream README's install path, which is not in opencode's
  discovery table. Upstream repo is `obsidianmd/obsidian-skills` (renamed from
  kepano); SKILL.md files sit at `obsidian-skills/plugins/obsidian/skills/<name>/`.
  Re-runs `git pull --ff-only` the clone and logs the HEAD SHA; never mention
  or write the stale path anywhere.
- **AGENTS.md project-notes placeholder:** `ensure_project_notes` runs on
  every setup (even `DOCTOR_ONLY`) and appends a marker-guarded
  `## Project notes` section — the user's hand-editable spot for project
  facts. Marker-guarded: never duplicate it, never touch user edits.
- **`docs/agents-md-template.txt` is a generic template** for foreign
  projects (placeholder sections, no repo-specific invariants). It must never
  become byte-identical to this repo's `AGENTS.md` again — that was audit
  finding F6.

## Efficiency invariants (tested — don't undo)

- **Generated, not tracked:** `opencode.json`, `.opencode/`, `graphify-out/`,
  and `.planning/graphs/` are gitignored (enforced by `update_gitignore`).
  Change `setup-opencode.sh`; never hand-edit those artifacts.
- **PATH persistence:** `persist_path` appends `~/.opencode/bin`,
  `~/.local/bin`, `~/.npm-global/bin` to `~/.bashrc` + `~/.profile`
  (idempotent). Tested by extracting the function and running it twice
  against a temp `HOME`.
- **Instruction diet:** `.opencode/instructions/INSTRUCTIONS.md` is
  repo-owned, deliberately short (ECC's generic 343-line doc is replaced by
  `write_repo_instructions`, which branches: repo heredoc for this repo,
  generic heredoc for foreign projects). Loaded every turn and every
  subagent — keep it under ~90 lines; the test enforces the cap.
- **Agent diet:** ECC ships ~26 subagents + 26 commands; every entry is loaded
  into context each session. `cfg ecc` allowlists (see above). Don't undo
  this — it was audit finding F5.
- **Env doctor:** `write_env_doctor` ships `.opencode/plugins/env-doctor.js`,
  which prepends a `command -v node opencode graphify` probe to the first
  shell command of a session and prints only missing tools. The probe
  distinguishes "installed but missing from PATH" (remediation:
  `DOCTOR_ONLY=1 bash setup-opencode.sh`) from "not installed"
  (remediation: `bash setup-opencode.sh`). The REMINDER block must stay
  POSIX-sh without `$( )`/backticks (test-enforced).
- **MCP policy:** only `context7` (library docs) + `parallel-search` (web).
  Tavily/Exa were retired as duplicates; `cfg mcp-rm` prunes them on every
  run so existing configs migrate, not just fresh installs.
- **Bug → test ratchet:** any bug that costs a debugging session gets a check
  in `tests/run-tests.sh` (see the persist_path and env-doctor checks).

## Conventions that differ from defaults

- `graphify install` **must never be run bare** (it targets Claude); always
  `graphify install --platform opencode`, then `graphify opencode install`.
- Model IDs use the `opencode-go/<model>` form; without Go auth the fallback
  is `opencode/big-pickle`. `OPENCODE_MODEL` always overrides detection;
  `GO_MODEL`/`GO_SMALL_MODEL` only apply when Go auth is detected. Primary
  agents are pinned by `write_agent_models` after ECC: plan = `glm-5.3`,
  build = `glm-5.3-flash` (`GO_PLAN_MODEL`/`GO_BUILD_MODEL`), and
  `cfg agent-model` uses `??=` so a model chosen in `/models` survives
  re-runs.
- Secure posture is deliberate: `share: disabled`, `autoupdate: false`,
  `server.mdns: false`, deny list for destructive bash. Don't relax it in
  defaults; `UNLOCK=1` is the opt-in.
- The proot container is the real security boundary; deny rules are a
  seatbelt. Never add `--termux-home` binds to logins.

## Supply-chain pins (audit F7)

All external sources are pinned to exact versions/SHAs:

| Source | Pin | Where |
|---|---|---|
| get-shit-done-cc | `@${GSD_VERSION}` = 1.42.3 | `install_gsd` |
| graphify (PyPI) | `graphifyy==0.9.111` | `install_graphify` (uv/pipx/pip) |
| everything-claude-code | SHA `3f14a10…` | `install_ecc` |
| @tarquinen/opencode-dcp | `@${DCP_VERSION}` = 3.2.1 | `install_extras` |
| ecc-universal | `@2.2.3` (`ECC_PLUGIN_PIN`) | `syncPlugins` |
| opencode-shell-strategy | SHA `1303f24…` | vendored to `.opencode/instructions/shell-strategy.md` |
| obsidian-skills | tracks `main` (deliberate) | `install_obsidian_skills` |
| @hueyexe/opencode-ensemble | `@0.18.0` | `install_extras` |

All pins are env-overridable (`GSD_VERSION`, `GRAPHIFY_VERSION`, `ECC_REF`,
`DCP_VERSION`). `syncPlugins` normalizes any bare or older-pinned
`ecc-universal` spelling to the current pin, so re-runs migrate old configs.
When bumping a pin, update the version in `setup-opencode.sh` only.

## ECC cache (audit F8)

`install_ecc` clones once into `~/.cache/opencode-android/ecc` and reuses it;
it re-clones only when the pinned SHA is not in the cache or `ECC_REFRESH=1`
forces a refresh. The doctor's exit-3 retry re-runs `install_ecc`, and a
healthy cache makes that retry cheap.

## Performance notes (audit F11 — recorded, deliberately not optimized)

Setup spawns `node` roughly 17 times (one per `cfg` subcommand). That cost
was measured in audit F11 and accepted: setup runs once per project, not per
session, and batching `cfg` calls into one process would complicate the
subcommand API for seconds of savings. If a future change wants to revisit
this, baseline with `bash tests/verify-sandbox.sh bench` (start time and peak
memory of one trivial in-container run) and compare against the audit §6
table in `opencode-android-audit.md` before and after.
