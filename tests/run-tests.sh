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

PASS=PASS=0; FAIL=0
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
TAVILY_API_KEY=tv-secret cfg mcp tavily "https://mcp.tavily.com/mcp/" --bearer-env TAVILY_API_KEY >/dev/null
chk "mcp-tavily/bearer" "Bearer tv-secret" "$(node -pe 'JSON.parse(require("fs").readFileSync("opencode.json","utf8")).mcp.tavily.headers.Authorization')"
EXA_API_KEY=ex-key cfg mcp exa "https://mcp.exa.ai/mcp" --header x-api-key EXA_API_KEY >/dev/null
chk "mcp-exa/header" "ex-key" "$(node -pe 'JSON.parse(require("fs").readFileSync("opencode.json","utf8")).mcp.exa.headers["x-api-key"]')"
chk "mcp-exa/url" "https://mcp.exa.ai/mcp" "$(node -pe 'JSON.parse(require("fs").readFileSync("opencode.json","utf8")).mcp.exa.url')"

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

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
