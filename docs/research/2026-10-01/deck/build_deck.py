#!/usr/bin/env python3
"""Builds the Videoboy market report: deck.html -> Videoboy-Market-Report-2026-10-01.pdf.

Run from this folder:  python3 build_deck.py
It (1) parses ../feature-inventory.md, (2) cross-checks every Videoboy cell in the
comparison matrices against the inventory and stops on any disagreement, (3) writes
deck.html, (4) prints it with headless Chrome, (5) renders PNG previews for review.
"""

import os
import re
import subprocess
import sys
from collections import Counter

import deck_data as D
import deck_slides as S
from deck_style import CSS, BEBAS

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
INV = os.path.join(HERE, "..", "feature-inventory.md")
PDF = os.path.join(HERE, "Videoboy-Market-Report-2026-10-01.pdf")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"


def parse_inventory():
    text = open(INV).read()
    sections, cur = [], None
    for line in text.splitlines():
        m = re.match(r"^## ([A-K])\. (.+)$", line)
        if m:
            cur = (f"{m.group(1)} · {m.group(2)}", [])
            sections.append(cur)
            continue
        m = re.match(r"^\| ([A-K][0-9]+) \| (.+?) \| (✓|◐|⚑|✗) \| (.*) \|$", line)
        if m and cur:
            ev = re.sub(r"`([^`]+)`", r"<code>\1</code>", m.group(4))
            feat = re.sub(r"\*\*(.+?)\*\*", r"\1", m.group(2))
            feat = re.sub(r"`([^`]+)`", r"<code>\1</code>", feat)
            cur[1].append((m.group(1), feat, m.group(3), ev))
    return sections


def check_paths():
    text = open(INV).read()
    paths = sorted(set(p for p in re.findall(r"`([A-Za-z_.][A-Za-z0-9_./*-]*)`", text) if "/" in p))
    missing = []
    for p in paths:
        if p.startswith("feature/"):
            continue  # a branch name
        full = os.path.join(REPO, p)
        if "*" in p:
            import glob
            if not glob.glob(full):
                missing.append(p)
        elif not os.path.exists(full):
            missing.append(p)
    return len(paths), missing


def cross_check(status):
    """Every Videoboy cell must agree with the inventory rows it cites."""
    problems, checked = [], 0
    for g, feat, cells, note, refs in D.LIVE_ROWS:
        v = cells["VB"]
        sts = [status[r] for r in refs]
        if any(r not in status for r in refs):
            problems.append(f"{feat}: cites a missing inventory id {refs}")
            continue
        ok = {
            "Y": "✓" in sts,
            "P": ("◐" in sts) or ("⚑" in sts) or ("✓" in sts and "✗" in sts),
            "N": (not refs) or ("✗" in sts),
        }[v]
        checked += 1
        if not ok:
            problems.append(f"{feat}: VB={v} but inventory says {list(zip(refs, sts))}")
    return checked, problems


SOURCES = [
    ("Videoboy (repo)", ["CLAUDE.md", "docs/SPEC.md", "docs/BUILD-PLAN.md", "docs/PROPOSAL-2026-09-26.md",
                         "docs/PROPOSAL-2026-09-28-setlist.md", "docs/FEATURE-LEDGER-2026-09-27.md", "docs/AUDIT-2026-09-28.md",
                         "docs/THIRD-PARTY.md", "docs/DESIGN-BACKLOG.md", "docs/REQUEST-BACKLOG.md",
                         "docs/research/2026-10-01/feature-inventory.md", "selfqa/out/perf/pads/window.png"]),
    ("Resolume", ["https://www.resolume.com/shop", "https://resolume.com/support", "https://resolume.com/support/en/clips",
                  "https://resolume.com/support/en/video", "https://resolume.com/support/en/layers", "https://resolume.com/support/en/bpm",
                  "https://resolume.com/support/en/avenue-arena-difference", "https://resolume.com/support/en/updates",
                  "https://resolume.com/support/en/sync-with-dj", "https://www.resolume.com/blog/23542",
                  "https://github.com/stoatworks-labs/resolume-scopes", "https://vjacademy.info/learn/resolume-arena-vs-avenue"]),
    ("VDMX", ["https://vdmx.vidvox.net/", "https://www.vidvox.net/?action=versionDetails", "https://vdmx.vidvox.net/tutorials/workspace-inspectors-layers",
              "https://vdmx.vidvox.net/tutorials/ableton-link-in-vdmx", "https://vdmx.vidvox.net/blog/new-vdmx-new-plugins",
              "https://docs.vidvox.net/vdmx/vdmx_plugins"]),
    ("Millumin", ["https://www.millumin.com/v5/", "https://help.millumin.com/docs/general/shortcuts/",
                  "https://help.millumin.com/docs/general/recommendations/", "https://help.millumin.com/?page=20_lab_general/syphon_recorder",
                  "https://forum.millumin.com/discussion/345/bpm-speed-of-clips"]),
    ("QLab", ["https://qlab.app/docs/v5/video/video-cues/", "https://qlab.app/shop/", "https://qlab.app/release-notes/4.0/",
              "https://qlab.app/docs/v5/networking/midi-file-cues/", "https://www.capterra.com/p/146969/QLAB/ *"]),
    ("MadMapper", ["https://docs.madmapper.com/madmapper/6/11.-live-performance-and-control", "https://docs.madmapper.com/madmapper/6/what's-new",
                   "https://cdm.link/madmapper-6-brings-timelines-markers-clips-more/", "https://madmapper.com/madmapper/software"]),
    ("TouchDesigner · Isadora · Synesthesia", ["https://derivative.ca/UserGuide/TouchDesigner_Products", "https://troikatronix.com/isadora/",
              "https://support.troikatronix.com/support/solutions/articles/13000106556-isadora-4-release-notes",
              "https://synesthesia.live/features", "https://synesthesia.live/pricing", "https://app.synesthesia.live/docs/faq/video.html"]),
    ("Other live tools", ["https://hap.video/integrations.html", "https://en.wikipedia.org/wiki/Modul8", "https://imimot.com/blog/farewell-from-coge/",
                          "https://en.wikipedia.org/wiki/Magic_Music_Visuals", "https://www.disguise.one/en/products/designer-starter-vs-pro *",
                          "https://pixera.one/en/software/licenses/ *", "https://www.notch.one/pricing *", "https://www.dataton.com/about/special-offer *"]),
    ("DJ software", ["https://serato.com/dj/pro/pricing", "https://store.serato.com/us/video", "https://support.serato.com/hc/en-us/articles/223365767-Serato-Expansions",
                     "https://serato.com/forum/discussion/1262889", "https://virtualdj.com/products/virtualdj/price.html",
                     "https://virtualdj.com/products/virtualdj/features.html", "https://virtualdj.com/manuals/virtualdj/settings/record.html",
                     "https://rekordbox.com/en/feature/overview/", "https://www.digitaldjtips.com/rekordbox-v7-2-8-adds-4-stem-separation-new-cloud-setup-wizard/",
                     "https://dj.studio/blog/professional-dj-software-price-guide *", "https://www.bhphotovideo.com/lit_files/630695.pdf (CDJ-3000)",
                     "https://www.pioneerdj.com/en/news/2023/djm-a9-4-channel-professional-dj-mixer/",
                     "https://www.thedjrevolution.com/dj-terms/", "https://dj.studio/blog/dj-mixing-terms"]),
    ("DJ ↔ visuals sync", ["https://djworx.com/stagelinq-soundswitch-resolume-denon-djs-visual-trinity/", "https://github.com/Deep-Symmetry/beat-link-trigger",
                           "https://www.edmtunes.com/2026/09/alphatheta-adds-soundswitch-support-to-rekordbox-pro-dj-link/",
                           "https://www.prodjlink.com/help/resolume"]),
    ("Broadcast", ["https://www.fullcompass.com/common/files/83524-ATEMSDIUserGuide.pdf",
                   "https://wwwapps.grassvalley.com/docs/Manuals/switchers/kayenne/071-88-3400_Kayenne_Karrera_Concepts_Manual.pdf",
                   "https://www.blackmagicdesign.com/products/atemmini/editing", "https://www.redsharknews.com/atem-mini-pro-iso-take-your-live-edits-right-into-davinci-resolve",
                   "https://www.vmix.com/software/features.aspx", "https://www.vmix.com/purchase/",
                   "https://www.nyfa.edu/student-resources/the-ultimate-list-of-broadcast-journalism-terms/",
                   "https://www.rundowncreator.com/how-it-works/timing-101/", "https://newslab.org/backtiming-the-day-a-guide-for-producers/",
                   "https://en.wikipedia.org/wiki/Media_Object_Server", "https://www.rossvideo.com/products/automation-and-control/overdrive/",
                   "https://www.manualslib.com/manual/1224276/Evs-Multicam-Lsm.html",
                   "https://chrisryanouellette.gitbook.io/casparcg-html-template-guide/amcp-commands-review",
                   "https://www.videomaker.com/article/f1/17834-how-to-use-a-live-switcher/",
                   "https://www.cengage.com/resource_uploads/static_resources/0495569437/17449/ch10.html"]),
    ("Post and DAW", ["https://www.blackmagicdesign.com/products/davinciresolve/whatsnew", "https://www.redsharknews.com/davinci-resolve-21-nab-2026-photo-page-ai-tools",
                      "https://costbench.com/compare/adobe-premiere-pro-vs-davinci-resolve/ *", "https://www.kylerholland.com/blog/premiere-pro-january-2026-whats-new",
                      "https://community.adobe.com/announcements-727/what-s-new-in-adobe-premiere-26-5-september-2026-1641187",
                      "https://support.apple.com/en-us/109503", "https://tidbits.com/2026/01/15/apple-bundles-pro-apps-into-new-creator-studio-subscription/",
                      "https://www.macrumors.com/2026/01/28/apple-creator-studio-hands-on/", "https://en.wikipedia.org/wiki/Apple_Creator_Studio",
                      "https://support.emerson.edu/hc/en-us/articles/21709364842011-Three-Point-Editing-in-Avid"]),
]


def main():
    sections = parse_inventory()
    status = {rid: st for _, rows in sections for rid, _, st, _ in rows}
    counts = Counter(status.values())
    for k in "✓◐⚑✗":
        counts.setdefault(k, 0)
    n_paths, missing = check_paths()
    checked, problems = cross_check(status)
    print(f"inventory: {len(status)} rows {dict(counts)}; paths {n_paths}, missing {missing}")
    print(f"VB cross-check: {checked} cells checked, {len(problems)} problems")
    for p in problems:
        print("  ✗", p)
    if problems:
        sys.exit("stop: matrix disagrees with the inventory")

    # scoreboard over the live matrix
    comp_cells = sum(1 for _ in D.LIVE_ROWS) * (len(D.LIVE_PRODUCTS) - 1)
    unverified = sum(1 for r in D.LIVE_ROWS for k, v in r[2].items() if k != "VB" and v == "U") + \
        sum(1 for r in D.ADJ_ROWS for k, v in r[1].items() if k != "VB" and v == "U")
    comp_cells += len(D.ADJ_ROWS) * (len(D.ADJ_PRODUCTS) - 1)
    score = []
    for key, name in D.LIVE_PRODUCTS:
        c = Counter(r[2][key] for r in D.LIVE_ROWS)
        score.append(((name if key != "VB" else "Videoboy 0.4.10"), c["Y"], c["P"], c["U"]))
    score.sort(key=lambda r: (-(r[1] + 0.5 * r[2]), r[0]))
    unique = [feat for g, feat, cells, *_ in D.LIVE_ROWS if cells["VB"] == "Y" and
              all(v in ("N", "U", "P") for k, v in cells.items() if k != "VB") and
              sum(1 for k, v in cells.items() if k != "VB" and v == "Y") == 0]

    vb_check = f"({checked} cells, 0 disagreements)"
    stats = {"rows": len(status), "paths": n_paths, "missing": missing, "vbcheck": f"{checked} cells, 0 disagreements",
             "unverified": unverified, "cells": comp_cells}

    # per-category table for the scoreboard, in matrix order
    group_names = []
    for r in D.LIVE_ROWS:
        if r[0] not in group_names:
            group_names.append(r[0])
    groups = [(g, sum(1 for r in D.LIVE_ROWS if r[0] == g)) for g in group_names]
    order = [name for name, *_ in score]
    key_of = {("Videoboy 0.4.10" if k == "VB" else n): k for k, n in D.LIVE_PRODUCTS}
    gcells = []
    for name in order:
        k = key_of[name]
        gcells.append([(sum(1 for r in D.LIVE_ROWS if r[0] == g and r[2][k] == "Y"),
                        sum(1 for r in D.LIVE_ROWS if r[0] == g and r[2][k] == "P")) for g in group_names])
    group_table = (groups, order, gcells)

    # inspector coverage grid, derived from the same matrix rows
    cov_map = [("Media and source settings", "Video files, common codecs"), ("Loops and play modes", "Loop · ping-pong · play once"),
               ("Cue points inside media", "Cue points / hot cues inside a clip"),
               ("Geometry: position, scale, crop", "Per-layer geometry: position, scale, rotate, crop"),
               ("Masks and keys", "Masks and keys"), ("Blend modes", "Blend modes"), ("Keyframes / envelopes", "Keyframes / envelopes"),
               ("Beat-synced playback", "Beat-synced clip playback"), ("Timecode", "Timecode (SMPTE / LTC / MTC)")]
    by_feat = {r[1]: r[2] for r in D.LIVE_ROWS}
    cov_keys = ["VB", "RES", "VDMX", "QLAB", "MIL", "MAD"]
    cov_names = ["Videoboy", "Resolume", "VDMX6", "QLab 5", "Millumin 5", "MadMapper 6"]
    coverage = ([c for c, _ in cov_map], cov_names, [[by_feat[f][k] for k in cov_keys] for _, f in cov_map])
    tiles = [
        ("Features inventoried", f"{len(status)}", f"{counts['✓']} shipped · {counts['◐']} partial · {counts['⚑']} off · {counts['✗']} absent"),
        ("Products compared", "14", "7 live tools + 7 adjacent (DJ, switchers, editors, DAW)"),
        ("Swift", "80k", "lines in 252 files; Core has 867 tests, 0 failures"),
        ("Self-QA checks", "40", "offscreen PNG, analog loopback, virtual MIDI"),
        ("Mean frame at full load", "6.4 ms", "of a 33.4 ms budget (29.97 fps)"),
        ("HD soak, 10 minutes", "0", "dropped frames; memory flat; 0 leaks"),
    ]

    slides = []
    slides.append(S.cover())
    toc_slot = len(slides)
    slides.append(None)  # contents, filled once page numbers are known
    marks = {}
    def mark(name, desc):
        marks[name] = (len(slides) + 1, desc)
    mark("Executive summary", "five findings and the numbers")
    slides.append(S.exec_summary(tiles))
    mark("01 · Videoboy", "what it is, the window, the modes")
    slides += [S.what_it_is(), S.interface_vj(), S.interface_modes()]
    mark("02 · Feature inventory", f"{len(status)} features checked in the code, and the honest list")
    slides += S.inventory_pages(sections, counts)
    slides.append(S.not_built(sections, counts))
    mark("03 · Market", "lanes, who's who, prices, business models, 2026 signals")
    slides += [S.market_map(), S.who_is_who(), S.pricing(), S.business_models(), S.signals()]
    mark("04 · Feature comparison", "live tools, adjacent tools, scoreboard")
    slides += S.matrix_pages(vb_check)
    slides.append(S.matrix_adjacent())
    slides.append(S.scoreboard(score, len(D.LIVE_ROWS), unique, group_table))
    mark("05 · Inspectors and gaps", "what their inspectors show; major and minor gaps")
    slides += [S.inspectors(coverage), S.gaps_major(), S.gaps_minor()]
    mark("06 · Interface", "vs Logic Pro, DaVinci Resolve, Premiere Pro, VDMX")
    slides += [S.interface_compare(), S.interface_matrix(), S.interface_borrow()]
    mark("07 · Broadcast and DJ deep dive", "two worlds, twelve borrowings")
    slides += [S.two_worlds(), S.borrowings()]
    mark("08 · Vocabulary", "Videoboy vs DJ vs broadcast news; false friends")
    slides += [S.vocab_core(), S.vocab_fixes()]
    mark("09 · Roadmap — the owner's", "from the build plan and proposals")
    slides.append(S.roadmap())
    mark("10 · What I would do", "generalist · market and money · live video artist · 90 days")
    slides += [S.me_generalist(), S.me_market(), S.me_artist(), S.me_90days()]
    mark("Appendix", "method, verification, sources")
    slides.append(S.methodology(stats))
    slides.append(S.sources_page(SOURCES))
    slides.append(S.back_cover())
    toc = [(p, n, d) for n, (p, d) in marks.items()]
    slides[toc_slot] = S.contents(toc)

    total = len(slides)
    html = ("<!doctype html><html><head><meta charset='utf-8'><title>Videoboy — Market &amp; Feature Report, October 2026</title>"
            f"<style>{CSS.replace('__BEBAS__', BEBAS)}</style></head><body>" +
            "".join(s.render(i + 1, total) for i, s in enumerate(slides)) + "</body></html>")
    out_html = os.path.join(HERE, "deck.html")
    open(out_html, "w").write(html)
    print(f"wrote deck.html ({total} pages)")

    cmd = [CHROME, "--headless=new", "--disable-gpu", "--no-pdf-header-footer", "--allow-file-access-from-files",
           "--run-all-compositor-stages-before-draw", "--virtual-time-budget=8000",
           f"--print-to-pdf={PDF}", "file://" + out_html]
    subprocess.run(cmd, check=True, capture_output=True)
    print("wrote", PDF, os.path.getsize(PDF), "bytes")

    prev = os.path.join(HERE, "preview")
    os.makedirs(prev, exist_ok=True)
    for f in os.listdir(prev):
        os.remove(os.path.join(prev, f))
    subprocess.run(["magick", "-density", "72", PDF, os.path.join(prev, "p-%02d.png")], check=True, capture_output=True)
    print("previews:", len(os.listdir(prev)))


if __name__ == "__main__":
    main()
