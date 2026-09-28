#!/usr/bin/env python3
#
# beat-eval.py — score the beat trackers against reference beats.
#
# Purpose : Reads the CSVs BeatNetEvaluationTests writes (one per clip) and a
#           reference JSON of true beat times per clip, and prints, per tracker:
#           how soon it locked, how much of the time it stayed locked, how far its
#           tempo was off and how much it wandered, and how far its beats landed
#           from the real ones. See docs/BEATNET.md for how to make the reference.
# Inputs  : argv[1] reference JSON {clip path: {"beats": [...]}}; argv[2] CSV folder.
# Outputs : a table on stdout. Standard library only.
#
# Scoring rules:
#  - Everything is measured from 10 s in, once any tracker has had time to settle.
#  - Double or half the reference tempo counts as the same pulse (a performer can
#    live with a clock at half time; a clock at 4/3 is wrong). Phase is then scored
#    against the reference beats at the tracker's own rate.
#  - "on frame" = a predicted beat within 33 ms of a real one: the same video frame.

import csv, json, os, statistics, sys

SETTLE = 10.0
FRAME = 0.0334


def fit_bpm(beats):
    n = len(beats)
    xs = list(range(n))
    mx, my = sum(xs) / n, sum(beats) / n
    slope = sum((x - mx) * (y - my) for x, y in zip(xs, beats)) / sum((x - mx) ** 2 for x in xs)
    return 60 / slope


def grid_at_rate(beats, ratio):
    """Reference beats resampled to `ratio` × their rate (2 inserts midpoints)."""
    if ratio == 1:
        return beats
    if ratio == 2:
        out = []
        for a, b in zip(beats, beats[1:]):
            out += [a, (a + b) / 2]
        return out + beats[-1:]
    return beats  # half time: every real beat is still a candidate


def main():
    reference = json.load(open(sys.argv[1]))
    folder = sys.argv[2]
    rows = []
    for wav, info in reference.items():
        name = os.path.splitext(os.path.basename(wav))[0]
        path = os.path.join(folder, name + '.csv')
        if not os.path.exists(path):
            continue
        beats = info['beats']
        ref_bpm = fit_bpm(beats)
        reports = list(csv.DictReader(open(path)))
        for tracker in ('old', 'beatnet', 'hybrid'):
            mine = [r for r in reports if r['tracker'] == tracker]
            settled = [r for r in mine if float(r['time']) >= SETTLE]
            locked = [r for r in settled if r['state'] == 'locked' and r['bpm']]
            first = next((float(r['time']) for r in mine if r['state'] == 'locked'), None)
            row = {'clip': name[:28], 'tracker': tracker, 'ref': ref_bpm,
                   'first': first, 'locked': len(locked) / max(len(settled), 1)}
            if locked:
                bpms = [float(r['bpm']) for r in locked]
                mean = statistics.fmean(bpms)
                ratio = min((1, 2, 0.5), key=lambda k: abs(mean - ref_bpm * k))
                row['bpm'] = mean
                row['ratio'] = ratio
                row['bpm_err'] = abs(mean - ref_bpm * ratio)
                row['bpm_sd'] = statistics.pstdev(bpms)
                grid = grid_at_rate(beats, ratio)
                errors = []
                for r in locked:
                    if not r['beat']:
                        continue
                    b = float(r['beat'])
                    errors.append(min((b - g for g in grid), key=abs))
                if errors:
                    row['phase_med'] = statistics.median(abs(e) for e in errors) * 1000
                    row['phase_bias'] = statistics.median(errors) * 1000
                    row['on_frame'] = sum(abs(e) <= FRAME for e in errors) / len(errors)
            rows.append(row)

    def f(v, fmt):
        return format(v, fmt) if isinstance(v, (int, float)) else '—'
    print(f"{'clip':28} {'tracker':8} {'ref':>6} {'bpm':>7} {'x':>3} {'err':>5} {'wander':>6} "
          f"{'1st lock':>8} {'locked':>6} {'|phase|':>7} {'bias':>6} {'on frame':>8}")
    for r in rows:
        print(f"{r['clip']:28} {r['tracker']:8} {f(r['ref'], '6.1f')} {f(r.get('bpm'), '7.2f')} "
              f"{f(r.get('ratio'), '3g')} {f(r.get('bpm_err'), '5.2f')} {f(r.get('bpm_sd'), '6.2f')} "
              f"{f(r['first'], '7.1f')}s {f(r['locked'] * 100, '5.0f')}% "
              f"{f(r.get('phase_med'), '5.0f')}ms {f(r.get('phase_bias'), '4.0f')}ms "
              f"{f(r.get('on_frame', 0) * 100 if 'on_frame' in r else None, '7.0f')}%")
    for tracker in ('old', 'beatnet', 'hybrid'):
        mine = [r for r in rows if r['tracker'] == tracker]
        on = [r.get('on_frame', 0) for r in mine]
        lk = [r['locked'] for r in mine]
        if mine:
            print(f"{tracker:8} mean: locked {statistics.fmean(lk) * 100:.0f}%, "
                  f"beats on the right frame {statistics.fmean(on) * 100:.0f}%")


if __name__ == '__main__':
    main()
