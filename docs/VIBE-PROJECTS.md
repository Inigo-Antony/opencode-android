# vibe-coded projects: which safety tools live where

A common question: "does opencode-android need a different setup for vibe
coding (fast AI-built apps)?" No — this repo is the **harness + sandbox**
(set up once, project-agnostic). The extra safety nets for fragile AI-built
apps are **per-project tools that the agent itself scaffolds** inside each new
repo. This page maps the classic checklist to where each piece belongs on a
phone.

## The "10 tools to make vibe-coded apps less fragile" checklist

| Tool | Where it lives on this setup |
| --- | --- |
| pre-commit hooks (lint/format at commit time) | per project — ask the agent: "set up pre-commit with lint + quick tests" |
| gitleaks (secret scanner) | per project + CI; also partly covered here (`.env` is git-ignored, keyless MCP URLs never inline tokens) |
| linter / formatter (Biome/ESLint) | per project — agent scaffolds; always-on at CI |
| type checker (tsc strict etc.) | per project — agent scaffolds |
| unit tests (Vitest/Jest) | per project — ECC's `/tdd` + `tdd-workflow` skill enforces the workflow |
| Playwright (browser E2E) | **not on the phone** — Chromium under proot destabilizes/RAM-crashes; run E2E in a cloud sandbox or CI instead |
| Dependabot / Renovate + `npm audit` in CI | GitHub-side; nothing to install locally |
| Semgrep (pattern static analysis) | optional; install inside the container (`pip install semgrep`) where RAM allows |
| error tracker (Sentry) | SaaS — configure in the app repo, not here |
| TDK CLI / Dockerized multi-service stacks | **Docker does not run under proot** (no container runtime). Use a remote sandbox instead — e.g. the `opencode-daytona` plugin runs the whole agent session in an isolated cloud VM |

## The pattern to remember

- **This repo**: set up once, covers every language/framework — agent harness,
  sandbox, plugins, MCPs, security profile.
- **Each project**: the language-specific safety tools, which opencode can
  generate for you in one prompt ("harden this app: pre-commit, gitleaks,
  lint, typecheck, test runner, and a CI workflow that fails on warnings").
- **Real machines / cloud**: browser E2E, Dockerized stacks, releases.

## Workflow that holds up on a phone

1. `mkdir app && cd app && git init` → run `setup-opencode.sh` (once per project)
2. `opencode` → `/plan` the app → build → `/tdd` → `/code-review` → `/security`
3. `git push` via GH (`apt install gh && gh auth login` inside the container, optional)
4. CI (GitHub Actions) runs the lint/typecheck/tests/E2E you scaffolded — that is
   where the heavy validation happens, not on the phone.

That split keeps the phone fast and safe while the fragile-demo problem gets
checked by the tools that are actually good at it.
