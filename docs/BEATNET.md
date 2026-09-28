# BeatNet in Videoboy

Beat detection listens with BeatNet's trained network (Heydari, Cwitkowitz & Duan,
ISMIR 2021; CC BY 4.0 — credit in `THIRD-PARTY.md`). Added 2026-09-27 after the
owner reported that audio beat lock "never seems tight" and asked for a proven
engine rather than a home-made one.

## What runs

```
device audio (44.1/48 kHz)
  → StreamingResampler      22,050 Hz, windowed sinc, no timing offset
  → BeatNetFeatures         272 values per 20 ms frame (madmom's log spectrogram + diff)
  → BeatNetModel            conv → linear → 2×LSTM(150) → softmax: P(beat), P(downbeat)
  → BeatTracker             the app's autocorrelation tempo + phase tracker, fed the
                            activation instead of the onset envelope (mode .activationTempo)
  → BeatTrackerReport       → Engine.applyBeatReport, unchanged
```

All in `Core/Sources/VideoboyCore/Audio/BeatNet/`. No Python and no new dependency;
the weights are one 2 MB file, `App/Resources/BeatNet/beatnet-model1.bin`, copied into
the bundle by `scripts/build.sh`. Cost: ~1.7% of one core (120 s of audio in 2 s,
release build), on the audio analysis queue — never the render path.

`VIDEOBOY_LEGACY_BEAT=1` switches back to the older onset tracker. If the weights
file is missing or damaged, the app logs why (`[clock]`) and uses the older tracker.

## Is the port faithful?

`BeatNetTests` holds it to BeatNet's own Python on the same signal:

| stage | agreement |
|---|---|
| features (vs madmom) | within 1e-3 on sampled frames (1e-7 in float64 checks) |
| activations, all 600 frames (vs PyTorch) | within 2e-3 |
| particle filter (vs BeatNet's `particle_filter_cascade`) | beat F-measure within 0.01–0.06 on six real tracks |

## Why not BeatNet's own particle filter?

Scored on six real tracks (first 120 s each, the owner's own files — never committed),
against madmom's offline beat tracker as reference. "On frame" = the predicted beat
within 33 ms of a real one, i.e. on the right video frame at 29.97.

| tracker | time locked (after 10 s) | beats on the right frame |
|---|---|---|
| old onset tracker | 88% | 69% |
| BeatNet particle filter + beat-grid fit | 57% | 66% |
| **BeatNet activations → tempo tracker (shipped)** | **88%** | **78%** |

BeatNet's causal particle filter is not much better than the old tracker on real
music (its published real-time F-measure is ~0.75–0.80, and that is what it scored
here). What BeatNet is genuinely good at is *hearing* a beat; the old tracker's
autocorrelation is good at *holding* one. The shipped mode combines those.

Per track, beats on the right frame, old → new: Cereal Killa 34 → 40%, Joy Crookes
51 → 79%, Los Bitchos 83 → 89%, Electioneering 84 → 85%, Karma Police 86 → 92%,
Herbie 79 → 85%.

Tuning chosen by the same scoring: the first lock waits for eight agreeing estimates
(2 s) at confidence ≥ 0.25 (`BeatNetTracker.activationTempoTuning`). The network's
peak leads the beat by one 20 ms frame (measured on a signal with known beat times);
`activationLeadSeconds` corrects it.

## Known limits

- **3:2 first locks.** On some tracks the first seconds look like 2/3 or 3/2 of the
  tempo; the lock is corrected by the relock rule, but that takes ~15–25 s.
- **Swung lo-fi** (Cereal Killa) is poor for every tracker tried, and the reference
  itself may be wrong there.
- **Downbeats** — the network outputs them, but nothing uses them yet ("which beat is
  one").
- **Screen latency** is still uncompensated; see BUILD-PLAN backlog.

## Re-running the scores

Needs a Python 3.10 environment with `numpy<2 cython scipy torch soundfile librosa`
and madmom from git (`pip install --no-build-isolation git+https://github.com/CPJKU/madmom`).

1. Reference beats: run madmom's `RNNBeatProcessor` + `DBNBeatTrackingProcessor` over
   each clip (mono WAV) and write `{clip path: {"beats": [...]}}` to a JSON file.
   (madmom's models are CC BY-NC-SA: fine for scoring on a developer machine, never
   shipped.)
2. Run both trackers over the clips:
   ```
   VIDEOBOY_BEAT_EVAL_CLIPS="a.wav:b.wav" VIDEOBOY_BEAT_EVAL_OUT=/tmp/beat-eval \
     scripts/test.sh -c release -Xswiftc -enable-testing --filter BeatNetEvaluationTests
   ```
   `VIDEOBOY_HYBRID_TUNING="lock=8,conf=0.25,stick=0.8,relock=8"` tries other settings.
3. Score: `scripts/beat-eval.py reference.json /tmp/beat-eval`.

## Rebuilding the weights file

`scripts/beatnet-export.py path/to/BeatNet` (a clone of github.com/mjhydri/BeatNet)
writes `beatnet-model1.bin` and `beatnet-reference.json`. Copy them to
`App/Resources/BeatNet/` and `Core/Tests/Fixtures/`, then run `BeatNetTests`.
