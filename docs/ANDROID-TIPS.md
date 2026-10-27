# Android/Termux notes for long agent sessions

Real-world gotchas running opencode on a phone (checked through several weeks of
daily use by the community). This file assumes the setup from this repo.

## 1. The phantom process killer (signal 9)
Android 12+ reaps background processes; leave Termux mid-agent-run and you may
find the session killed with `signal 9`.

- Run `termux-wake-lock` (or acquire it in Termux's notification) before long runs.
- Keep Termux in the foreground during heavy tasks.
- If you can use adb (`adb shell am set-standby-bucket com.termux active`) or a
  "no battery optimization" toggle for Termux, do it.
- Inside proot, use an idempotent workflow: GSD/plan files on disk mean a fresh
  session can resume without loss.

## 2. RAM is the limit, not CPU
- Check `free -m` before anything heavy.
- Avoid browser/Playwright E2E tooling on phones — Chromium under proot triggers
  `epoll`/`futex` kernel-not-implemented failures under memory pressure.
- dcp (dynamic context pruning) is enabled by the setup for exactly this reason:
  it prunes stale tool outputs, so long sessions survive with small models.
- One runaway log file can fill a phone's `/tmp`. The setup already redirects
  TMPDIR into a private workspace dir inside your project.

## 3. No systemd, no auto-start
- MCP servers, graphify daemons etc all start on demand with the session. Verify
  with `ps` before assuming something is running.
- Detached/`setsid` background jobs survive a tool timeout but die with the
  environment restart. Don't arm long sleeps (the clock freezes when the phone
  suspends); write receipts to a file and re-run idempotent scripts.

## 4. Termux Node must not leak into the container
Termux's own Node reports `process.platform = "android"`, which breaks npm
platform checks, Playwright and some plugins. Everything in this repo runs only
on the Linux Node inside the Ubuntu userland (the setup script explicitly
refuses an `android`-platform Node). Symptom of doing it wrong: plugins silently
not loading.

## 5. Storage and initial sync
- First install is ~1–2 GB (distro + Node + opencode + node_modules).
- `proot-distro` stores the rootfs under Termux's private data — moving it to
  `/sdcard` breaks it (no exec on some filesystems). Leave defaults alone.
- If the phone is slow on first plugin fetch, run once inside the container:
  `npm install -g opencode-ai` gets cached; subsequent `npx --yes` runs are fast.

## 6. DNS (the #1 silent failure)
If `git clone` / `npm install` hang or fail inside the container:

```bash
echo 'nameserver 8.8.8.8' > /etc/resolv.conf
```

The setup script pre-checks this and refuses to start on broken DNS.

## 7. Keyboard/screen ergonomics
- The TUI is usable on a phone but a terminal with an Escape key helps
  (Hacker's Keyboard, or a Bluetooth keyboard).
- opencode sessions are resumable: `opencode --continue` picks up your last
  session — cheap insurance on mobile.
