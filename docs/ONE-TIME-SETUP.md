# ONE-TIME-SETUP.md

The short list of things only you can do. Do these once, then you can let Claude Code run autonomously to the clickable-app milestone. Everything else it handles and self-verifies.

## 1. Toolchain (5 min)
- Install Xcode + command line tools (`xcode-select --install`).
- Install Node 22+ if needed (`brew install node`) and Claude Code (`npm install -g @anthropic-ai/claude-code`).
- Verify: `swift --version`, `xcodebuild -version` both print.

## 2. Repo (2 min)
- Put `CLAUDE.md` at the repo root; `BUILD-PLAN.md`, `SPEC.md`, `SELF-QA-HARNESS.md`, this file into `docs/`.
- Put `layout-v6.html` into `docs/mockups/` — it is the normative visual reference for the UI (SPEC §14).
- `cp config/devices.example.json config/devices.json` (Claude will help fill it, but see step 4).

## 3. Sample media (yours to provide)
- Drop test videos into `samples/`. **Include at least one real `.dv` file** — DV is the whole point and AVFoundation can't decode it, so the libav path and the corruptor need a genuine DV fixture. Also include a couple of ordinary `.mov`/`.mp4` clips.
- Anything MPEG-family you want to datamosh is welcome too.
- Claude generates `samples/manifest.json` from what's there; if `samples/` has no `.dv`, it will stop and ask.

## 4. Hardware loop (the part that lets Claude see the output)
- Connect: Mac Studio → HDMI output card → HDMI-to-RCA → **DVC100** → back into the Mac (USB). This closes the loop so Claude can capture the real analog-facing signal.
- Power the DVC100; confirm macOS sees it as a capture device (it appears like a camera/UVC input).
- In `config/devices.json`, name which display is the HDMI card and which capture device is the DVC100 (or run the app once and let Claude read the enumerated names into the file).

## 5. Permissions (one click each — the only unavoidable manual step)
macOS gates camera/capture behind a permission prompt a CLI agent can't click. On the app's first run it will ask for **Camera** access (the DVC100 presents as a camera) — click **Allow** once. That's it. (If you also enable screen-capture sources later, grant **Screen Recording** once then too.)
- If a prompt never appears and capture fails, check System Settings → Privacy & Security → Camera and enable the app.

## 6. Let it run
Open Claude Code in the repo and give it one prompt, e.g.:

> Read CLAUDE.md and docs/BUILD-PLAN.md. Run autonomously through Phase 2. Build the self-QA harness first, self-verify every step with offscreen PNGs and the DVC100 loopback, commit per phase, and stop when there's a clickable app with evidence in selfqa/out/ — or at a real blocker written to docs/BLOCKED.md. Don't wait for me between phases.

Then walk away. When you come back you should have a launchable `.app`, a `docs/FIRST-RUN.md`, and the self-QA evidence.

## What you are NOT doing yet
- No Apple Developer Program, no notarization, no distribution signing. The app runs locally unsigned. Revisit ADP only once it's fully functioning and you actually want to ship it.
