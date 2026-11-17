# AGENTS.md — opencode-android

Scripts-only repo: Bash + one Node script (`cfg.cjs`) embedded in a Bash heredoc in `setup-opencode.sh`. No manifests, linters, or CI. **Full invariants and design history: `docs/MAINTAINING.md` — read before changing setup logic.**

## Verify before claiming done
`bash -n <script>.sh`; `bash tests/run-tests.sh` → final line `PASS=<n> FAIL=0`; `DOCTOR_ONLY=1 bash setup-opencode.sh` when config generation changed. Bugs that cost a debugging session get a regression test.

## Hard rules
- No secrets in code or `opencode.json` — env vars / `{env:VAR}` / `--bearer-env`, resolved at runtime.
- `opencode.json`, `.opencode/`, `graphify-out/`, `.planning/graphs/` are generated and gitignored: edit the generator, never the artifact.
- Setup stays idempotent: re-runs repair config, never clobber user model/permission choices (`cfg` uses `??=`).
- Secure defaults are deliberate (share off, autoupdate off, mdns off, destructive bash denied); `UNLOCK=1` is the only opt-in. Never add `--termux-home` binds — proot is the security boundary.
- Read `opencode.json` tolerantly (JSONC, trailing commas, merged roots); keep `plugin` == `plugins` (`syncPlugins()`).

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

When the user types `/graphify`, use the installed graphify skill or instructions before doing anything else.

Rules:
- When graphify-out/graph.json exists, run `graphify query "<question>"` before your first grep, search or source-file read for a codebase question, and put this rule in every subagent prompt that explores code. Read raw files only for lines the graph or an earlier read already located. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- Dirty graphify-out/ files are expected after hooks or incremental updates; dirty graph files are not a reason to skip graphify. Only skip graphify if the task is about stale or incorrect graph output, or the user explicitly says not to use it.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
- A committed graphify-out/graph.json is rewritten whole on every build, so a large diff to it in a pull request is expected. Do not flag it as churn or suggest skipping the graph rebuild or its hooks.

## Project notes (fill me in)
<!-- Setup left this placeholder: write anything an agent should know about
     THIS project — stack, build/test commands, key paths, conventions,
     what "done" means, and what must never be touched. -->
- Stack / runtime:
- Build / test commands:
- Key entry points and paths:
- Conventions and hard limits:
