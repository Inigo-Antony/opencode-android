# AGENTS.md — opencode-android

Installs and configures OpenCode on Android (Termux + proot-distro Ubuntu). **Scripts-only repo: Bash + one Node script embedded in a Bash heredoc.** No package manifests, no linters, no CI.

## The two entrypoints

- `bootstrap.sh` — Termux side. Hard-refuses to run anywhere except Termux (checks `TERMUX_VERSION` / `/data/data/com.termux`). Copies repo files into the container at `/root/opencode-android` and runs `setup-opencode.sh` there.
- `setup-opencode.sh` — container side. **Must run inside a git repo** (`git rev-parse --show-toplevel` or it exits), and refuses Node reporting `platform=android` (Termux Node; `bootstrap.sh` installs Node 20 from NodeSource). Installs opencode, GSD, graphify, ECC, MCP servers, then validates config. Also persists the tool PATH (`~/.opencode/bin`, `~/.local/bin`, `~/.npm-global/bin`) to `~/.bashrc` + `~/.profile` via `persist_path` — without it, post-setup and agent-spawned shells can't find graphify/opencode (GSD's graphify pre-flight false-negatives "not installed").

## Verification

```bash
bash tests/run-tests.sh     # the only automated test; exit 0 = pass (50 checks)
bash -n <script>.sh         # syntax check for any Bash edit
```

- `tests/run-tests.sh` **extracts the embedded `cfg.cjs` from `setup-opencode.sh` via awk** (heredoc between `cat > "$CFG" <<'JS'` and the line `JS`) and asserts against a temp `opencode.json`. Any edit to the embedded JS must stay inside those exact markers or the test silently tests stale code.
- `tests/verify-sandbox.sh` has 4 modes: `termux` (canary leak checks; run **only in Termux**), `inside`, `project` (config hygiene: secrets, `share`, pinned plugins, `{file:}` refs), `bench` (time/memory). Full behavioral tests live in `tests/MANUAL-TESTS.md`.

## cfg.cjs / opencode.json invariants (tested — don't break)

- `opencode.json` is parsed **tolerantly**: JSONC comments, trailing commas, and **multiple concatenated `{...}` root objects are merged**. Never assume strict-JSON semantics when reading or writing it.
- **`plugin` and `plugins` keys must always be kept identical** in the generated config (`syncPlugins()`); OpenCode 1 reads `plugin`, OpenCode 2 reads `plugins`.
- `setup-opencode.sh` must stay **idempotent**: re-running repairs `opencode.json` every time. `cfg base` uses `??=` so an existing `model` is never clobbered (except `--replace-default` swaps the `opencode/big-pickle` fallback); `cfg security secure` uses `??=` so user permission rules win; `cfg security unlock` overwrites.
- **API keys must never appear literally in `opencode.json`** — MCP headers use `{env:VAR}`/`--bearer-env`/`--header` so the value lands at runtime, not in a committable file. `project` mode greps for leaks and tests assert this.
- The doctor (`DOCTOR_ONLY=1 bash setup-opencode.sh`) strips `SKILL.md` entries from `instructions` (token bloat), keeps `https://` entries, rewrites `{file:}` refs to an existing path, and **exits 3 on unresolved refs**.
- `templates/security-profile.json` is an auditable mirror of `SECURE_PERMISSION` in `setup-opencode.sh` — keep the two in sync when changing permission rules.

## Efficiency invariants (tested — don't undo)

- **Generated, not tracked:** `opencode.json`, `.opencode/`, `graphify-out/`, and `.planning/graphs/` are gitignored (enforced by `update_gitignore`). Change `setup-opencode.sh`; never hand-edit those artifacts.
- **PATH persistence:** `persist_path` appends `~/.opencode/bin`, `~/.local/bin`, `~/.npm-global/bin` to `~/.bashrc` + `~/.profile` (idempotent). Tested by extracting the function and running it twice against a temp `HOME`.
- **Instruction diet:** `.opencode/instructions/INSTRUCTIONS.md` is repo-owned, deliberately ~45 lines (ECC's generic 343-line doc is replaced by `write_repo_instructions`). Loaded every turn and every subagent — keep it under ~90 lines; the test enforces the cap.
- **Env doctor:** `write_env_doctor` ships `.opencode/plugins/env-doctor.js`, which prepends a `command -v node opencode graphify` probe to the first shell command of a session and prints only missing tools. Turns the PATH-bug class into one visible line.
- **MCP policy:** only `context7` (library docs) + `parallel-search` (web). Tavily/Exa were retired as duplicates; `cfg mcp-rm` prunes them on every run so existing configs migrate, not just fresh installs.
- **Bug → test ratchet:** any bug that costs a debugging session gets a check in `tests/run-tests.sh` (see the persist_path and env-doctor checks).

## Conventions that differ from defaults

- `graphify install` **must never be run bare** (it targets Claude); always `graphify install --platform opencode`, then `graphify opencode install`.
- Model IDs use the `opencode-go/<model>` form; without Go auth the fallback is `opencode/big-pickle`. `OPENCODE_MODEL` always overrides detection; `GO_MODEL`/`GO_SMALL_MODEL` only apply when Go auth is detected.
- Secure posture is deliberate: `share: disabled`, `autoupdate: false`, `server.mdns: false`, deny list for destructive bash. Don't relax it in defaults; `UNLOCK=1` is the opt-in.
- The proot container is the real security boundary; deny rules are a seatbelt. Never add `--termux-home` binds to logins.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

When the user types `/graphify`, use the installed graphify skill or instructions before doing anything else.

Rules:
- When graphify-out/graph.json exists, run `graphify query "<question>"` before your first grep, search or source-file read for a codebase question, and put this rule in every subagent prompt that explores code. Read raw files only for lines the graph or an earlier read already located. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- Dirty graphify-out/ files are expected after hooks or incremental updates; dirty graph files are not a reason to skip graphify. Only skip graphify if the task is about stale or incorrect graph output, or the user explicitly says not to use it.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
- This repo gitignores `graphify-out/`, so graph output never appears in a PR diff here. In a repo that does commit `graph.json`, expect a whole-file diff on every build; don't flag it as churn or suggest skipping the rebuild.
