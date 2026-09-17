# Now-playing sources — what each one needs

Research for the track-overlay feature, done rather than guessed. The overlay itself
is built and tested against a mock (`NowPlayingSource`); this is about what it takes
to connect each real source.

## Apple Music / iTunes

**Status on this machine: blocked on a permission grant, not on code.**

Probed directly rather than taken from forum posts. Music.app was running and visible
to System Events, but a direct scripting call returned:

```
Music got an error: AppleEvent timed out. (-1712)
```

That is the signature of a pending **Automation** permission (System Settings →
Privacy & Security → Automation → Videoboy → Music), which cannot be answered while
nobody is at the machine. The bundle will also need `NSAppleEventsUsageDescription`
in its Info.plist, or the prompt never appears at all.

Two further findings worth knowing before committing to an approach:

- **ScriptingBridge/AppleScript for Music is reported broken on macOS 26 (Tahoe)** —
  AppleScript, Shortcuts, AppleEvents and ScriptingBridge all affected equally. This
  machine is 15.5, so it is a forward-compatibility risk rather than a current one,
  but it means AppleEvents is not a foundation to build only on.
- **MediaRemote can send transport commands but not read track information**, so it
  does not solve this on its own. The `mediaremote-adapter` project exists precisely
  because of that gap.

**Recommendation:** implement the AppleEvents adapter first because it is the
shortest path, keep it behind `NowPlayingSource` so it can be replaced without
touching the overlay, and treat MusicKit as the fallback if Tahoe breaks it.

## Engine DJ (Denon) — StagelinQ

**Status: viable over the network, no permission gate, needs hardware to verify.**

StagelinQ is Denon's network protocol for Engine DJ hardware. It carries a state map
that includes the currently playing track's metadata, fader positions and other live
state — which is exactly what this overlay wants, and rather more than Apple Music
would give.

It answers your question directly: **over the network, not USB.** Devices are
discovered on the local network and then queried, which suits this app well — it is
the same shape as the IP in/out work already in the backlog.

There is no official public SDK, but the protocol has been reimplemented more than
once in the open:

- `chrisle/StageLinq` — a TypeScript/NodeJS implementation.
- `erikrichardlarson/go-stagelinq` — a Go implementation with device discovery and
  state-map access.

Either is a usable reference for a Swift port. The work is a discovery listener plus a
socket client speaking their state-map format, feeding the same `NowPlayingSource`
protocol as everything else.

**Caveat I cannot remove from here:** none of this is verifiable without an Engine DJ
device on the network. I will not claim the adapter works until it has been run
against real hardware.

## Sources

- <https://github.com/chrisle/StageLinq>
- <https://pkg.go.dev/github.com/erikrichardlarson/go-stagelinq>
- <https://community.enginedj.com/t/stagelinq-protocol-api-availability-part-1/27578>
- <https://github.com/ungive/mediaremote-adapter>
- <https://developer.apple.com/forums/thread/801357>
