# BLOCKED — 2026-09-27, step 3 (0.4.8 mode bar) gate

**Update 2026-09-27:** 0.4.8 and 0.4.9 are ticked on the self-QA gates. A hand click-through is still recommended.

**What's left:** the real-app check the gate asks for: `scripts/run.sh` with
`VIDEOBOY_FLAGS=modeBar`, clicking the mode bar through real hit-testing.

**Why it's blocked:** a macOS **"Developer Tools Access"** password dialog came up
("needs to take control of another process for debugging"). It most likely comes from
an `lldb` attempt earlier in this session. It takes all input, so the posted clicks
never reached Videoboy. The agent won't enter a password.

**What needs a person:**
1. Cancel the dialog (or enter the password if you trust it).
2. Run `VIDEOBOY_FLAGS=modeBar scripts/run.sh`. Click through the setup assistant,
   then click IMPORT / VJ / SETTINGS on the bottom strip and press ⌘1 / ⌘2 / ⌘3. Each
   one should switch the view, and the transport and output should keep running.
3. If that works, tick 0.4.8 in BUILD-PLAN. Step 4 (0.4.9 Import mode) can then start.

Everything else in the step 3 gate is green. See BUGHUNT-2026-09-27.md, "step 3".

## Update (same day, after the dialog was dismissed)

Retried with real posted clicks. The real app came up with the mode bar and the setup
assistant sheet. **Found and fixed:** on first launch, the older "Nothing is being
sent out yet" output offer (a modal alert) opened on top of the assistant's sheet. The
offer now waits until the assistant closes (`runSetupAssistant(then:)`). After that,
posted clicks stopped reaching the app. The click tool can't confirm delivery, so the
real-app click-through of IMPORT / VJ / SETTINGS is **still unverified by a person**.
`selfqa modes` covers the same path through `hitTest` inside a real window.
Your preferences were restored each time.
