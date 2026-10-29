#!/usr/bin/env bash
# Functional battery for the embedded cfg.cjs inside ../setup-opencode.sh.
# Run from anywhere:  bash tests/run-tests.sh      (0 = all pass)
set -u
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# extract cfg.cjs from the setup script and syntax-check it
awk '/cat > "\$CFG" <<'"'"'JS'"'"'/{f=1;next} f&&/^JS$/{exit} f{print}' \
  "$REPO_DIR/setup-opencode.sh" > "$WORK/cfg.cjs"
node --check "$WORK/cfg.cjs" || { echo "FAIL: cfg.cjs does not parse"; exit 1; }

PASS=0; FAIL=0
chk() { # chk "name" expected actual
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1  (want [$2] got [$3])"; fi
}

mkdir -p "$WORK/projects"
cd "$WORK/projects" || exit 1
cfg() { node "$WORK/cfg.cjs" "$@"; }
grepchk() { # grepchk name pattern file
  if grep -q "$2" "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 ($2 not in $3)"; fi
}
nogrepchk() {
  if grep -q "$2" "$3"; then FAIL=$((FAIL+1)); echo "FAIL(negative): $1 ($2 in $3)"; else PASS=$((PASS+1)); fi
}

# 1. base on missing config
cfg base opencode/big-pickle >/dev/null && grepchk "base/model" '"model": "opencode/big-pickle"' opencode.json
grepchk "base/small" '"small_model": "opencode/big-pickle"' opencode.json && grepchk "base/schema" 'opencode.ai/config.json' opencode.json

# 2. base again does not clobber
node -e "const fs=require('fs');fs.writeFileSync('opencode.json',JSON.stringify({model:'opencode-go/kimi-k3'}))" 
cfg base opencode/big-pickle >/dev/null
chk "base-noclobber/model" "opencode-go/kimi-k3" "$(node -pe 'JSON.parse(require("fs").readFileSync("opencode.json","utf8")).model')"

# 3. jqc-style JSONC comments + trailing commas parse
printf '%s\n' '{ // comment
  "share": "ask", /* block */
  "plugin": ["x",],
}' > opencode.json
cfg base opencode/big-pickle >/dev/null && grepchk "jsonc-parse" '"share": "ask"' opencode.json

# 4. appended multi-object merge
printf '{ "autoupdate": false }\n{ "share": "disabled" }\n' >> opencode.json
rm -f opencode.json
printf '{ "autoupdate": false }\n' > opencode.json
printf '{ "share": "disabled" }\n' >> opencode.json
cfg security secure >/dev/null
chk "multiroot-merge/autoupdate" "false" "$(node -pe 'JSON.parse(require("fs").readFileSync("opencode.json","utf8")).autoupdate')"
chk "multiroot-merge/share" "disabled" "$(node -pe 'JSON.parse(require("fs").readFileSync("opencode.json","utf8")).share')"

# 5. security secure profile
rm -f opencode.json
SEC_PROFILE=$(cfg security secure)
chk "security-secure/profile" "profile=secure" "$SEC_PROFILE"
D=$(node -pe 'JSON.parse(require("fs").readFileSync("opencode.json","utf8")).permission.bash["rm -rf /*"]')
chk "secure-deny/rm-rf-root" "deny" "$D"
D=$(node -pe 'JSON.parse(require("fs").readFileSync("opencode.json","utf8")).permission.external_directory["*"]')
chk "secure/external-ask" "ask" "$D"

# 6. security secure does not clobber user's permission
node -e 'const fs=require("fs");const c=JSON.parse(fs.readFileSync("opencode.json","utf8"));c.permission.bash["git push *"]="ask";fs.writeFileSync("opencode.json",JSON.stringify(c))'
cfg security secure >/dev/null
chk "secure-keeps-user-rules/custom-rule" "ask" "$(node -pe 'JSON.parse(require("fs").readFileSync("opencode.json","utf8")).permission.bash["git push *"]')"
chk "secure-still-labeled" "profile=secure" "$(cfg security keep)"

# 7. unlock forces overwrite
UNLOCK_PROFILE=$(cfg security unlock)
chk "unlock/profile" "profile=unlocked" "$UNLOCK_PROFILE"
chk "unlock-bash-allow" "allow" "$(node -pe 'JSON.parse(require("fs").readFileSync("opencode.json","utf8")).permission.bash["*"]')"

# restore secure
cfg security secure >/dev/null

# 8. mcp: header injection with env set
PARALLEL_KEY=pk-secret cfg mcp parallel-search "https://search.parallel.ai/mcp" --bearer-env PARALLEL_KEY >/dev/null
chk "mcp-parallel/bearer" "Bearer pk-secret" "$(node -pe 'JSON.parse(require("fs").readFileSync("opencode.json","utf8")).mcp["parallel-search"].headers.Authorization')"
CTX_KEY=ctx-key cfg mcp context7 "https://mcp.context7.com/mcp" --header x-api-key CTX_KEY >/dev/null
chk "mcp-context7/header" "ctx-key" "$(node -pe 'JSON.parse(require("fs").readFileSync("opencode.json","utf8")).mcp.context7.headers["x-api-key"]')"
chk "mcp-context7/url" "https://mcp.context7.com/mcp" "$(node -pe 'JSON.parse(require("fs").readFileSync("opencode.json","utf8")).mcp.context7.url')"
cfg mcp-rm context7 >/dev/null   # test 9 re-adds it fresh (no headers)

# 9. no env -> no headers (fresh server), exists-check idempotent
cfg mcp context7 "https://mcp.context7.com/mcp" >/dev/null
POST_COUNT=$(grep -c '"context7"' opencode.json || true)
chk "mcp-idempotent" "1" "$POST_COUNT"
NODE_MCP=$(node -e 'const c=JSON.parse(require("fs").readFileSync("opencode.json","utf8"));console.log(c.mcp&&c.mcp.context7&&c.mcp.context7.headers?"bad":"ok")')
chk "mcp-fresh/no-headers" "ok" "$NODE_MCP"

# 10. plugin add syncs both keys
cfg plugin add "@tarquinen/opencode-dcp" >/dev/null
P=$(node -pe 'const c=JSON.parse(require("fs").readFileSync("opencode.json","utf8"));JSON.stringify(c.plugin)===JSON.stringify(c.plugins)?"yes":"mismatch"')
chk "plugin-sync/arrays-equal" "yes" "$P"

# 11. instruction add dedupe
cfg instruction --add AGENTS.md >/dev/null
cfg instruction --add AGENTS.md >/dev/null
N=$(node -pe 'JSON.parse(require("fs").readFileSync("opencode.json","utf8")).instructions.filter(x=>x==="AGENTS.md").length')
chk "instruction-dedupe" "1" "$N"
# https instructions survive strip; SKILL.md + missing files dropped
cfg instruction --add "https://raw.githubusercontent.com/JRedeker/opencode-shell-strategy/trunk/shell_strategy.md" >/dev/null
cfg instruction --add ".opencode/skills/tdd-workflow/SKILL.md" >/dev/null
cfg instruction --add "nonexistent-file.md" >/dev/null
cfg instruction --strip-skill-md >/dev/null 2>&1
HTTPS_KEPT=$(node -pe 'const i=JSON.parse(require("fs").readFileSync("opencode.json","utf8")).instructions;i.some(x=>x.startsWith("https://"))?"kept":"dropped"')
chk "strip/https-kept" "kept" "$HTTPS_KEPT"
SKILL_STRIPPED=$(node -pe 'const i=JSON.parse(require("fs").readFileSync("opencode.json","utf8")).instructions;String(!i.some(x=>/SKILL\.md/.test(x)))')
chk "strip/skillmd-removed" "true" "$SKILL_STRIPPED"
MISSING_STRIPPED=$(node -pe 'const i=JSON.parse(require("fs").readFileSync("opencode.json","utf8")).instructions;String(!i.includes("nonexistent-file.md"))')
chk "strip/missing-removed" "true" "$MISSING_STRIPPED"

# 12. doctor: {file:} ref fixing + missing refs exit 3
mkdir -p .opencode/prompts/agents; printf 'x' > .opencode/prompts/agents/planner.txt
node -e 'const fs=require("fs");fs.writeFileSync("opencode.json",JSON.stringify({agent:{planner:{prompt:"{file:.opencode/prompts/agents/planner.txt}"}}},{indent:2}))'
cfg doctor >/dev/null
grepchk "doctor/ref-fixed" '{file:.opencode/prompts/agents/planner.txt}' opencode.json
# also root-relative ref gets rewritten to .opencode/ when found there
node -e 'const fs=require("fs");fs.writeFileSync("opencode.json",JSON.stringify({agent:{planner:{prompt:"{file:prompts/agents/planner.txt}"}}}))'
cfg doctor >/dev/null
grepchk "doctor/ref-rel" '{file:.opencode/prompts/agents/planner.txt}' opencode.json
node -e 'const fs=require("fs");fs.writeFileSync("opencode.json",JSON.stringify({agent:{planner:{prompt:"{file:does/not/exist.txt}"}}}))'
cfg doctor >/dev/null 2>&1
RC=$?
chk "doctor/missing-exit3" "3" "$RC"

# 13. doctor keeps https instruction, strips SKILL.md, summary labels
node -e 'const fs=require("fs");fs.writeFileSync("opencode.json",JSON.stringify({instructions:["https://example.com/x.md",".opencode/skills/tdd-workflow/SKILL.md"]}))'
SUMMARY=$(cfg doctor)
chk "doctor/https-kept" "kept" "$(grep -q "https://example.com/x.md" opencode.json && echo kept || echo dropped)"
M=$(echo "$SUMMARY" | grep -c "model=" || true)
S=$(echo "$SUMMARY" | grep -c "security=" || true)
if [ "$M" -ge 1 ] && [ "$S" -ge 1 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: doctor summary prints model/security"; fi

# 14. mcp-rm prunes a retired server (migration for existing installs)
cfg mcp exa "https://mcp.exa.ai/mcp" >/dev/null
cfg mcp-rm exa >/dev/null
chk "mcp-rm/exa-removed" "true" "$(node -pe 'const c=JSON.parse(require("fs").readFileSync("opencode.json","utf8"));String(!c.mcp||!c.mcp.exa)')"

# 15. persist_path: extracted from setup, run twice against a temp HOME
awk '/^persist_path\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$REPO_DIR/setup-opencode.sh" > "$WORK/persist_path.sh"
mkdir -p "$WORK/home"
HOME="$WORK/home" bash -c '. "$1"; persist_path; persist_path' _ "$WORK/persist_path.sh"
chk "persist-path/bashrc" "1" "$(grep -cF '# opencode-android tool PATH' "$WORK/home/.bashrc")"
chk "persist-path/profile" "1" "$(grep -cF '# opencode-android tool PATH' "$WORK/home/.profile")"
chk "persist-path/export-line" "1" "$(grep -cF 'export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"' "$WORK/home/.bashrc")"

# 16. env-doctor plugin: ships, parses, registered, probe has no substitution
# .mjs: the plugin uses ESM syntax; under Node 20 (the version bootstrap.sh
# installs) a .js file in a bare temp dir is parsed as CommonJS and fails.
awk '/cat > \.opencode\/plugins\/env-doctor\.js <<.*JS/{f=1;next} f&&/^JS$/{exit} f{print}' \
  "$REPO_DIR/setup-opencode.sh" > "$WORK/env-doctor.mjs"
node --check "$WORK/env-doctor.mjs" || { FAIL=$((FAIL+1)); echo "FAIL: env-doctor.js does not parse"; }
grepchk "env-doctor/registered" 'cfg plugin add "\.opencode/plugins/env-doctor\.js"' "$REPO_DIR/setup-opencode.sh"
grepchk "env-doctor/probe" '\[env-doctor\]' "$WORK/env-doctor.mjs"
awk '/^const REMINDER =/{f=1} f{print} f&&/;$/{exit}' "$WORK/env-doctor.mjs" > "$WORK/reminder.txt"
if grep -qE '\$\(|`' "$WORK/reminder.txt"; then FAIL=$((FAIL+1)); echo "FAIL: env-doctor probe contains \$( ) or backticks"; else PASS=$((PASS+1)); fi

# 16b. the hook must actually fire (otherwise the plugin is a silent no-op).
# It probes PATH regardless of graph existence; the only guard is once per
# session/directory plus wrong-tool silence.
mkdir -p "$WORK/proj"
HOOK="$(node --input-type=module -e '
  const mod = (await import(process.argv[1])).default;
  const hooks = await mod.server({ directory: process.argv[2] });
  const fire = (tool) => { const o = { args: { command: "echo hi" } }; return { o, p: hooks["tool.execute.before"]({ tool }, o) }; };
  const one = fire("bash"); await one.p;
  const two = fire("bash"); await two.p;
  const other = fire("read"); await other.p;
  const ok = one.o.args.command.startsWith("for c in node opencode graphify")
    && two.o.args.command === "echo hi"
    && other.o.args.command === "echo hi";
  console.log(ok ? "true" : "false");
' "file://$WORK/env-doctor.mjs" "$WORK/proj")"
chk "env-doctor/hook-fires" "true" "$HOOK"

# 17. repo instructions: shipped, short, registered (token-diet ratchet)
awk '/cat > \.opencode\/instructions\/INSTRUCTIONS\.md <<.*MD/{f=1;next} f&&/^MD$/{exit} f{print}' \
  "$REPO_DIR/setup-opencode.sh" > "$WORK/INSTRUCTIONS.md"
LINES=$(wc -l < "$WORK/INSTRUCTIONS.md")
if [ "$LINES" -le 90 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: INSTRUCTIONS.md is $LINES lines (max 90)"; fi
grepchk "instructions/verify-section" 'Verify before claiming done' "$WORK/INSTRUCTIONS.md"
grepchk "instructions/registered" 'cfg instruction --add \.opencode/instructions/INSTRUCTIONS\.md' "$REPO_DIR/setup-opencode.sh"

# 18. MCP policy: two servers only; retired ones pruned every run
grepchk "mcp-policy/context7" 'cfg mcp context7' "$REPO_DIR/setup-opencode.sh"
grepchk "mcp-policy/parallel" 'cfg mcp parallel-search' "$REPO_DIR/setup-opencode.sh"
nogrepchk "mcp-policy/tavily-retired" 'cfg mcp tavily' "$REPO_DIR/setup-opencode.sh"
nogrepchk "mcp-policy/exa-retired" 'cfg mcp exa' "$REPO_DIR/setup-opencode.sh"
grepchk "mcp-policy/prune-tavily" 'cfg mcp-rm tavily' "$REPO_DIR/setup-opencode.sh"
grepchk "mcp-policy/prune-exa" 'cfg mcp-rm exa' "$REPO_DIR/setup-opencode.sh"

# 19. gitignore generator: graph output stays untracked, idempotently
awk '/^update_gitignore\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$REPO_DIR/setup-opencode.sh" > "$WORK/gitignore.sh"
mkdir -p "$WORK/gi"
( cd "$WORK/gi" && bash -c '. "$1"; update_gitignore; update_gitignore' _ "$WORK/gitignore.sh" )
chk "gitignore/graphify-out" "1" "$(grep -cxF 'graphify-out/' "$WORK/gi/.gitignore")"
chk "gitignore/planning-graphs" "1" "$(grep -cxF '.planning/graphs/' "$WORK/gi/.gitignore")"

# 20. mcp-rm ignores inherited Object keys (no phantom removal)
chk "mcp-rm/prototype-noop" "" "$(cfg mcp-rm constructor 2>/dev/null)"
chk "mcp-rm/prototype-untouched" "true" "$(node -pe 'const c=JSON.parse(require("fs").readFileSync("opencode.json","utf8"));String(!c.mcp||!Object.hasOwn(c.mcp,"constructor"))')"

# 22. default models: Go auth -> opencode-go/glm-5.3-flash for main and small,
# still overridable via GO_MODEL / GO_SMALL_MODEL.
awk '/^detect_go_auth\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$REPO_DIR/setup-opencode.sh" > "$WORK/models.sh"
awk '/^write_base_config\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$REPO_DIR/setup-opencode.sh" >> "$WORK/models.sh"
mkdir -p "$WORK/mhome/.local/share/opencode"
printf '{"opencode-go":{"type":"api","key":"dummy"}}' > "$WORK/mhome/.local/share/opencode/auth.json"
model_out() {
  HOME="$WORK/mhome" "$@" bash -c '. "$1"; cfg(){ printf "%s\n" "$@"; }; log(){ :; }; need(){ return 1; }; write_base_config' _ "$WORK/models.sh"
}
DEFAULT_OUT=$(model_out)
chk "model/go-default" "2" "$(printf '%s\n' "$DEFAULT_OUT" | grep -cxF 'opencode-go/glm-5.3-flash')"
OVERRIDE_OUT=$(model_out env GO_MODEL=grok-4.7 GO_SMALL_MODEL=mini)
chk "model/go-override-main" "opencode-go/grok-4.7" "$(printf '%s\n' "$OVERRIDE_OUT" | sed -n '2p')"
chk "model/go-override-small" "opencode-go/mini" "$(printf '%s\n' "$OVERRIDE_OUT" | sed -n '3p')"

# 23. per-agent models: plan/build defaults, wired after ECC, never clobbered.
grepchk "agent-models/wired-plan" 'cfg agent-model plan' "$REPO_DIR/setup-opencode.sh"
grepchk "agent-models/wired-build" 'cfg agent-model build' "$REPO_DIR/setup-opencode.sh"
awk '/^detect_go_auth\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$REPO_DIR/setup-opencode.sh" > "$WORK/agents.sh"
awk '/^write_agent_models\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$REPO_DIR/setup-opencode.sh" >> "$WORK/agents.sh"
AGENT_OUT=$(HOME="$WORK/mhome" bash -c '. "$1"; cfg(){ echo "$*"; }; write_agent_models' _ "$WORK/agents.sh")
chk "agent-models/go-plan" "agent-model plan opencode-go/glm-5.3" "$(printf '%s\n' "$AGENT_OUT" | sed -n '1p')"
chk "agent-models/go-build" "agent-model build opencode-go/glm-5.3-flash" "$(printf '%s\n' "$AGENT_OUT" | sed -n '2p')"
cfg agent-model plan custom/keep-me >/dev/null
cfg agent-model plan opencode-go/glm-5.3 >/dev/null
chk "agent-models/no-clobber" "custom/keep-me" "$(node -pe 'JSON.parse(require("fs").readFileSync("opencode.json","utf8")).agent.plan.model')"

# 24. bootstrap: "already installed?" must see BOTH proot-distro layouts.
# The 2026 Python rewrite moved containers from installed-rootfs/<alias> to
# containers/<name>/rootfs; checking one path made `install` fail with
# "container 'X' already exists" on setups holding the other layout.
awk '/^container_installed\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' \
  "$REPO_DIR/bootstrap.sh" > "$WORK/pd.sh"
mkdir -p "$WORK/pd/installed-rootfs/ubuntu"
chk "pd/legacy-layout" "0" "$(DISTRO=ubuntu PD_ROOT="$WORK/pd" bash -c '. "$1"; container_installed' _ "$WORK/pd.sh" >/dev/null 2>&1; echo $?)"
rm -rf "$WORK/pd"; mkdir -p "$WORK/pd/containers/ubuntu/rootfs"
chk "pd/new-layout" "0" "$(DISTRO=ubuntu PD_ROOT="$WORK/pd" bash -c '. "$1"; container_installed' _ "$WORK/pd.sh" >/dev/null 2>&1; echo $?)"
rm -rf "$WORK/pd"
mkdir -p "$WORK/nopath"  # stub shadows any real proot-distro: name never matches
printf '#!/bin/sh\necho definitely-not-ubuntu\n' > "$WORK/nopath/proot-distro"
chmod +x "$WORK/nopath/proot-distro"
chk "pd/absent" "1" "$(DISTRO=ubuntu PD_ROOT="$WORK/pd" PATH="$WORK/nopath:$PATH" bash -c '. "$1"; container_installed' _ "$WORK/pd.sh" >/dev/null 2>&1; echo $?)"
rm -rf "$WORK/pd"
mkdir -p "$WORK/pdbin"
printf '#!/bin/sh\necho alpine\necho ubuntu\n' > "$WORK/pdbin/proot-distro"
chmod +x "$WORK/pdbin/proot-distro"
chk "pd/list-fallback" "0" "$(DISTRO=ubuntu PD_ROOT="$WORK/pd" PATH="$WORK/pdbin:$PATH" bash -c '. "$1"; container_installed' _ "$WORK/pd.sh" >/dev/null 2>&1; echo $?)"

# 25. config backup is rolling: a run keeps only the newest opencode.json.bak.*
# (previously every install/re-run stamped a new backup forever).
awk '/^backup_config\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' \
  "$REPO_DIR/setup-opencode.sh" > "$WORK/backup.sh"
mkdir -p "$WORK/bk"
BKOUT="$( cd "$WORK/bk" && echo '{}' > opencode.json \
    && touch opencode.json.bak.00000101000000 opencode.json.bak.00000101000001 \
    && log() { :; } && . "$WORK/backup.sh" && backup_config >/dev/null \
    && printf '%s\n' opencode.json.bak.* )"
chk "bkprune/keep-one" "1" "$(printf '%s\n' "$BKOUT" | grep -c .)"
chk "bkprune/seed-gone" "0" "$(printf '%s' "$BKOUT" | grep -c '00000101')"

# 21. README test-count ratchet: the badge and the repo-layout line must match
# the real suite size, so docs cannot drift stale again (they said "29 checks"
# long after the suite passed that). EXPECTED includes these two checks.
EXPECTED=$((PASS+2))
chk "readme/badge-count" "$EXPECTED" "$(sed -n 's|.*badge/tests-\([0-9]*\)%20checks.*|\1|p' "$REPO_DIR/README.md")"
chk "readme/layout-count" "$EXPECTED" "$(sed -n 's|.*Automated test battery (\([0-9]*\) checks).*|\1|p' "$REPO_DIR/README.md")"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
