# Audit work list — 2026-10-12

Numbered, self-contained fixes from the 2026-10-12 code and architecture audit of
commit `a4aeb32`. Each item can be handed to a coding agent as written. The
executive report (https://claude.ai/artifact/CCNgK8X1hcMCxuFFTunPj6, private to the
owner) holds the reasoning. Finding IDs (`V-03`, `UI-6`, …) refer to that report's
register.

The audit was a static read. Nothing was built or run, so every "Done when" below
still has to be proven on the Mac Studio.

**Project.** NewVHS › Research & Development › Videoboy. The Claude Max subscription
that runs the coding agents is attached to this project as a cost. The ledger and the
projection to the beta gate are in the report's *Project costs* section.

---

## Rules for whoever executes this list

1. **CLAUDE.md governs.** Read it first. Before starting an item, append it to
   `docs/QUEUE.md` as a new `Qn` quoting the item title verbatim. Have only one item
   in progress at a time.
2. **One item, one commit.** Commit message: `audit W-NN: <title>`. Touch only the
   files the item names. If you need another file, stop and say why in the queue
   entry.
3. **Build and verify only through the scripts, on the Mac.**
   - Run `scripts/test.sh` after any Core change, and `scripts/verify.sh` before an
     item counts as done.
   - Also run the self-QA checks each item names.
   - In a Linux cloud session (there is no Swift toolchain there), make the edit,
     then move the queue entry to *Awaiting verification* with the exact commands.
     Never claim a check passed if you did not run it.
4. **Frame-path rule.**
   - **Which items it covers:** any item that touches `Engine`, a `Node`,
     `MetalContext`, `ShellController.refresh(from:)` /
     `advanceAutomation(from:)`, or anything else called from the display-link
     tick.
   - **What to run:** `scripts/selfqa.sh stress` on a **release** build, before and
     after the change. Record the mean, p95 and worst tick in the commit message.
   - **When to revert:** if the worst tick gets more than 1 ms worse.
5. **Never make a gate pass by weakening it.**
   - Don't delete, skip or loosen a test or a self-QA assertion.
   - Don't turn a failure into "blocked".
   - Don't raise a timing threshold.
6. **Tags.**
   - **Mechanical:** do exactly what is written.
   - **Guided:** use your judgement inside the spec given.
   - **Design-first:** write a half-page design note in the queue entry and get the
     owner's OK before writing code.
   - **Owner decision:** ask the owner the question stated. Don't guess.
7. **Line numbers are from `a4aeb32` and will drift.** Find code by the symbol names
   given. The `≈L` numbers are hints.
8. **Priority and size.**
   - Priority: **P0** can end a show · **P1** high · **P2** medium · **P3** low.
   - Size: **S** < 2 h · **M** < 1 day · **L** > 1 day.

Work Part A first, then go in order unless the owner reorders.
Part K is architect-led. Don't start it piecemeal.

| Part | Items | Theme |
|---|---|---|
| A | W-01 – W-09 | Show safety |
| B | W-10 – W-16 | Crash and memory safety |
| C | W-17 – W-24 | Data integrity |
| D | W-25 – W-30 | Timing and clock correctness |
| E | W-31 – W-34 | The wedge, mechanical parts |
| F | W-35 – W-46 | Main-thread hygiene |
| G | W-47 – W-54 | Quality gates and hermetic tests |
| H | W-55 – W-56 | Docs and the module template |
| I | W-57 – W-60 | Swift 6 preparation |
| J | W-61 – W-68 | Structural work, step by step |
| K | X-1 – X-10 | Architect-led, not for piecemeal delegation |

---

## Part A — Show safety

### W-01 · Keep the displays awake while the render clock runs
`P0 · S · Mechanical` · Finding V-01 (FP-3)

> **Status:** built in `627b504` (queue Q4), awaiting verification on the Mac.

**Why.** Nothing stops display sleep. In a MIDI-only set, no keyboard or mouse event
resets the idle timer. Once the display-sleep timeout passes, the HDMI card loses
signal and the analog output goes black. The output layer's `nextDrawable()` can
then block the main thread.

**Where.** `App/Sources/Videoboy/Render/Engine.swift`, `start(drivenBy:)`, ≈L778:
```swift
liveActivity = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
```

**Do.**
1. Change the options to `[.userInitiated, .idleDisplaySleepDisabled, .latencyCritical]`.
   - `.userInitiated` also disables idle system sleep, which a live instrument
     needs.
2. Keep the existing `endActivity` in `stop()`.
3. Log once when the activity begins:
   `Log.info(.render, "display and system sleep held off while the render clock runs")`.

**Done when.** With the app running, `pmset -g assertions` lists Videoboy under
`PreventUserIdleDisplaySleep` and `PreventUserIdleSystemSleep`. After quitting, the
entries are gone.

**Verify.** `scripts/build.sh`, `scripts/run.sh`, then `pmset -g assertions | grep -i -A2 videoboy`.

---

### W-02 · ⌘H must never hide the program output
`P0 · S · Mechanical` · Finding V-02 (UI-8)

> **Status:** built in `4ebf3b9` (queue Q5), awaiting verification on the Mac.

**Why.** `NSWindow.canHide` defaults to `true`. Hide Videoboy (⌘H, in the app menu)
hides the borderless PROGRAM window, so the analog chain shows the desktop.

**Where.**
- `App/Sources/Videoboy/Output/OutputWindowController.swift`: the borderless window
  built in `init` (≈L59–79).
- Every other borderless output window in `App/Sources/Videoboy/Output/`. Find them
  with `grep -n "styleMask: \[.borderless\]"`.

**Do.** Set `window.canHide = false` next to the existing
`window.ignoresMouseEvents = true` on every output window.

**Done when.** With PROGRAM routed to a display, ⌘H hides the main window and the
output display keeps showing PROGRAM.

**Verify.** `scripts/selfqa.sh output`, which needs the HDMI card, then a manual ⌘H
check on the rig.

---

### W-03 · Confirm or refuse show-replacing commands while live
`P0 · M · Guided` · Finding V-02 (UI-6)

**Why.** New (⌘N), Open… (⌘O) and Open Recent each replace the live show with no
confirmation. They eject all four channels (black on air), remove every MIDI mapping
and clear undo. LOCK lets every ⌘-key through (`BankLockController.refuses`, ≈L169:
`guard !flags.contains(.command)`).

**Where.**
- `App/Sources/Videoboy/AppDelegate.swift`: `newTemplate()`, `openTemplate()`,
  `recentChosenFromMenu(_:)`, `open(templateAt:)` (≈L338–400).
- `App/Sources/Videoboy/UI/ShellController.swift`: `newTemplate()` (≈L1688) and
  `openTemplate(_:from:)` (≈L1563).

**Do.**
1. Add `var isLive: Bool` to `ShellController`. It is true when any of these hold:
   - any channel is playing (`engine.sources.values.contains { $0.isPlaying }`);
   - `engine.transport.isRunning`;
   - an output is routed (`!hasNoOutputs`);
   - a recording is running.
2. Add `var isAnySideLocked: Bool` to `BankLockController`, if it doesn't already
   exist.
3. In each AppDelegate entry point above, before anything else:
   - **If a side is locked:** refuse. Call `presentNotice("Locked", "Unlock both
     sides to replace the show.")` and return.
   - **Else if `isLive`:** show an `NSAlert` with `beginSheetModal(for:)` on the main
     window, not `runModal()`.
     - Title: "Replace the live show?"
     - Detail: "All four channels will be ejected and MIDI mappings replaced."
     - Buttons: [Replace] [Cancel].
     - Continue only on Replace.
   - **Otherwise:** keep today's behaviour unchanged.

**Done when.**
- ⌘N during playback asks first.
- With LOCK on, ⌘N, ⌘O and Open Recent are refused with the notice.
- With nothing playing and no output, nothing changes.

**Verify.** `scripts/selfqa.sh template` and `scripts/selfqa.sh lock`. Add one
assertion to `LockSelfQA`: with a side locked, `newTemplate` leaves channel A loaded.

---

### W-04 · Closing the window or quitting mid-show asks first
`P0 · S · Guided` · Finding V-02 (UI-8)

**Why.** `applicationShouldTerminateAfterLastWindowClosed` returns `true`
(AppDelegate ≈L209), so the red close button quits. With auto-save on and a file set,
`applicationShouldTerminate` saves and quits without asking (≈L183–185).

**Where.**
- `MainWindowController.swift`: the `NSWindowDelegate` extension (≈L178). It has no
  `windowShouldClose`.
- `AppDelegate.applicationShouldTerminate(_:)`.

**Do.**
1. Add `windowShouldClose(_:)`. If `shellController?.isLive == true` (from W-03),
   show a sheet:
   - Title: "Quit Videoboy?"
   - Detail: "The output will stop."
   - Buttons: [Quit] [Cancel].
   - Return `false` from `windowShouldClose`, and on Quit call
     `NSApp.terminate(nil)` yourself.
2. In `applicationShouldTerminate`, when `isLive`, confirm the same way before the
   auto-save branch. Auto-save still saves after the person confirms.

**Done when.**
- The red button and ⌘Q during a show prompt.
- An idle quit behaves as it does today.

**Verify.** Manually in `scripts/run.sh`. Use `scripts/selfqa.sh ui` for regressions.

---

### W-05 · Remove the "Don't remind me again" trap from the quit prompt
`P0 · S · Mechanical` · Finding V-03 (DL-7, UI-7)

**Why.** `ReminderAlert` stores only that a prompt was suppressed, not the answer. On
quit, `.notShown` maps to `.terminateNow` (AppDelegate ≈L198). Someone who ticks the
box and clicks **Save** loses their work on every later quit.

**Where.**
- `App/Sources/Videoboy/UI/ReminderAlert.swift`: `show(...)`.
- `AppDelegate.applicationShouldTerminate`.
- `Core/Sources/VideoboyCore/Persistence/Preferences.swift`: `suppressedReminders`.

**Do.**
1. Add a parameter `allowsSuppression: Bool = true` to `ReminderAlert.show`. When it
   is false:
   - don't show the suppression button;
   - ignore any stored suppression for that kind.
2. Pass `allowsSuppression: false` for `.saveOnQuit`.
3. When preferences load, remove `.saveOnQuit` from `suppressedReminders` if it is
   there, and log it once.

**Done when.**
- The quit prompt never shows the box.
- A preferences file that had `saveOnQuit` suppressed gets the prompt back.
- New test in `PreferenceTests`: decoding a file whose `suppressedReminders`
  contains `saveOnQuit` yields a store that `shouldRemind(.saveOnQuit)`.

---

### W-06 · Show writes are atomic and go through one serial writer
`P1 · S · Mechanical` · Finding V-03 (DL-2, UI-12)

**Why.**
- `TemplateDocument.write(to:)` uses `.write(to: url)` with no `.atomic`
  (TemplateDocument.swift ≈L235). A crash or a full disk mid-write truncates the only
  copy.
- Auto-save writes on `DispatchQueue.global` (AppDelegate ≈L420), while ⌘S and
  quit-save write on main. Two writers can interleave, or an older snapshot can land
  last.

**Do.**
1. `TemplateDocument.write(to:)`: change to `try encoder.encode(self).write(to: url, options: .atomic)`.
2. Make `TemplateDocument` and its nested types `Sendable`. Their members already
   are. Add the conformances and let the compiler confirm.
3. New file `Core/Sources/VideoboyCore/Persistence/ShowWriter.swift`, with the
   standard file header. Give it:
   - a private serial `DispatchQueue(label: "videoboy.show-writer", qos: .utility)`;
   - `func write(_ document: TemplateDocument, to url: URL, completion: @escaping @Sendable (Error?) -> Void)`,
     which runs on the queue and calls `completion` on main;
   - `func flush()`, which does `queue.sync {}`.
4. Route all three writers through one `ShowWriter`:
   - auto-save (`AppDelegate.startAutosave`);
   - `ShellController.saveTemplate(to:)`, ≈L1553. It still captures on main and
     writes through the writer;
   - quit-save. It calls `flush()` before returning `.terminateNow`.
5. Create the `ShowWriter` once, in AppDelegate, and inject it into
   `ShellController`. Don't make it a singleton.

**Done when.** A new Core test writes 200 documents from 4 concurrent threads to one
URL through `ShowWriter`. After every write, `TemplateDocument.read` succeeds, and no
temporary file is left in the folder.

**Verify.** `scripts/test.sh` and `scripts/selfqa.sh template`.

---

### W-07 · Track unsaved changes
`P1 · M · Guided` · Finding V-03

**Why.** There is no dirty state. The quit prompt shows on every quit, which pushes
people to suppress it, and recovery (W-08) has nothing to key on.

**Do.**
1. Add `private(set) var hasUnsavedChanges = false` and a callback
   `onUnsavedChangesChanged: ((Bool) -> Void)?` to `ShellController`.
2. Set it to true on every show mutation. Look for these paths:
   - `edit(_:slot:_:)` (≈L1718);
   - effect-chain add, remove and reorder;
   - mapping bind and unbind;
   - queue edits;
   - clip-pad edits;
   - tempo and subdivision changes;
   - channel load and eject.
3. Set it to false after a successful save, open or new.
4. In AppDelegate:
   - bind the callback to `window.isDocumentEdited`;
   - show the quit prompt only when `hasUnsavedChanges` is true.

**Done when.**
- A fresh launch and quit doesn't prompt.
- Moving any effect fader and then quitting does prompt.
- The window's close button shows the edited dot.

---

### W-08 · Crash-recovery snapshots
`P1 · M · Guided` · Finding V-03 (DL-1) · depends on W-06, W-07

**Do.**
1. In AppDelegate, add a 30-second timer that runs only while `hasUnsavedChanges`.
   On each fire:
   - capture with `captureTemplate(name:)` on main;
   - time the capture under `MainThreadCosts` label `recovery.capture`;
   - write through `ShowWriter` to
     `~/Library/Application Support/Videoboy/Recovery/recovery.vbt`.
2. Delete that file after a clean quit and after any successful save.
3. At launch, after the setup assistant and before any output offer, check for the
   file. If it exists, show a sheet:
   - Title: "Restore the show from <time>?"
   - Buttons: [Restore] [Discard].
   - On Restore, call `openTemplate(_:from: nil)`. Don't set it as the current file.
4. If `recovery.capture` costs more than 2 ms on a full show, increase the interval
   and say so in the commit.
5. In self-QA, write the snapshot to the sandbox folder (W-51), never to the real
   folder.

**Owner decision.** The interval. Default: 30 s.

**Done when.** Load clips, map MIDI and build chains, then `kill -9` the app.
Relaunch: the restore offer appears, and the restored show matches the original
(chains, values, mappings, queues, pads).

---

### W-09 · Default auto-save cadence
`P2 · S · Owner decision`

**Question for the owner.** Should `Preferences.autoSave` default to
`.everyFiveMinutes` instead of `.never` (Preferences.swift ≈L84)? It applies only
once a show has a file.

If yes, change the default, update the Settings ▸ Save pane label, and add a
`PreferenceTests` case for the default.

---

## Part B — Crash and memory safety

### W-10 · Fix the CoreMIDI event-list walk
`P0 · S · Guided` · Finding V-06 (CC-2)

**Why.** `MIDIInput.handle(eventList:)` (≈L234–252) copies the list and the first
packet into locals, then advances with `MIDIEventPacketNext(&packet)` on the local
copy. From roughly the 17th single-word packet in one list, it reads stack garbage.
The results are phantom parameter jumps, a spin on a garbage `wordCount`, or a crash.

**Do.**
1. Move the decode loop into a static, testable function:
   `static func events(in list: UnsafePointer<MIDIEventList>) -> [ControlEvent]`.
   `handle` then calls `enqueue` for each event.
2. Walk the packets through pointers into the original buffer, never through a copy:
   - **Preferred:** `for packet in list.unsafeSequence() { … }`, from the CoreMIDI
     Swift overlay.
   - **If that API isn't in the SDK:** start from
     `UnsafeRawPointer(list) + MemoryLayout<MIDIEventList>.offset(of: \.packet)!`,
     bound to `MIDIEventPacket`. Advance with `MIDIEventPacketNext` on that pointer.
3. Bound each packet's word loop with `min(Int(packet.pointee.wordCount), 64)`.

**Done when.**
- A new test in `MIDIAndPlaybackTests` builds a 40-packet event list with
  `MIDIEventListInit` / `MIDIEventListAdd` in a 4 KB buffer (40 different CC
  numbers), runs `events(in:)`, and asserts 40 events in order.
- That test fails on the old code (or crashes it).

**Verify.** `scripts/test.sh` and `scripts/selfqa.sh midi`.

---

### W-11 · Malformed ISF files must not trap
`P1 · S · Mechanical` · Finding V-07 (BS-6)

**Why.** These conversions trap on large or non-finite numbers:
- `VALUES` uses `Int($0)` (ISFDocument.swift ≈L349).
- `Int(value.rounded())` runs before the clamp (ISFNode.swift ≈L616).
- `Int32(current[0].rounded())` (ISFNode.swift ≈L752).
- `ISFSizeExpression` recurses without a depth limit.

The library is scanned at launch (`Engine.init(catalog: ModuleCatalog())`), and
`~/Library/Graphics/ISF` is shared with other apps. One bad file therefore crashes
every launch.

**Do.**
1. Add two helpers in `ISFDocument.swift`:
   - `static func clampedInt(_ value: Double, in range: ClosedRange<Int>) -> Int`.
     Non-finite values go to `range.lowerBound`; clamp in Double, then convert.
   - `static func clampedInt32(_ value: Double) -> Int32`, built the same way.
2. In `Core/Sources/VideoboyCore/Modules/Effects/ISF/`, every `Int(` or `Int32(`
   applied to a Double that came from JSON or from a parameter value must go through
   these helpers.
3. Cap `ISFSizeExpression` nesting at depth 32. Deeper input returns the parser's
   existing "invalid expression" result.

**Done when.** New `ISFParsingTests` cases each produce a labelled error or a clamped
value, never a trap:
- `"VALUES":[1e19,-1e19]`;
- a `long` `DEFAULT` of `3e9`;
- an audio `MAX` of `1e300`;
- a size expression with 1,000 nested parentheses;
- `$WIDTH*` repeated 60 times.

---

### W-12 · Ignore SIGPIPE; set SO_NOSIGPIPE on the emulator socket
`P1 · S · Mechanical` · Finding V-18 (BS-5)

**Why.** Nothing in the app ignores SIGPIPE. A write to the Amiberry Unix socket
after the emulator has closed it kills Videoboy.

**Do.**
1. In `App/Sources/Videoboy/main.swift`, add `signal(SIGPIPE, SIG_IGN)` in the
   `.normal` and `.selfQA` branches.
   - Don't add it to `.optimize`. That child should still die if its parent goes
     away.
2. In `Core/Sources/VideoboyCore/Modules/Emu/AmiberryIPC.swift`, set the option right
   after `socket(AF_UNIX, SOCK_STREAM, 0)` (≈L111):
   ```swift
   var one: Int32 = 1
   setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
   ```
3. Make sure `write` failures with `EPIPE` come back as the existing `Failure` error.

---

### W-13 · Rebuild the MPEG scaler when the frame size or format changes
`P1 · S · Mechanical` · Finding V-17 (BS-7)

**Why.** `MPEGStreamDecoder` makes its `sws_getContext` once, from the first frame
(≈L306–316). A later frame with a different size makes `sws_scale` read past the
plane buffers.

**Do.**
1. Store the scaler's source width, height and pixel format.
2. When a frame differs, `sws_freeContext` the old scaler and create a new one. Or
   use `sws_getCachedContext` with the same arguments.
3. Follow `H264MoshDecoder.swift` (≈L132), which already does this.

**Done when.** The code passes review, `scripts/test.sh` passes, and
`scripts/selfqa.sh playback` passes.

---

### W-14 · Remove the two `deinit → queue.sync` self-deadlocks
`P2 · S · Mechanical` · Findings DL-13, BS-10

**Where and do.**
- **`Catalog.deinit`** (≈L146): close the database directly, without
  `queue.sync`. Queued blocks capture `self` strongly, so `deinit` cannot overlap
  them.
- **`AmigaCommandBridge.deinit` / `stop()`** (≈L145–163): in `deinit`, cancel the
  timer directly instead of calling `stop()`.
- **`EmulatorController`** (≈L284–295): call `bridge?.stop()` before replacing
  `bridge`.

---

### W-15 · Window capture: stop must win over a start in flight
`P2 · S · Guided` · Finding CC-10

**Where.**
- `App/Sources/Videoboy/Platform/WindowCaptureSource.swift`: `WindowCaptureSession`
  `start`/`stop`, ≈L100–120.
- `SourceSessionManager.swift` ≈L42.

**Do.**
1. Mark `WindowCaptureSession` `@MainActor`.
2. Add `private var stopRequested = false`:
   - `stop()` sets it to true;
   - `start` clears it at its beginning;
   - after every `await` inside `start`, add
     `guard !stopRequested else { try? await stream?.stopCapture(); stream = nil; return }`.
3. Route the `node` handoff to the capture queue through the node's existing lock.

---

### W-16 · Read the capture node's cross-thread state under its lock
`P3 · S · Mechanical` · Finding FP-15

In `Core/Sources/VideoboyCore/Modules/Sources/CaptureSourceNode.swift`:
1. Make `receivedFrameCount` and `deviceName` private stored properties.
2. Expose public computed getters that read them under `lock`.
3. `isLive` uses the locked getter.

---

## Part C — Data integrity

### W-17 · Catalog transactions and queries report failure
`P1 · S · Mechanical` · Finding V-12 (DL-4)

**Where.** `Core/Sources/VideoboyCore/Persistence/Catalog.swift`: `transaction`,
`prepare` and `query` (≈L381–400).

**Do.**
1. **`transaction`:** change it to
   `@discardableResult private func transaction(_ body: () throws -> Void) -> Bool`.
   - If `BEGIN IMMEDIATE` fails, log and return false.
   - If `body` throws, `ROLLBACK` and return false.
   - If `COMMIT` fails, `ROLLBACK`, log and return false.
2. **`query`:** make it return `Bool`.
   - Loop on `sqlite3_step`. `SQLITE_ROW` calls `row`; `SQLITE_DONE` ends the loop
     with success.
   - Any other code: log through `logError("step")` and return false.
3. **Open:** after `sqlite3_open_v2` succeeds, call `sqlite3_busy_timeout(handle, 2000)`.
4. **Report write failures:**
   - add `public var onWriteFailure: ((String) -> Void)?`;
   - call it on main, once per streak of failed writes;
   - reset the streak on the next success.

**Done when.** New `CatalogAndImportTests`:
- a write to a catalog whose file was made read-only after opening fires
  `onWriteFailure`;
- a query on a dropped table returns false.

---

### W-18 · A failed catalog read must not look like an empty library
`P1 · S · Guided` · Finding V-12 (DL-4) · depends on W-17

**Where.**
- `Catalog.loadClips()`.
- `App/Sources/Videoboy/UI/LibraryModel.swift` `attach` (≈L250–262), where
  `if stored.isEmpty {` seeds sample clips.
- `AppDelegate.openCatalog(into:)`.

**Do.**
1. `loadClips()` throws `CatalogError` on a read failure. An empty catalog still
   returns `[]`.
2. In `attach`, on a throw:
   - don't seed;
   - don't write to the catalog for the rest of the session;
   - show a notice that stays up: "The library catalog could not be read. Changes
     are not being saved."
3. In `Catalog.init`, after `migrate()`:
   - run `PRAGMA quick_check`;
   - if the result isn't `ok`, throw `CatalogError.corrupt`.
4. In AppDelegate, on `.corrupt`, offer [Open Newest Backup] [Continue Without
   Saving]. The newest backup is in `Backups/` next to the catalog.

**Done when.** Unit test: a catalog file with garbage bytes written over page 2
throws `.corrupt`.

---

### W-19 · Checkpoint and close the catalog at quit
`P2 · S · Mechanical` · Finding DL-5

**Do.**
1. Add `public func close()` to `Catalog`. On the queue, it:
   - runs `sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)`;
   - calls `sqlite3_close`;
   - sets `database = nil`.
2. Make every later call a no-op once closed.
3. In `AppDelegate.applicationWillTerminate`, call `catalog?.close()` after
   `catalog?.flush()`.

**Done when.** After a quit, the catalog's `-wal` file is either 0 bytes or absent.

---

### W-20 · Catalog schema guards
`P2 · S · Mechanical` · Finding DL-11

**Where.** `Catalog.migrate()` (≈L158–192) and the upsert statement (≈L246).

**Do.**
1. Add `static let schemaVersion: Int32 = 2`.
2. If the stored `user_version` is greater than `schemaVersion`, throw
   `CatalogError.newerSchema(found:)`. AppDelegate shows: "This library was made by
   a newer Videoboy."
3. Wrap each `if version < N` step in `BEGIN IMMEDIATE` / `COMMIT`. The `ALTER`s and
   `PRAGMA user_version` go in the same transaction.
4. Replace `INSERT OR REPLACE INTO clips` with
   `INSERT INTO clips (...) VALUES (...) ON CONFLICT(id) DO UPDATE SET <every known column> = excluded.<column>`.

**Done when.** Tests:
- a catalog with `user_version = 3` is refused;
- a v1 catalog upgrades;
- an upsert keeps a value in an extra column added by hand.

---

### W-21 · A preferences file that fails to parse is kept aside, not overwritten
`P2 · S · Mechanical` · Finding DL-17

**Where.** `PreferenceStore.load(from:)` (Preferences.swift ≈L383–395).

**Do.**
1. On a decode error, move the file to `preferences.corrupt-<yyyyMMdd-HHmmss>.json`
   in the same folder.
2. Set `public private(set) var recoveredFromCorruptFile = false` to true.
3. AppDelegate shows a notice once: "Settings could not be read and were reset. The
   old file was kept as …".

---

### W-22 · Debounce preference writes, off the main thread
`P2 · S · Guided` · Finding DL-15

**Why.** Every change encodes pretty-printed JSON and writes the file atomically on
the main thread, which is also the render thread. Dragging the Data Burn colour well
does this many times a second.

**Do.**
1. In `PreferenceStore`, replace the immediate `save()` in `didSet` with a debounce:
   save on a private serial utility queue 0.5 s after the last change, encoding a
   snapshot (`Preferences` is `Sendable`).
2. Add `public func flush()`, which writes any pending change synchronously, and
   call it from `applicationWillTerminate`.
3. Keep `onChange` synchronous on main.

**Done when.** Dragging the colour well for 5 s writes the file at most 10 times
(count by logging writes in debug). Existing `PreferenceTests` pass. A new test sets
a value, calls `flush()` and reads the file back.

---

### W-23 · Confirm removing clips from the library
`P2 · S · Mechanical` · Finding V-16 (DL-8, UI-15)

**Where.** `App/Sources/Videoboy/UI/LibraryPanelBody.swift` `delete(_:)` (≈L907–913).

**Do.** When more than one clip is selected, show a sheet before calling
`removeItems`:
- Title: "Remove N clips from the library?"
- Detail: "Their marks, bins and optimized links are deleted. The files stay on
  disk."
- Buttons: [Remove] [Cancel].

Full library undo is a later design item (Part J, W-68).

---

### W-24 · Opening a show applies the queue limit and checks files off the main thread
`P2 · S · Guided` · Finding DL-9

**Where.**
- `ShellController.restoreQueues(_:)` (≈L1625–1640).
- `ClipQueue.swift` (≈L178–185).

**Do.**
1. Apply `QueueLimit.resolved` (the existing per-channel limit) when restoring.
2. If any clips go over the limit, report how many in the status strip.
3. Move the `FileManager.fileExists` filtering to a utility queue, then build
   `QueueSet` on main.

---

## Part D — Timing and clock correctness

### W-25 · Clamp tempo everywhere; cap scheduler work per advance
`P2 · S · Mechanical` · Finding CC-7

**Do.**
1. In `Core/Sources/VideoboyCore/Clock/Transport.swift`:
   - add `public static let tempoRange: ClosedRange<Double> = 20...999`;
   - in the `beatsPerMinute` `didSet`, keep the old value when the new one is
     non-finite;
   - clamp finite values into `tempoRange`.
2. Clamp on template decode: the `TemplateDocument` clock, where it is applied in
   `ShellController.openTemplate`.
3. In `Scheduler.advance`, stop after 512 fired events per call and log a warning
   once.

**Done when.** `ClockTests`:
- a tempo of `1e12` clamps to 999;
- `.nan` keeps the old value;
- an advance across a huge horizon returns.

---

### W-26 · Restarting the transport resets beat-driven state
`P1 · S · Guided` · Finding V-08 (CC-3)

**Why.** `Transport.start` resets `anchorBeats` to 0, but scheduler subscriptions
keep `lastScheduledBeat`. After running to beat 960, the scheduler is silent for
about 8 minutes. Beat-stepped clips use `Int(abs(currentInterval - previous))`
(ClipSourceNode.swift ≈L590), so they jump 960 steps in one frame.

**Do.**
1. In `Transport`, add `public private(set) var epoch = 0` and increment it in
   `start(atHostTime:)`.
2. In `Scheduler`, keep `lastSeenEpoch`. When `advance` sees a different epoch:
   - set every subscription's `lastScheduledBeat` to the transport's current beats,
     minus a small epsilon;
   - record the new epoch.
3. In `ClipSourceNode` beat stepping:
   - if `currentInterval < previous`, the beats went backwards. Set
     `lastSteppedBoundary = currentInterval` and return without stepping;
   - remove the `abs`.

**Done when.** New tests:
- run to beat 960, stop, start: the next quarter-note boundary fires within one
  beat;
- stepping from beat 960 back to beat 0 moves the playhead at most one step.

---

### W-27 · Beat-driven flips and pad beat-arming are sampled at presentation time
`P2 · S · Guided` · Finding V-14 (UI-14)

**Where.**
- `ShellController.flipAutomatedButtons` (≈L3235, which uses
  `CACurrentMediaTime()`).
- `fireActionTriggers`.
- `ClipPadController.tick` (≈L282).
- All three are called from `refresh(from:)` (the `onFrame` callback, ≈L3922).

**Do.**
1. Call them from `advanceAutomation(from:)` (`onBeforeRender`) instead.
2. Read the time from `engine.framePresentationTime`, never from
   `CACurrentMediaTime()`.
3. Keep the visual refresh parts in `refresh`.

**Verify.** `scripts/selfqa.sh push-fade`, `pads` and `ab-roll`.

---

### W-28 · LFOs, scheduler and musical position use the presentation time
`P2 · S · Guided` · Finding V-14 (FP-11, CC-5)

**Where.** `Engine.renderTick` (≈L895–930). `scheduler.advance(to: now)`,
`lfos.update(atHostTime: now, …)` and `transport.position(atHostTime: now)` all use
`link.timestamp`.

**Do.**
1. Pass `link.targetTimestamp` to all three.
2. Then re-run the latency checks. The scheduler fires at `T − latency`, so check
   that beat-locked changes now land on the same frame as cuts and fades on that
   beat.

**Verify.** `scripts/selfqa.sh push-fade` and `scripts/selfqa.sh calibrate` (needs
hardware). Report before and after.

---

### W-29 · Audio: non-finite samples can't freeze parameters
`P2 · S · Mechanical` · Finding CC-9

**Do.**
1. In `AudioAnalyzer` (≈L136–141), replace non-finite input samples with 0 before
   analysis.
2. In `AudioReactivityBus` (≈L198, L203), treat a non-finite `previous` as 0.
3. In `ParamRegistry.setValue`, throttle the "refused a non-finite value" warning to
   once per slot/code per 10 s.

**Done when.** Test: feed a buffer containing one NaN. The envelope and pulse shapes
recover within one decay period.

---

### W-30 · Release held notes when a MIDI source disappears
`P3 · S · Guided` · Finding CC-8

**Where.** `MIDIInput` (notify handling, ≈L118) and press latches such as `3FB` mosh
HOLD.

**Do.**
1. Track note-ons per source.
2. When a source disappears, deliver a note-off (value 0) for each held note from
   that source, through the normal path.

---

## Part E — The wedge: the mechanical parts

> Keep `FeatureFlag.bitstreamCorruptor` **off** until W-31 to W-34 and Part K
> item X-1 have all landed. With W-32 alone, every beat makes the MPEG decoder
> re-decode from frame 0.

### W-31 · Seed the MPEG corruptor per picture, not per packet
`P1 · S · Mechanical` · Finding V-04 (BS-3)

**Why.** `MPEGCorruptor.corrupt` makes a fresh `SeededRandom(seed: settings.seed)`
on every call (≈L102), and libav hands over one picture per packet. Every picture
therefore gets the same first draw: 0.5666 for seed 1, computed. Below 56.7% amount,
frame drop and reference hold never fire; above it they hit every P/B picture.

**Do.**
1. Add a parameter `pictureIndex: Int = 0` to `corrupt(stream:settings:previousPicture:)`.
2. Seed with
   `SeededRandom(seed: settings.seed ^ (UInt64(truncatingIfNeeded: pictureIndex) &* 0x9E37_79B9_7F4A_7C15))`.
3. In `MPEGStreamDecoder.decodeNext()` (≈L262–280):
   - keep a `decodeOrderIndex` that goes up by one per packet;
   - pass it to `corrupt`;
   - reset it in `restart(at:)`.

**Done when.**
- A new test runs 1,000 single-picture P packets with `pictureIndex` 0…999 at amount
  0.25, and between 200 and 300 are dropped.
- At amount 0 none are dropped; at amount 1 all are.
- Existing `MPEGCorruptorTests` still pass. With the default `pictureIndex = 0`,
  whole-buffer calls behave as before.

---

### W-32 · The beat reseed reaches the decoder
`P1 · S · Guided` · Finding V-04 (FP-1, CC-1, BS-8)

**Why.** The scheduler calls `rerollCorruptionSeed` (Engine.swift ≈L740) at the top
of the tick. `applyAllParameters` then overwrites `corruption.seed` from the registry
(ClipSourceNode.swift ≈L876), and that value is always present (34B, default 1). So
in the app, damage never changes on the beat.

**Do.**
1. In `ClipSourceNode`, add `private var beatSeed: UInt64 = 0`.
2. `rerollCorruptionSeed(using:)` sets `beatSeed` and no longer touches
   `corruption.seed`.
3. `effectiveCorruption` returns a copy of `corruption` with
   `seed = corruption.seed ^ beatSeed` when engaged.
4. Add an order test in Core:
   - build a `ParamRegistry` and a `ClipSourceNode` backed by a fake decoder that
     records the settings it receives (follow the `CountingDecoder` pattern in
     `PrefetchAndCanvasTests`);
   - call `rerollCorruptionSeed(using: 42)`, then `applyParameters(from:)`, then
     render;
   - assert that the decoder saw seed `1 ^ 42`;
   - the test must fail on today's code.

**Owner decision.** Should 33B ("rate") choose the reseed subdivision, or come out
of the UI? Nothing reads it today, and the subscription is fixed to quarter notes.

---

### W-33 · Normalise the damage key so it is inert when it can't apply
`P2 · S · Mechanical` · Finding BS-12

**Where.** `ClipSourceNode.effectiveCorruption` (≈L187): `wetDry > 0.001 ? corruption : .inert`.

**Do.** Return `.inert` in any of these cases:
- `wetDry <= 0.001`;
- `corruption.amount <= 0`;
- the loaded decoder's `dataEffectFamily` has no corruptor.

That stops prefetch misses and MPEG restarts for damage that can't happen.

---

### W-34 · A self-QA lane with the corruptor switched on
`P2 · S · Mechanical` · Finding QA-11

**Do.**
1. Add a case to `scripts/selfqa.sh`: `wedge)`. It runs `ui`, `playback` and
   `stress` with `VIDEOBOY_FLAGS="${VIDEOBOY_FLAGS:+$VIDEOBOY_FLAGS,}bitstreamCorruptor"`.
2. In `UISelfQA`, when the flag is on, assert that the corruptor card is present and
   that its fader writes 31B through the registry.

---

## Part F — Main-thread hygiene, the cheap fixes

### W-35 · Clip Pads resolve their targets once, not twice a second in the tick
`P1 · S · Mechanical` · Finding UI-3

**Why.** `ClipPadController.tick` runs `refreshLive()` every 15 frames (≈L293). For
each loaded pad that calls `shell.playbackTarget(for:)`, which scans the library and
may `stat()` an optimized file (≈L340–355). On a spun-down disk, that blocks the
frame.

**Do.**
1. Cache `resolvedTargets: [Int: URL]`. Recompute it when:
   - a pad is assigned or cleared;
   - the library changes (subscribe through the same path the pad views already
     use; see `LibraryModel.notify()` ≈L353);
   - an optimize job finishes.
2. `refreshLive()` compares cached URLs only. It must make no `FileManager` calls.
3. Add 8 loaded pads to the arrange step of `StressSelfQA`.

**Verify.** `scripts/selfqa.sh pads` and `scripts/selfqa.sh stress` (frame-path
rule).

---

### W-36 · ADV: consult the queue first; cache the fallback order; index by path
`P1 · M · Guided` · Finding V-05 (UI-2, DL-3)

**Where.**
- `ShellController` `planAdvance` / `pickNext` / `settleOutgoing` (≈L1886–2022).
- `LibraryBrowser.fallbackOrder()` (≈L130).
- `ABRoll.swift` (≈L106–120).
- `LibraryModel`.

**Do.**
1. Look at Up Next before calling `fallbackOrder()`. Build the fallback list only
   when the queue is empty.
2. Cache `fallbackOrder()` in `LibraryBrowser`. Invalidate it when the library,
   search or sort changes.
3. Check that the file exists only for the clip finally chosen, not for every
   candidate.
4. Add `LibraryModel.item(forStandardizedPath:)`, backed by a dictionary maintained
   on every mutation. Use it in place of the linear `items.first { $0.url?.standardizedFileURL == … }`.

**Done when.** With a 2,000-clip scratch catalog in `selfqa ab-roll`,
`MainThreadCosts["adv.plan"]` reads below 1 ms. Record the value before and after.

---

### W-37 · Sweeps: no undo steps, survive card rebuilds, hold faders weakly
`P1 · S · Mechanical` · Finding V-13 (UI-4, UI-5)

**Why.**
- `driveSweeps` writes through `entry.write(value)` (≈L3285), which goes
  `parameterChanged` → `edit` → `undoHistory.record`. Two sweeps fill the 100-step
  history in about 2 s.
- Card rebuilds (⌘Z, add/remove, ISF reload, collapse, drag-reorder) leave
  `armedSweeps` holding discarded faders or none at all.

**Do.**
1. Add `writeAutomated(slot:code:value:)`, which calls `engine.registry.setValue`
   directly: no `edit`, no undo.
2. Sweeps use it.
3. Replace the tuple with `struct ArmedSweep { weak var fader: VBFader?; let slot: String; let code: ParamCode }`.
4. Call `refreshArmedSweeps()` at the end of every chain rebuild path. If
   `EffectChainPanelBody`'s internal rebuilds (collapse and reorder, ≈L973 and
   ≈L1137) don't fire `onChainRebuilt`, make them fire it.

**Done when.** In `UndoSelfQA`, a sweep armed for 3 s leaves the undo count
unchanged, and a sweep survives collapsing its card.

---

### W-38 · Read play state and loop mode from the engine, not from mirrors
`P2 · S · Guided` · Finding V-13 (UI-9)

**Do.**
1. Remove `ShellController.playingChannels` (≈L1085, L1326–1334). Read
   `engine.sources[letter]?.isPlaying` instead.
2. In `refreshChannelAfterSwap` (≈L1183–1192), set the source panel's `loopMode`
   from the engine's clip.
3. In the preferences `onChange` handler, update the three library AUTO keys when
   play-on-load changes (PreferencePanes ≈L266, ShellController ≈L511–514).
4. Let the MIDI-learn prompt own the status-bar MIDI field until the learn ends
   (≈L920, L3936).

**Done when.** After auto-play on load, the first ▶ press pauses.

---

### W-39 · "Recorded N files" becomes a notice, not a modal alert
`P2 · S · Mechanical` · Finding UI-13

**Where.** `ShellController.presentRecordingFinished` (≈L612–644), which uses
`alert.runModal()`.

**Do.** Replace the alert with `presentNotice(_:_:)` (≈L1356). If the notice can't
take an action, log the folder path and put "Show in Finder" in the File menu, using
the most recent recording folder.

---

### W-40 · Redraw only on change
`P2 · S · Mechanical` · Finding UI-10

**Do.**
1. In `VBFader`, guard the driven value (≈L78) and `isDetectHighlighted` (≈L63)
   with `guard newValue != oldValue` before setting `needsDisplay`. `VBOptionButton`
   already does this; copy its pattern.
2. Do the same for the armed-state setter in `MiniRecordIndicator` (≈L33).

---

### W-41 · ⌘Z updates values in place instead of rebuilding both FX panels
`P2 · S · Guided` · Finding UI-11

**Where.** The undo/redo apply path (ShellController ≈L1765) goes
`repaintFromRegistry` → `refreshCards` → `setEffects` → `rebuild()`.

**Do.** When an undo changes values only (no chain change), update each affected
fader in place, using the same lookup `showTargetedCopy` uses. Rebuild only if the
chain itself changed.

---

### W-42 · Cache DATA BURN's font and drawing context
`P2 · S · Mechanical` · Finding BS-14

**Where.** `Core/Sources/VideoboyCore/Scopes/DataBurn.swift` (≈L228–270), called
from `ScopeOverlayNode` (≈L183–188).

**Do.**
1. Cache the `CTFont`, its bold copy and the colour space in a small dictionary
   keyed by `(style, fontSize)`. Keep it on the overlay node, not global.
2. Reuse one `CGContext` and pixel buffer per `(width, height)`.

**Done when.** `selfqa stress` with burn on has a p95 within 1 ms of burn off. The
09-28 audit measured 9.8 ms with burn on against 6.6 ms off.

---

### W-43 · Small frame-path hygiene bundle
`P3 · S · Mechanical` · Findings FP-7, FP-13, FP-14

1. **`ImageBuffer.fromBGRA`** (`Core/Sources/VideoboyCore/SelfQA/ImageBuffer.swift`
   ≈L139): replace the per-pixel `swapAt` loop with
   `vImagePermuteChannels_ARGB8888`, permute map `[2, 1, 0, 3]`.
2. **`RenderGraph.evaluationOrder` / `inputs(of:)`** (≈L80–115): cache both behind a
   `version` counter, bumped on add, remove, connect and disconnect.
3. **`CrossfadeNode`** (≈L255) and **`MetalPreviewView`** (≈L702, L747): commit
   through `metal.submit(_:label:)`, so GPU errors are logged and
   `VIDEOBOY_SYNC_EVERY_PASS` covers them.

Do these as three separate commits.

---

### W-44 · The learn keys leave text fields alone
`P3 · S · Mechanical` · Finding UI-17

In `ShellController.handleLearnKey(_:)` (≈L953), return false when the key window's
first responder is an `NSText`, so Backspace in a search field never unmaps the
armed control.

---

### W-45 · Output windows react to a display being unplugged
`P2 · S · Guided` · Finding FP-8

**Do.**
1. Observe `NSApplication.didChangeScreenParametersNotification` in
   `OutputRouter` / `OutputWindowController`.
2. Tear down any route whose display ID has gone.
3. Log it, and show "Output display disconnected: <name>" as a notice.

---

### W-46 · An ejected channel shows black, not the other channel
`P2 · S · Owner decision, then Mechanical` · Finding FP-6

**Why.** `Engine.evaluateGraph` (≈L985) builds a node's inputs with
`compactMap { produced[$0] }`, so a connected input that produced nothing simply
disappears. `CrossfadeNode` (≈L190) then passes the remaining input through:
`guard inputs.count >= 2 else { return inputs.first }`. This happens when the fader
sits fully on A and A is ejected, or is pointed at a camera that hasn't delivered a
frame yet. Channel B then goes to air at 100 %.

**Owner decision.** In that case, should PROGRAM show black (proposed) or the other
channel?

**Do (if black).**
1. In `evaluateGraph`, when an input edge exists but its producer returned nil, pass
   a cached black canvas texture in that position. Create it once per canvas size
   and keep it on the engine.
2. Inputs then always arrive in edge order, as the `Node.render` contract states
   (Node.swift ≈L84).

**Verify.** `scripts/selfqa.sh playback` and `scripts/selfqa.sh ab-roll`, plus
`stress` (frame-path rule).

---

## Part G — Quality gates and hermetic tests

### W-47 · Self-QA: "blocked" means only an environmental cause; add a strict mode
`P1 · M · Guided` · Finding V-09 (QA-1)

**Why.**
- `SelfQARunner` returns 0 for blocked (≈L116).
- 106 `finish(blockedReason:)` sites include real product defects, for example:
  - "the Datamosh card's switch is not in the A/B FX panel";
  - "the display link did not tick";
  - "Import mode did not build its view".

**Do.**
1. In `Core/Sources/VideoboyCore/SelfQA/SelfQACheck.swift`, add:
   ```swift
   public enum BlockedReason: Sendable {
       case noMetalDevice, noScreen
       case missingHardware(String), missingPermission(String), missingFixture(String)
   }
   ```
2. Replace `finish(blockedReason: String?)` with `finish(blocked: BlockedReason?)`.
3. Go through the 106 call sites, one file per commit.
   - **Environmental cause:** map it to an enum case.
   - **Product condition:** record a failed `AssertionResult` with that text and
     call `finish()`.
   - **Feature flag off:** the check fails.
4. In `SelfQARunner`, when `VIDEOBOY_STRICT=1`, exit 3 on blocked.
5. In `scripts/verify.sh`, export `VIDEOBOY_STRICT=1` for the checks that need no
   hardware.

**Done when.** `grep -rn "finish(blockedReason" App Core` returns nothing, and every
blocked reason left is environmental.

---

### W-48 · Core GPU tests fail when Metal setup fails
`P1 · S · Mechanical` · Finding V-09 (QA-2)

**Why.** `MetalContext.shared` is nil if any one of 12 pipelines fails to compile
(MetalContext.swift ≈L1215–1236). Every GPU test then skips with "no Metal device",
and `swift test` exits 0.

**Do.**
1. Record why setup failed: add
   `public private(set) static var setupFailure: String?`, set it inside `init`
   before each `return nil`.
2. Add `Core/Tests/VideoboyCoreTests/MetalTestSupport.swift` with
   `func requireMetal(file:line:) throws -> MetalContext`:
   - **Device exists, but `shared` is nil:** `XCTFail` with `setupFailure`, then
     throw.
   - **No device at all:** throw `XCTSkip`.
3. Replace each `guard let metal = MetalContext.shared else { throw XCTSkip(...) }`
   with `try requireMetal()`.
4. Add `testEveryPipelineCompiles`.
5. Convert the skips that describe defects into `XCTFail`. These are "render
   failed" (13), "could not upload…" (15) and "…produced nothing" (≥2); find them
   with grep.

---

### W-49 · Restore the deleted regression tests; add a test-inventory ratchet
`P1 · S · Mechanical` · Finding V-09 (QA-8)

**Do.**
1. Restore `testPlayingBackwardsDoesNotRestartTheReaderEveryFrame` and
   `testHEVCTaggedHev1Plays` into
   `Core/Tests/VideoboyCoreTests/AVFClipDecoderTests.swift`.
   - Commit `ad14e29` deleted them. Get them with `git show ad14e29 -- Core/Tests/VideoboyCoreTests/AVFClipDecoderTests.swift`.
   - Adapt them to the post-DV API.
   - The `samples/motion-hev1.mov` fixture is still produced by `make-fixtures.sh`.
2. Add `scripts/test-inventory.sh`. It runs `swift test list`, sorts the output and
   diffs it against `docs/test-inventory.txt`, exiting non-zero if a test vanished.
3. Call it from `scripts/verify.sh`. Removing a test now means updating the
   inventory in the same commit.

---

### W-50 · Fix the stale canvas assertion in `selfqa modes`
`P2 · S · Mechanical` · Finding V-09

**Why.** `ModeBarSelfQA` (≈L296–305) requires every canvas after SD NTSC to be
disabled. Vertical has been available since `8312731` (2026-10-02), so the check can
no longer pass.

**Do.**
1. Build the expected enabled states from `ProjectCanvas.allCases.map(\.isAvailable)`
   and compare them, in order, with the pop-up items' `isEnabled`.
2. Rename the assertion to "Project: SD NTSC selected; only built canvases enabled".

---

### W-51 · Self-QA never touches the performer's settings
`P1 · M · Guided` · Finding V-10 (QA-6, DL-10, UI-16)

**Why.**
- 29 checks construct `ShellController(shell:engine:)` and get its default
  `PreferenceStore()`, which is the real
  `~/Library/Application Support/Videoboy/preferences.json`.
- `Engine()` scans the real ISF folders.
- `setFrameAutosaveName` writes window frames into the real defaults.
- `midi.start()` connects every physical device.

**Do.**
1. Remove these default arguments:
   - `ShellController.init(…, preferences: PreferenceStore = PreferenceStore())` (≈L53);
   - `MainWindowController.init(preferences:engine: Engine = Engine())` (≈L83);
   - `Engine.init(catalog: ModuleCatalog = ModuleCatalog(), …)` (≈L210).
   Then pass explicit values at every call site; the compiler lists them.
2. Add `App/Sources/Videoboy/Platform/SelfQASandbox.swift`. It provides:
   - a temp root;
   - `PreferenceStore(fileURL: <temp>/preferences.json)`;
   - a `ModuleCatalog` that sees built-in ISF modules only;
   - `isActive`.
   Every check uses it.
3. When `SelfQASandbox.isActive`:
   - skip `setFrameAutosaveName` (MainWindowController ≈L127);
   - skip split-view autosave (ImportModeView ≈L152).
4. Add an Engine option to connect only virtual MIDI sources. Self-QA uses it.

**Done when.** Make the real preferences file read-only (`chmod 444`) and run
`selfqa ui`. No write attempt is logged, and
`defaults read <bundle id> NSWindow\ Frame\ VideoboyMainWindow` is unchanged.

---

### W-52 · CI lane for headless checks
`P1 · M · Guided` · Finding V-09 (QA-3)

**Owner decision.** GitHub-hosted macOS runner (costs minutes) or a self-hosted
runner on the Mac Studio?

**Do (hosted).**
1. Add `.github/workflows/core.yml`:
   - `runs-on: macos-15`;
   - cache `vendor/ffmpeg`, keyed on the hash of `scripts/build-ffmpeg.sh`;
   - run `scripts/bootstrap.sh`, `scripts/test.sh`, `scripts/build.sh release` and
     `scripts/lint.sh`.
2. As the first step, log `MTLCreateSystemDefaultDevice()?.name`. It is unverified
   whether hosted runners expose a Metal device.
3. Run on every push and pull request.

**Done when.** A deliberately failing test turns the run red, and reverting it turns
it green.

---

### W-53 · Accessibility identifiers in one registry; custom controls exposed to accessibility
`P2 · M · Guided` · Finding M-09

**Do.**
1. Add `App/Sources/Videoboy/UI/AXID.swift`. It is the one place that builds
   identifiers, e.g. `static func cut(bus: String) -> NSUserInterfaceItemIdentifier`.
   - Identifiers are unique per instance: include the bus or channel.
   - Data (e.g. `"autoplay|A"`, the queue-limit list in PreferencePanes ≈L169) moves
     out of identifiers into properties.
2. Implement `NSAccessibility` on the custom controls:
   - `VBFader`: role `.slider`, value, increment and decrement.
   - `VBOptionButton`, `VBTransportButton`, `VBBusButton`, `VBStepButton`,
     `RecordButton`, `SeamSwapKey`: role `.button`, press action, label.
   - `VBSwitch`, `VBSlideToggle`: role `.checkBox`, value.
3. Add a `UISelfQA` assertion: every control in the `AuditableControl` registry has a
   unique identifier and an accessibility role.

**Done when.** Accessibility Inspector shows the role and label of a CUT key and a
fader.

---

### W-54 · Keep durations out of functional assertions; wait on conditions
`P2 · M · Guided` · Finding QA-5

**Do.**
1. Add `SelfQAWait.until(_ condition: () -> Bool, timeout: TimeInterval, pollEvery: TimeInterval = 0.01) -> Bool`.
   It runs the run loop between polls.
2. Replace fixed `RunLoop.main.run(until: Date().addingTimeInterval(…))` waits with
   it, where a condition exists. Start with UISelfQA, PadsSelfQA and ImportSelfQA.
3. Split any assertion that mixes behaviour and timing (UISelfQA ≈L396 and ≈L1501;
   PadsSelfQA ≈L151) into two:
   - a behaviour assertion, which counts toward the verdict;
   - a timing metric written to `metrics.json` and reported, not gated. Gating
     moves to a later perf lane.

---

## Part H — Docs and the module template

### W-55 · Fix the copy-me module template and the module guide
`P2 · S · Mechanical` · Finding FP-10, BS-13

**Do.**
1. In `Core/Sources/VideoboyCore/Modules/_Template/ExampleNode.swift`:
   - replace `commandBuffer.commit()` / `waitUntilCompleted()` (≈L119–120) with
     `metal.submit(commandBuffer, label: identifier)`;
   - blend into a separate `blendTarget` instead of into `target` (≈L129). Copy the
     pattern from a production node that does it: `CompositeCodecNode` or
     `FeedbackNode`.
2. Rewrite `docs/ADD-A-MODULE.md` and `Modules/_Template/README.md` around what
   exists:
   - a `Node` plus `ParameterApplying`;
   - an entry in `ModuleCatalog.nativeModules()`.
   There is no manifest file. Remove the DV references and the dead 33B example.

---

### W-56 · Refresh the stale project docs
`P3 · S · Mechanical` · Finding M-07

1. **`docs/STATUS.md`:** it says 192 tests, ISF "not started", "no encoder", and
   has DV rows. Either rewrite it from `BUILD-PLAN.md` and
   `FEATURE-LEDGER-2026-09-27.md`, or replace it with a pointer and mark it
   superseded.
2. **`docs/ARCHITECTURE.md`:**
   - remove the DV signal path;
   - say the render clock is `NSScreen.displayLink` on the main run loop, not
     `CVDisplayLink`;
   - add the thread map from the audit report.
3. **`App/Sources/Videoboy/main.swift`:** the `usage` text lists only three checks.
   Point it at `scripts/selfqa.sh` instead.
4. **`Core/Sources/CFFmpeg/include/CFFmpeg.h`:** the header comment mentions
   `DVDecoder`; fix it.

---

## Part I — Swift 6 preparation, the mechanical steps

### W-57 · Measure strict-concurrency diagnostics (don't commit the flag)
`P2 · S · Mechanical`

**Do.**
1. On a scratch branch, add `.enableUpcomingFeature("StrictConcurrency")` to every
   target's `swiftSettings` in `Core/Package.swift` and `App/Package.swift`. If
   SwiftPM rejects it, use `-strict-concurrency=complete`.
2. Build with `scripts/build.sh debug`.
3. Record the diagnostic count per file and per category in `docs/SWIFT6-BASELINE.md`.
4. Commit only that document. `lint.sh` fails on warnings, so the flag itself stays
   on the scratch branch.

---

### W-58 · `Sendable` on value types that cross threads
`P3 · S · Mechanical`

Add `Sendable` to each of these types where the compiler accepts it without
`@unchecked`:
- `ControlEvent`, `Parameter`, `ScheduledEvent`, `LFOBank.Assignment`,
  `ReactivityAssignment`;
- `ImageBuffer`, `RenderContext`, `MusicalPosition`;
- `SeededRandom`, `MPEGCorruptionSettings`, `CorruptionSettings`;
- `BeatNetTensor`.

If one needs `@unchecked`, leave it and note it in the commit.

---

### W-59 · Write down the confinement that already exists
`P3 · S · Mechanical`

1. Mark these queue- or lock-confined classes `@unchecked Sendable`, each with a
   one-line comment above the declaration saying which queue or lock owns its state:
   - `ClipPrefetcher`, `ISFCompiler`, `ClipThumbnails`, `H264LiveEncoder`,
     `LockedValue`, `Catalog`;
   - `CaptureSourceNode`, after W-16.
2. Mark `CanvasGeometry.project` `nonisolated(unsafe)` with the comment "set once at
   launch, before any window or engine exists".
3. Replace `Log`'s `NSLock` and ring with `OSAllocatedUnfairLock<Ring>` (macOS 13+).

---

### W-60 · One helper for hopping to the main thread
`P3 · S · Guided`

**Why.** Three mechanisms are in use: `DispatchQueue.main.async`,
`RunLoop.main.perform` and `CFRunLoopPerformBlock`.

**Do.**
1. Add `MainHop.perform(_ block: @escaping () -> Void)`, which wraps
   `CFRunLoopPerformBlock` in common modes plus `CFRunLoopWakeUp`. Document why
   common modes matter: it runs during tracking and modal loops.
2. Replace the `CFRunLoopPerformBlock` call sites and the `RunLoop.main.perform`
   call sites with it.
3. Leave `DispatchQueue.main.async` where it is ordered against other GCD work.

---

## Part J — Structural work, step by step

These change the shape of the code. Each one is Design-first unless marked
otherwise. Once its design note is approved, each is delegable as written.

### W-61 · Extract `ContentFramePacer` to Core, with tests
`P1 · S · Mechanical` · Finding M-02

**Why.** `Engine.contentFrameDue(at:refresh:)` (≈L860–871) and the dropped-frame
rule in `renderTick` (≈L899–905) are pure. They enforce the most important invariant
in CLAUDE.md, and nothing tests them.

**Do.**
1. Add `Core/Sources/VideoboyCore/Render/ContentFramePacer.swift`:
   ```swift
   public struct ContentFramePacer {
       public mutating func isFrameDue(at now: Double, refresh: Double) -> Bool
   }
   public struct DroppedFrameCounter { … }
   ```
   Keep the same logic and constants.
2. `Engine` uses both.
3. Add tests that simulate 10,000 ticks at 60, 120, 144 and 50 Hz:
   - the renders average 29.97/s, within one frame per minute;
   - after a 1 s stall, the pacer resyncs and does not render a burst;
   - ±0.5 ms timestamp jitter never skips a due frame.

---

### W-62 · Every node that applies parameters conforms to `ParameterApplying`
`P2 · S · Mechanical` · Findings FP-12, BS-11

**Why.** `Engine.applyAllParameters` (≈L953–966) is a hand-kept list, and nodes have
fallen off it:
- the emulated titler (audit item L3 is still open);
- capture nodes, whose opacity, contrast and saturation are mappable but never
  applied;
- the test pattern.

Several node types implement `applyParameters(from:)` without declaring the
protocol: `ClipSourceNode`, `CrossfadeNode`, `GeneratorSourceNode`,
`EmulatedTitlerNode`, `ScopeOverlayNode`, `ColourControlNode`, `EchoNode`,
`TransformNode` and `CharacterGeneratorNode`.

**Do.**
1. Add `ParameterApplying` to each of those types.
2. For `CaptureSourceNode`, add `applyParameters(from:)` for its registered codes,
   copying the pattern `ClipSourceNode` uses.
3. Replace the list with
   `for node in graph.nodes.values { (node as? ParameterApplying)?.applyParameters(from: registry) }`.
4. Keep the order-sensitive ones ahead of the loop if order matters. Check sources
   before mixers.

**Verify.** `scripts/selfqa.sh stress` (frame-path rule), `selfqa ui`, and
`selfqa audit` (the five titler faders should now pass where FS-UAE is present).

---

### W-63 · Split the App package: library, thin executable, tests
`P1 · M · Design-first (build graph)` · Finding M-02

**Do.**
1. Move `App/Sources/Videoboy/*` except `main.swift` to
   `App/Sources/VideoboyApp/`.
2. In `App/Package.swift`:
   - `.target(name: "VideoboyApp", dependencies: [VideoboyCore])`;
   - `.executableTarget(name: "Videoboy", dependencies: ["VideoboyApp"])`, holding
     `main.swift` only;
   - `.testTarget(name: "VideoboyAppTests", dependencies: ["VideoboyApp"])`.
3. `main.swift` calls one public entry point, `VideoboyApp.run(arguments:)`.
4. Keep the product name `Videoboy`, so `scripts/build.sh`'s `BINARY` path still
   works. Check that it does.
5. Add `App/` tests to `scripts/test.sh`.
6. Add the first `VideoboyAppTests` file: a smoke test that builds a
   `MainWindowController` with a sandboxed store (W-51) and finds the 5×5 grid.

---

### W-64 · `FrameTick` and a `RenderTicker` seam
`P2 · M · Design-first` · depends on W-61

**Do.**
1. Add `struct FrameTick { let timestamp: Double; let targetTimestamp: Double }`.
2. Change `Engine.renderTick(_ link: CADisplayLink)` to `renderTick(_ tick: FrameTick)`.
3. Add `protocol RenderTicker { func start(_ onTick: @escaping (FrameTick) -> Void); func stop() }`,
   with two implementations:
   - `DisplayLinkTicker`, which wraps today's `NSScreen.displayLink` code;
   - `ManualTicker`, for tests.
4. `Engine` takes a ticker in its initializer.

Push-fade curves, pacing and automation sampling then become deterministic unit
tests.

---

### W-65 · Move `LibraryModel`, `ImportJob` and `OptimizeQueue` to Core, with tests
`P2 · M · Design-first` · Finding M-02

**Why.** `LibraryModel` uses AppKit only for `NSImage`. `ImportJob` uses only
`NSLock`. `OptimizeQueue` uses no AppKit.

**Do.**
1. Change `LibraryItem`'s poster to `CGImage`. Keep an `NSImage` cache in the view
   layer.
2. Move the three types to `Core/Sources/VideoboyCore/Library/`.
3. Add tests:
   - write-through to a scratch `Catalog`;
   - batch apply;
   - cancellation between files;
   - duplicate detection;
   - the queue's process launch, behind a protocol.

---

### W-66 · An `AppEnvironment` composition root; models move out of views
`P2 · M · Design-first` · Finding M-03 · depends on W-51

**Do.**
1. Add `struct AppEnvironment`, built in `main.swift` as `.live` or as
   `.selfQA(sandbox)`. It holds:
   - the preferences store, the catalog URL, the module folders;
   - the feature flags, the MIDI policy, the ticker;
   - the show writer.
2. Pass it down: AppDelegate → MainWindowController → Engine and ShellController.
3. `PanelSet` stops creating `LibraryModel` (≈L178) and `EmulatorController`
   (≈L188); they are injected.
4. Replace `shell.shell.grid.panels…` reach-through with explicit references.

---

### W-67 · Break up `ShellController`, one feature per pull request
`P1 · L · Design-first` · Finding M-01

`ShellController` is 3,965 lines, has about 28 responsibilities, and was touched by
26 of 60 commits.

Extract in the order below. Each step:
- moves the rules into Core with unit tests;
- leaves a thin App adapter;
- changes no behaviour;
- runs every self-QA check for that feature.

| Step | New type | Lives in | Takes over |
|---|---|---|---|
| 67a | `TakeScheduler` | Core | `activeFades`, `pendingCuts`, `beatCutEnabled`, `beginMove`, `updateFadesAndCuts`, `takeStarted`, `takeLanded` |
| 67b | `AdvancePlanner` | Core | `rollOn`, `advanceOn`, pickers, `advancePlans`, `planAdvance`, `settleOutgoing`, `pickNext`, `isStillValid`. Returns actions instead of calling views |
| 67c | `ChannelDeck` | Core | queues, `queueLimit`, `queueAdvance`, play state, `autoPlayByChannel`, `togglePlayback`. The one source of truth for playback (removes W-38's class of bug) |
| 67d | `SweepBank`, `BeatFlipBank` | Core | fader sweeps, automated buttons, pad beat-arming |
| 67e | `ShowDocumentController` | App | capture, save, open, new, `restoreQueues`, auto-save, recents, dirty tracking; uses `ShowWriter` |
| 67f | `MIDILearnController` | App | `pendingLearn`, learn keys, `refreshDrivenParameters`, mapping removal, badges |
| 67g | `EffectCardModelBuilder` | Core | `makeCards`, `makeSourceCard`, `parameterModels`, add-menu groups, `cardInstances`, `slot(forEffect:)` |
| 67h | `ScopeBurnController`, `OutputController`, `RecordingController`, `ImportCoordinator` | App | the rest |

**Done when.** `ShellController` is under 800 lines, and every rule it used to hold
has Core tests.

---

### W-68 · One show-state model with a single writer
`P2 · L · Design-first` · Finding V-13 · after W-67c/d

Extend the pattern the parameter registry already follows: one store, one writer,
views repainted from it.
1. Add a `ShowState` value type covering playback, queues, pads, sweeps, locks and
   the current file.
2. Changes arrive as intents and are applied in one place.
3. The undo history records intents. This gives library undo (W-23) a home.
4. Recovery snapshots (W-08) serialise `ShowState` directly.

---

## Part K — Architect-led work (not for piecemeal delegation)

Listed here so they aren't attempted as drive-by fixes. Each needs a design reviewed
by the owner, and a measurement plan, before any code.

| # | Item | Findings |
|---|---|---|
| X-1 | MPEG decoder v2. Build an I-frame byte-offset index at open and restart at the nearest earlier I-frame, never at 0. Coalesce damage changes. Cache the damaged length for each damage setting. Count frames, not fields. Add 2-minute `.m2v` fixtures and a test that sweeps damage late in a clip. **Gate for turning the corruptor back on.** | V-04 · FP-2, BS-1, BS-2 |
| X-2 | Replace the per-frame CPU fence (`MetalContext.waitForIdle`) with `MTLSharedEvent` slot reuse and a third uploader slot. Give each ISF node a GPU-time budget that auto-bypasses on overrun. | V-05 · FP-9, BS-4 |
| X-3 | While PROGRAM is routed, clock the engine from the output display. Verify with a DVC100 loopback of at least 2 minutes of a moving wipe at 720×480 @ 59.94. | V-11 · FP-4 |
| X-4 | Move device and session work onto serial queues with async completion: camera `startRunning`, `AVAudioEngine` start/stop, process taps, permission requests made ahead of time, and output display mode switches. | V-05 · UI-1, CC-4, FP-8 |
| X-5 | Real-time audio: copy from the HAL I/O block into a preallocated SPSC ring. No allocation, lock or dispatch on that thread. | V-15 · CC-6 |
| X-6 | Take recording and streaming off the tick: blit, then a completed handler, then a `CVPixelBuffer` handed to a writer queue. Stream encoding gets its own queue with frame dropping and slice threads. | V-05 · FP-7, BS-9 |
| X-7 | Decode-miss waits in two phases: post every urgent request first, then wait on one shared 5 ms deadline. | V-05 · FP-5 |
| X-8 | Self-QA v2: run under a real `NSApp.run()`, add a scenario registry with a fresh shell per scenario, JUnit output and image baselines with tolerance. Add a black-box AX/CGEvent smoke driver for about 10 journeys on the real `.app`. | V-09 · QA-4, QA-9, QA-10 |
| X-9 | Flip Core, then App, to Swift 6 language mode, after W-57 to W-60, with the `@MainActor` annotations on `Engine`, `ShellController`, the registry and the transport. | M-06 |
| X-10 | Decide, by measurement after X-2, X-4 and X-6, whether graph evaluation should leave the main thread. Main-thread confinement is what keeps the app race-free today; don't trade it away without X-9 in place. | V-05 |
