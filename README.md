# opencode-android

Run **OpenCode** (the open-source terminal AI coding agent) as a full power-user
station on your Android phone — **Termux + proot-distro** — with one command, and
with your main files locked away in a separate sandbox.

Designed for: OpenCode **Go** subscribers (auto-detected, model set for you) and
anyone else (falls back to the free Big Pickle model, no API key needed).

## What you get

| Component | What it does |
| --- | --- |
| **proot-distro Ubuntu** | A real Linux userland on your phone — the hard security boundary |
| **opencode** | The agent itself (linux-arm64 binary) |
| **Everything-Claude-Code (ECC)** | `ecc-universal` plugin + 25 review/build subagents + ~20 workflow commands; 11 core skills by default (`ECC_SKILLS=all` for all 300+) |
| **GSD (get-shit-done)** | Spec → plan → implement project workflow library |
| **graphify** | Local knowledge-graph of your codebase (`/graphify .`), queried before grepping — big token saver |
| **MCP: Context7** | Up-to-date library/API docs (no key) |
| **MCP: Parallel** | Deep web search / research (no key) |
| **MCP: Tavily** | Web search + extraction (keyless Search/Extract; add `TAVILY_API_KEY` in `.env` for more) |
| **MCP: Exa** | Web search (keyless; add `EXA_API_KEY` in `.env` for more) |
| **dcp** | Dynamic context pruning — prunes stale tool output (matters a lot on phones) |
| **shell-strategy** | Non-interactive shell rules — stops agents hanging on TTY prompts (common in proot) |
| **Secure-by-default config** | `share: disabled`, no auto-update, destructive bash denied, prompts before touching files outside the project |

Re-running the script is always safe and idempotent; it repairs a broken
`opencode.json` every time.

## Quickstart (one command)

1. Install [Termux from F-Droid](https://f-droid.org/en/packages/com.termux/)
   (**not** Play Store — it is outdated/unmaintained).

2. In Termux, run (replace `YOUR-USER` with this repo's owner):

   ```bash
   curl -fsSL https://raw.githubusercontent.com/YOUR-USER/opencode-android/main/bootstrap.sh | bash
   ```

   That installs proot-distro + Ubuntu, disables your Termux home from the
   container (that is your sandbox), installs Node + opencode + everything above,
   and prints next steps. ~1–2 GB storage / ~15 minutes on Wi-Fi.

3. Use it:

   ```bash
   proot-distro login ubuntu   # enter the sandbox
   mkdir -p ~/my-project && cd ~/my-project
   git init                    # setup must run inside a git repo
   bash /root/opencode-android/setup-opencode.sh   # per-project setup
   opencode                    # start the agent
   ```

4. One-time model setup inside opencode:
   - **OpenCode Go subscribers:** type `/connect`, pick **OpenCode Go**, paste
     your key from [opencode.ai/console](https://opencode.ai/console). Then
     re-run the setup script once inside this project — it detects your Go
     subscription and sets `model: opencode-go/kimi-k3` with a fast/cheap
     `small_model` (`opencode-go/glm-5.3-flash`). Change with:
     `GO_MODEL=kimi-k3.1-pro bash setup-opencode.sh`
   - **No subscription:** Big Pickle is already configured, free, no key.

## Manual install path (if the one-liner fails)

```bash
# Termux side
pkg update -y && pkg install proot-distro
proot-distro install ubuntu
proot-distro login ubuntu

# inside Ubuntu
apt update && apt install -y curl git python3-pip pipx
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt install -y nodejs
git clone https://github.com/YOUR-USER/opencode-android /root/opencode-android

cd /path/to/your/git/project
bash /root/opencode-android/setup-opencode.sh
```

## Tuning (environment variables)

| Variable | Default | Meaning |
| --- | --- | --- |
| `UNLOCK=1` | off | Allow-everything profile (no approval prompts) — power-user flow |
| `SECURITY_PROFILE=secure\|keep` | `secure` | `keep` leaves your permission settings untouched |
| `OPENCODE_MODEL` / `OPENCODE_SMALL_MODEL` | auto | Force models (e.g. `opencode-go/grok-4.7`) |
| `GO_MODEL` / `GO_SMALL_MODEL` | `kimi-k3` / `glm-5.3-flash` | Models used when a Go subscription is detected |
| `ECC_SKILLS` | `core` | `all` = every ECC skill, `none` = no skills |
| `ENABLE_CONTEXT7=0` etc. | on | Disable any of context7 / parallel / tavily / exa / dcp / shell-strategy |
| `SKIP_GSD=1`, `SKIP_GRAPHIFY=1`, `SKIP_ECC=1`, `SKIP_MCP=1`, `SKIP_EXTRAS=1`, `SKIP_OPENCODE=1` | off | Skip a component |
| `DOCTOR_ONLY=1` | off | Only repair + validate `opencode.json` |
| `TAVILY_API_KEY`, `EXA_API_KEY` | unset | Put in a git-ignored `.env` next to opencode.json; wired as MCP headers, never inlined into JSON |

## Verify your setup

After `opencode` launches:

- `/models` — model shows `opencode-go/…` (Go) or `opencode/big-pickle`
- `/gsd-help` — GSD answering
- `/graphify .` — builds `graphify-out/`, ask structural questions via `graphify query`
- `@code-reviewer` — ECC subagents available
- startup panel lists MCP servers **context7, parallel-search, tavily, exa**

## First-session checklist for a "power user"

- Tab — switch `build`/`plan` primary agents; `@planner` etc for subagents
- `/plan <feature>` → `/tdd` → `/code-review` → `/security` — ECC review flow
- `/gsd:plan <goal>` → GSD GSD wraps features with spec/plan/implement steps
- `/new` — fresh session; `/share` is disabled by design (privacy)

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Clones/installs silently fail | DNS inside proot: `echo 'nameserver 8.8.8.8' > /etc/resolv.conf` |
| `Node reports platform=android` | You are on the Termux Node; run everything inside the proot distro (script refuses by design) |
| Session killed with `signal 9` when you leave the app | Android 12+ phantom process killer: `termux-wake-lock`, keep Termux in foreground, use `tmux`? optional inside proot |
| `epoll`/`futex` failures under load | RAM limit: check `free -m`; avoid browser-heavy MCP/tooling (no Playwright E2E on small phones) |
| Config broke after manual edits | `DOCTOR_ONLY=1 bash setup-opencode.sh` (backups kept as `opencode.json.bak.*`) |
| GSD reports missing gsd-sdk | `npm install -g get-shit-done-cc@latest` |
| graphify installs into `~/.claude/` | You ran bare `graphify install`; fix: `graphify claude uninstall && graphify install --platform opencode` |

## Security in one paragraph

The **proot container is the real boundary**: opencode, the model's tool calls,
plugins and every subprocess run inside a Linux userland that cannot reach your
Android/Termux files (no root, no bind mounts of your home), and Termux/Android
files cannot reach into it either. On top of that the config denies
world-breaking commands (`rm -rf /`, `dd`, `mkfs…`) and asks before touching
paths outside the project directory, plus `share: disabled` (no prompt
sharing/upload), `autoupdate: false` (no surprise binaries) and API keys stay
in `.env` / opencode's own auth store — never in JSON you might commit.
Full threat model + honest limits: [docs/SECURITY.md](docs/SECURITY.md).

## Extras (optional, inside the container)

- **GitHub CLI** (`gh`): `apt install gh && gh auth login` — lets the agent open
  PRs/issues directly (`gh pr create`). Plain `git` already works without it.
- **GitButler**: not available on Android — skip; `git` + `gh` cover it.
- Heavy browser E2E / Docker stacks: run in cloud sandboxes or CI, not in proot
  (see `docs/VIBE-PROJECTS.md`).

## Repo layout

```
bootstrap.sh                 Termux side: proot-distro + Ubuntu + first-run setup
setup-opencode.sh            Container side: installs + configures everything, idempotent
templates/security-profile.json   Auditable copy of the default permission set
docs/SECURITY.md             Threat model, layers, limits
docs/ANDROID-TIPS.md         Phantom killer, RAM, background jobs, wakelock
docs/VIBE-PROJECTS.md        Where the "vibe-coded app safety tools" (pre-commit,
                             gitleaks, Playwright, Docker stacks...) actually live
```
