---
title: opencode-android audit and fix handover
date: 2026-11-16
repo: Inigo-Antony/opencode-android
branch: feature/ensemble
commit: c157f79
audience: OpenCode agent (fixer)
status: audit complete, no code changed
tags: [audit, opencode, termux, token-discipline, handover]
---

# opencode-android: audit and fix handover

> [!abstract] Scope
> Audit of `feature/ensemble` @ `c157f79` on four axes: **utility**, **efficiency**, **performance**, **token discipline**. Read-only. Nothing was changed, committed or installed. Baseline: `bash tests/run-tests.sh` gives `PASS=85 FAIL=0` in about 1.9 s, and `bash -n` is clean on all four shell files.

## 0. Kickoff prompt (paste into OpenCode)

```text
Read docs/AUDIT-2026-11-16.md fully. Work through §5 in order, one commit per batch.
For each finding: write the failing check first (section "Verify"), then the minimal fix.
Obey §1 constraints. Run `bash -n` on every edited .sh and `bash tests/run-tests.sh` after
every batch. Stop and ask before touching anything in §7 "Owner decisions".
```

## 1. Constraints (do not break)

These come from the repo's own `AGENTS.md` and `tests/run-tests.sh`. Violating them fails the suite or silently tests stale code.

- `opencode.json`, `.opencode/`, `graphify-out/` are **generated and gitignored**. Change `setup-opencode.sh`, never the artifact.
- Edits to the embedded Node script must stay between `cat > "$CFG" <<'JS'` and the line `JS`. The tests extract it with awk.
- Setup stays **idempotent**. Keep `??=` semantics so user model and permission choices are never clobbered.
- `plugin` and `plugins` stay identical (`syncPlugins()`).
- No secrets in `opencode.json`. Secure defaults stay (`share: disabled`, `autoupdate: false`, `mdns: false`). Never add `--termux-home`.
- Test hooks to respect:
  - `run-tests.sh:179-184` extracts the **first** heredoc that writes `.opencode/instructions/INSTRUCTIONS.md`, ending at the first line `MD`. It asserts at most 90 lines, the text `Verify before claiming done`, and that `cfg instruction --add .opencode/instructions/INSTRUCTIONS.md` exists in the script.
  - `run-tests.sh:253-261` (test 25) asserts rolling `opencode.json.bak.*` keeps only the newest.
  - `run-tests.sh:57,67` assert `profile=secure` on a fresh config.
  - `run-tests.sh:220-230` cover per-agent models.
  - `run-tests.sh:310-324` cover the AGENTS.md notes placeholder.
- The test count appears in three places. Update all three when it changes: `README.md:13` badge, `README.md:145`, `AGENTS.md:14`.

## 2. Scorecard (auditor's judgment, not a measured benchmark)

| Axis | Score | Summary |
|---|---|---|
| Utility | 6/10 | 14 of 26 subagents do not match the owner's stack. One file is misapplied to every project. |
| Efficiency | 7/10 | Idempotent and well tested. Re-runs are heavy and the backup logic is lossy. |
| Performance | 7/10 | Installer logic is fast. Cost is network clones and process spawns. Runtime on-device speed was **not measured**. |
| Token discipline | 5/10 | Good levers (dcp, 11 core skills, 2 MCPs, per-agent models), undermined by about 3.5k tokens of always-on context and mutable remote instructions. |

## 3. Findings index

| ID | Sev | Area | One line |
|---|---|---|---|
| F1 | P0 | bootstrap | README one-liner clones the `YOUR-USER` placeholder repo |
| F2 | P0 | utility, tokens | Repo-specific `INSTRUCTIONS.md` is written into every project |
| F3 | P0 | efficiency | Rolling backup destroys the user's original config |
| F4 | P0 | security | Doctor reports `profile=secure` when the bash deny-list is gone |
| F5 | P1 | tokens | 26 subagents and 26 commands always loaded, most off-stack |
| F6 | P1 | tokens | AGENTS.md is maintainer docs loaded every turn, and the "template" is a copy |
| F7 | P1 | supply chain | 7 unpinned sources, including a mutable remote instruction URL |
| F8 | P1 | performance | Every re-run re-clones ECC and runs `npx ...@latest` |
| F9 | P2 | performance | Ensemble is default-on on a RAM-limited phone (owner decision) |
| F10 | P3 | performance | `detect_go_auth` can spawn `opencode` up to 3 times per run |
| F11 | P3 | performance | About 17 `node` spawns per run (measure first) |
| F12 | P3 | docs | `SECURITY.md` references a "web-deny" rule that does not exist |

## 4. Findings in detail

### F1 [P0] Bootstrap clones a placeholder repo

- **Evidence:** `bootstrap.sh:21` is `REPO_URL="${OC_ANDROID_REPO:-https://github.com/YOUR-USER/opencode-android}"`. Under `curl ... | bash`, `BASH_SOURCE[0]` is empty, so `SCRIPT_DIR` resolves to the **current directory**. There is no `setup-opencode.sh` next to it, so the script takes the clone branch (`bootstrap.sh:83-85`, `97-102`) and clones `YOUR-USER`. Simulated the `SCRIPT_DIR` resolution under a piped run. I did **not** run a real install.
- **Impact:** the README install one-liner (`README.md:33`) fails unless `OC_ANDROID_REPO` is set by hand.
- **Fix:**
  1. Default `REPO_URL` to `https://github.com/Inigo-Antony/opencode-android`.
  2. Fix the header comments at lines 7-12.
  3. If `${BASH_SOURCE[0]:-}` is empty, set `SCRIPT_DIR=""` so piped runs never mistake the cwd for the repo.
- **Verify:**
  - Add a test: `grep -v '^[[:space:]]*#' bootstrap.sh | grep -c YOUR-USER` must be `0`.
  - Run bootstrap with stubbed `proot-distro` and `pkg` on `PATH`, piped from another cwd, and confirm the clone URL contains `Inigo-Antony`.
- **Note:** the one-liner fetches `HEAD`, so it ignores this branch until merged. Use `OC_ANDROID_BRANCH=feature/ensemble` to test (see §7).

### F2 [P0] Repo-specific instructions leak into every project

- **Evidence:** `write_repo_instructions` (`setup-opencode.sh:461-511`) writes a fixed heredoc unconditionally. It says "Bash-only: bootstrap.sh and setup-opencode.sh... No package manifests", and tells the agent to run `tests/run-tests.sh`. In any other repo that text is wrong. It loads on every turn and into every subagent.
- **Fix:**
  - Branch on `[ -f "$ROOT/setup-opencode.sh" ] && [ -f "$ROOT/bootstrap.sh" ]`.
  - Keep the current text for this repo. Otherwise write a **generic** 20-25 line version covering verify-before-done, secrets, token hygiene, git, and agent usage, with no mention of this repo's files.
  - Keep the repo-specific heredoc **first** with terminator `MD`. Give the generic one a different terminator (for example `GEN`) so the test extractor still sees the first block.
  - The file is rewritten on every run, so re-running setup heals projects that already got the wrong text.
- **Verify:**
  - A new test runs the function against a temp dir without those two files and asserts the output does not contain `bootstrap.sh`, is at most 90 lines, and contains `Verify before claiming done`.
  - The existing checks at lines 179-184 still pass.

### F3 [P0] Rolling backup loses the original

- **Evidence:** `backup_config` (`setup-opencode.sh:371-380`) copies the current config, then deletes every older backup (`ls -1t ... | tail -n +2`). Reproduced: after two runs the only backup held the post-run-1 state, and the original hand-edit was gone.
- **Fix:**
  - In `backup_config`, add `[ -f opencode.json.orig ] || cp -p opencode.json opencode.json.orig`. Keep the rolling logic as is.
  - Add `opencode.json.orig` to `update_gitignore` (`setup-opencode.sh:720`) and to `.gitignore`.
  - Update the README sentence about rolling backups.
- **Verify:**
  - Extend test 25: two consecutive runs leave one `bak.*` and `.orig` equal to the **first** config.
  - `.orig` must not match the `opencode.json.bak.*` glob, so the existing assertion still holds.

### F4 [P0] Doctor misreports the security profile

- **Evidence:** the profile label compares only `permission.external_directory` (`setup-opencode.sh:304` and `359`, inside the Node block). With the bash deny-list removed (`bash: {"*":"allow"}`) the tool printed `profile=secure`. Reproduced.
- **Fix:**
  - Add one helper, `profileOf(c)`, and use it at both sites.
  - It returns `secure` only if `c.permission` deep-equals `SECURE_PERMISSION`. Use a key-order-independent deep compare, not `JSON.stringify`. Return `unlocked` for `UNLOCKED_PERMISSION` and `custom` otherwise.
- **Verify:**
  - Keep tests 57 and 67 green.
  - Add a negative test: weakened bash block gives `profile=custom`.
  - Add a test: secure profile with an extra user deny rule gives `profile=custom`.

### F5 [P1] Subagent and command bloat

- **Evidence** (from `docs/opencode-json-template.txt`, a reference copy):
  - 28 agents (2 primary, 26 subagents) and 26 commands.
  - 15 subagents are language or stack specific: go, cpp, java, kotlin, php, ruby, rust, database, e2e, python. **14 do not match** the owner's Python, Bash and energy-systems stack. Keep `python-reviewer`.
  - Subagent names plus descriptions are about 3.5k characters, roughly **880 tokens** (chars/4 estimate) on every turn.
  - The live set comes from ECC upstream at install time (`cfg ecc`, `setup-opencode.sh:244`), so **count from a generated `opencode.json`, not the template**.
- **Fix:**
  - Add `ECC_AGENTS` (comma list, or `all`), filtered inside the `ecc` subcommand.
  - Default allowlist: `planner, architect, code-reviewer, security-reviewer, tdd-guide, build-error-resolver, python-reviewer, docs-lookup`, plus primary `build` and `plan`.
  - Also drop every `command` whose `agent` was filtered out, otherwise the doctor's `{file:}` and agent references dangle. For example `go-build`, `e2e` and `refactor-clean`.
  - Update `docs/opencode-json-template.txt` and the README tuning table.
- **Verify:**
  - A test feeds a fake ECC `opencode.json` through `cfg ecc` and asserts the filtered agent and command sets.
  - `DOCTOR_ONLY=1 bash setup-opencode.sh` exits 0, not 3.
  - Record the agent and command counts and description characters before and after.

### F6 [P1] AGENTS.md is maintainer documentation loaded every turn

- **Evidence:** `AGENTS.md` is 8,425 bytes (about 2.1k tokens). Most of it is `cfg.cjs` invariants, the obsidian path history and test internals. That is useful when editing this repo, but pure overhead as per-turn agent context. It has four **empty** placeholder bullets (lines 66-69). The graphify "query before grep" rule is duplicated in `INSTRUCTIONS.md`. `docs/agents-md-template.txt` is **byte-identical** to `AGENTS.md`, so it is not a reusable template.
- **Fix:**
  - Move the invariants, efficiency and conventions detail to `docs/MAINTAINING.md`. Leave `AGENTS.md` at 30 lines or fewer: a digest of the "must not break" list, the verify commands, and a pointer to `docs/MAINTAINING.md`.
  - Fill or delete the empty placeholder bullets in **this repo's** AGENTS.md. The placeholder generated for user projects is intentional and stays.
  - Make `docs/agents-md-template.txt` a generic master with placeholders and none of this repo's invariants.
  - Remove the duplicated graphify rule from one of the two files.
- **Caution:** the graphify section is tool-owned (`graphify opencode install`). After trimming, run setup twice and confirm it is neither duplicated nor re-bloated. If graphify is not installed in your environment, leave that block verbatim.
- **Verify:**
  - `wc -c AGENTS.md` is under about 3 KB.
  - `diff AGENTS.md docs/agents-md-template.txt` is non-empty.
  - `tests/run-tests.sh` is green.

### F7 [P1] Unpinned supply chain

Repo policy (`AGENTS.md`, "Ensemble plugin is pinned") says unpinned npm plugins are cached once and never update (opencode #6774). Only ensemble follows it.

| Item | Where | Current | Fix |
|---|---|---|---|
| GSD | `setup-opencode.sh:423,425` | `get-shit-done-cc@latest`, run every time | `GSD_VERSION` pinned default |
| graphify | `setup-opencode.sh:433-439` | `graphifyy`, no version | `graphifyy==X.Y.Z` |
| ECC | `setup-opencode.sh:49,520` | clone of HEAD | `ECC_REF` commit SHA, checked out |
| obsidian-skills | `setup-opencode.sh:673` | `main`, then `pull --ff-only` | `OBSIDIAN_SKILLS_REF` (see §7) |
| shell-strategy | `setup-opencode.sh:52` | raw URL on `trunk` | commit-SHA URL, or vendor the file |
| `@tarquinen/opencode-dcp` | `setup-opencode.sh:641` | unpinned | `@x.y.z` |
| `ecc-universal` | `setup-opencode.sh:241` (hardcoded) | unpinned | `@x.y.z` |

- **Highest risk:** the shell-strategy URL sits in `instructions`. It is fetched at runtime from a mutable third-party branch and injected into the system prompt of every session and subagent. Anyone who controls that branch controls the agent's instructions. Prefer **vendoring** it into `.opencode/instructions/` at a pinned SHA. That also removes a per-session network dependency on a flaky phone link. Its size was not measured because the fetch was blocked in the audit sandbox. Fetch it on the device and count.
- Resolve current versions with `npm view <pkg> version` and `pip index versions graphifyy` (or `uv`). Do not guess.
- Update `docs/opencode-json-template.txt` (lines 32-37 and 39-44), the README, and check what `tests/verify-sandbox.sh project` asserts about pinned plugins before changing it.
- **Verify:** `grep -nE '@latest|/trunk/' setup-opencode.sh docs/opencode-json-template.txt` returns nothing. Add that as a test.

### F8 [P1] Re-runs are expensive

- **Evidence:** `install_ecc` does `rm -rf` plus a fresh `git clone` every run (`setup-opencode.sh:519-520`), and `install_gsd` runs `npx --yes ...@latest` every run. Multiply by every project on the phone.
- **Fix:** cache the ECC clone at `~/.cache/opencode-android/ecc-<ref>` and reuse it. Add `ECC_REFRESH=1` to force a re-clone. With pinned versions (F7) `npx` caches too. Keep the doctor's retry path (`install_ecc` on exit 3) working.
- **Verify:** time two consecutive runs with `time`. The second should skip the clone. Add a test that the cache path is reused.

### F9 [P2] Ensemble default-on (owner decision)

`ENABLE_ENSEMBLE:-1` (`setup-opencode.sh:643`). `docs/ANDROID-TIPS.md` says RAM is the limit and each teammate is its own agent context in its own worktree. Recommendation: document the RAM and token multiplier next to the flag. Whether to flip the default is the owner's call (§7).

### F10 [P3] `detect_go_auth` repeated

Called at `setup-opencode.sh:408, 556, 563`. When `auth.json` has no Go entry it falls through to `opencode auth list`, a full process start each time. Memoize in a variable on first call. Unmeasured, so confirm with `bench` first.

### F11 [P3] Many `node` spawns

About 17 `cfg` invocations per run, each parsing and saving `opencode.json`. Measure with `tests/verify-sandbox.sh bench` before optimizing. Only batch if the cost is material. Every subcommand has tests, so keep them intact.

### F12 [P3] Docs inaccuracy

`docs/SECURITY.md:58` mentions "web-deny" among the layers. No such rule exists in the secure profile. Remove or reword it.

## 5. Execution order

1. **Batch A (P0 correctness):** F1, F2, F3, F4. Each gets its own test. Update the test count in three places.
2. **Batch B (token diet):** F5, F6. Record before and after numbers (§6).
3. **Batch C (supply chain and speed):** F7, F8.
4. **Batch D (low priority):** F10, F11, F12, and the docs half of F9.

One commit per batch. Conventional messages (`fix:`, `perf:`, `docs:`). Commit only when asked.

## 6. Baseline for before and after

Estimator: characters divided by 4. Use a real tokenizer if one is available on the device.

| Metric | Before | Target |
|---|---|---|
| `AGENTS.md` | 8,425 B (about 2.1k tok) | under 3 KB |
| `INSTRUCTIONS.md` | 45 lines, 2,191 B (about 0.55k tok) | unchanged for this repo, generic elsewhere |
| Subagent name and description | about 3.5k chars (about 880 tok) | about 1.1k chars |
| Fixed always-on context (those three) | about 3.5k tok | about 1.5k tok |
| MCP tool schemas, shell-strategy doc | not measured | measure on device and record |
| Tests | 85 pass | all pass, plus new checks |

For on-device numbers, run `bash tests/verify-sandbox.sh bench` on a full install and on a baseline install, as that mode's own help text suggests.

## 7. Owner decisions and unverified items

> [!warning] Ask the owner before doing these
> - **Ensemble default** (F9): keep default-on, or make it opt-in.
> - **obsidian-skills pinning** (F7): the README says it deliberately tracks `main`. Confirm that stays.
> - **F1 branch behavior:** the one-liner installs the default branch. Decide whether to merge `feature/ensemble` first or document `OC_ANDROID_BRANCH`.
> - **ECC agent allowlist** (F5): confirm the default list, for example whether `doc-updater` and `refactor-cleaner` should stay.

> [!info] Not verified by the audit
> - `shellcheck` was not installed, so lint is unchecked.
> - `shell_strategy.md` size was not measured.
> - Whether OpenCode deduplicates `AGENTS.md` when it is also listed under `instructions` is unknown. If it does not, the file loads twice.
> - On-device runtime (RAM, start time, real token use) was not measured.
> - `tests/verify-sandbox.sh` was only skimmed, and `tests/MANUAL-TESTS.md` and `docs/VIBE-PROJECTS.md` were not reviewed.
> - Agent and command counts come from the reference template, not a freshly generated config.

## 8. Definition of done

- Every F1 to F8 fix has a test that fails before and passes after.
- `bash -n` is clean on all edited `.sh` files, and `bash tests/run-tests.sh` ends with `FAIL=0`.
- `DOCTOR_ONLY=1 bash setup-opencode.sh` exits 0 in a scratch git repo.
- Test counts in `README.md` and `AGENTS.md` match the suite.
- The §6 table is re-measured and pasted into the PR description.
