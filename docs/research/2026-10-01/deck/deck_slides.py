"""Slide builders for the Videoboy market report (revision 2, after a page-by-page review).

Each builder returns a Slide; build_deck.py numbers and renders them. Charts are inline
SVG in the validated palette (amber #C08000, cyan #169BC6, red #EE4036; ordinal cyan
#0E5A75 -> #1898C4). Opinion pages and ratings are labelled as the author's.
"""

from html import escape as E
import deck_data as D
from deck_style import BARS

BRAND = "VIDEOBOY · MARKET &amp; FEATURE REPORT · OCTOBER 2026"


def glyph(code):
    return {
        "Y": '<span class="s sY">●</span>', "P": '<span class="s sP">◐</span>', "N": '<span class="s sN">–</span>',
        "U": '<span class="s sU">?</span>', "A": '<span class="s sNA">n/a</span>',
        "✓": '<span class="s sY">●</span>', "◐": '<span class="s sP">◐</span>', "⚑": '<span class="s sF">⚑</span>',
        "✗": '<span class="s sN">–</span>',
    }[code]


LEGEND = ('<div class="legend"><span>' + glyph("Y") + ' offered</span><span>' + glyph("P") +
          ' partial / indirect</span><span>' + glyph("N") + ' not offered, or not found in the docs reviewed</span><span>' +
          glyph("U") + ' not verified</span><span>' + glyph("A") + ' not applicable</span></div>')


def bars_html(height, width="100%"):
    cells = "".join(f'<i style="flex:1;display:block;background:{c}"></i>' for c in BARS)
    return f'<div style="display:flex;height:{height}px;width:{width};border-radius:2px;overflow:hidden">{cells}</div>'


class Slide:
    def __init__(self, section, kicker, title, dek="", body="", src="", h1cls="", pad="", chrome=True):
        self.section, self.kicker, self.title, self.dek = section, kicker, title, dek
        self.body, self.src, self.h1cls, self.pad, self.chrome = body, src, h1cls, pad, chrome

    def render(self, n, total):
        top = bars_html(5)
        h1 = f'<h1 class="{self.h1cls}">{self.title}</h1>' if self.title else ""
        dek = f'<p class="dek">{self.dek}</p>' if self.dek else ""
        kick = f'<div class="kicker">{self.kicker}</div>' if self.kicker else ""
        hdr = (f'<div class="hdr"><span><b>{self.section}</b></span><span>{n:02d} / {total:02d}</span></div>' if self.chrome else "")
        foot = (f'<div class="foot"><span class="src">{self.src}</span><span>{BRAND}</span></div>' if self.chrome else "")
        return (f'<section class="slide" style="{self.pad}"><div class="bars" style="display:block">{top}</div>'
                f'{hdr}{kick}{h1}{dek}{self.body}{foot}</section>')


# ── charts ─────────────────────────────────────────────────────────────────────
def hbars(rows, width=700, bar_h=15, gap=8, color="#169BC6", label_w=215, fmt=None, fs=12):
    vmax = max(r[1] for r in rows)
    h = len(rows) * (bar_h + gap)
    plot_w = width - label_w - 100
    out = [f'<svg width="{width}" height="{h:.0f}" viewBox="0 0 {width} {h:.0f}" xmlns="http://www.w3.org/2000/svg" font-family="system-ui">']
    for i, row in enumerate(rows):
        label, v, cur = row[0], row[1], row[2]
        y = i * (bar_h + gap)
        w = max(3, plot_w * v / vmax)
        r, x0 = 3, label_w
        path = (f"M{x0},{y:.1f} H{x0 + w - r:.1f} Q{x0 + w:.1f},{y:.1f} {x0 + w:.1f},{y + r:.1f} V{y + bar_h - r:.1f} "
                f"Q{x0 + w:.1f},{y + bar_h:.1f} {x0 + w - r:.1f},{y + bar_h:.1f} H{x0} Z")
        val = fmt(v, cur) if fmt else f"{cur}{v:,.0f}"
        ty = y + bar_h / 2 + fs * 0.36
        out.append(f'<text x="{label_w - 10}" y="{ty:.1f}" text-anchor="end" font-size="{fs}" fill="#B4B4BE">{E(label)}</text>')
        out.append(f'<path d="{path}" fill="{color}"/>')
        out.append(f'<text x="{x0 + w + 8:.1f}" y="{ty:.1f}" font-size="{fs}" fill="#F4F4F6" font-family="ui-monospace, Menlo">{val}</text>')
    out.append("</svg>")
    return "".join(out)


def stacked(rows, width=760, bar_h=22, gap=14, label_w=160, total=None):
    h = len(rows) * (bar_h + gap)
    plot_w = width - label_w - 150
    out = [f'<svg width="{width}" height="{h}" viewBox="0 0 {width} {h}" xmlns="http://www.w3.org/2000/svg" font-family="system-ui">']
    for i, (label, full, part, unk) in enumerate(rows):
        y = i * (bar_h + gap)
        wf, wp, x0 = plot_w * full / total, plot_w * part / total, label_w
        vb = label.startswith("Videoboy")
        ty = y + bar_h / 2 + 4.5
        out.append(f'<text x="{label_w - 10}" y="{ty:.1f}" text-anchor="end" font-size="13" fill="{"#FF6F64" if vb else "#B4B4BE"}" '
                   f'font-weight="{800 if vb else 500}">{E(label)}</text>')
        out.append(f'<rect x="{x0}" y="{y}" width="{max(wf, 0.01):.1f}" height="{bar_h}" rx="3" fill="#1898C4"/>')
        if part:
            out.append(f'<rect x="{x0 + wf + 2:.1f}" y="{y}" width="{max(wp - 2, 1):.1f}" height="{bar_h}" rx="3" fill="#0E5A75"/>')
        out.append(f'<text x="{x0 + wf + wp + 10:.1f}" y="{ty:.1f}" font-size="12.5" fill="#F4F4F6" font-family="ui-monospace, Menlo">'
                   f'{full} ● {part} ◐ <tspan fill="#7C7C87">{unk} ?</tspan></text>')
    out.append("</svg>")
    return "".join(out)


def positioning():
    W, H, ml, mt, pw, ph = 640, 560, 70, 18, 545, 490
    out = [f'<svg width="{W}" height="{H}" viewBox="0 0 {W} {H}" xmlns="http://www.w3.org/2000/svg" font-family="system-ui">',
           f'<rect x="{ml}" y="{mt}" width="{pw}" height="{ph}" fill="#101015" stroke="#262630"/>',
           f'<line x1="{ml + pw / 2}" y1="{mt}" x2="{ml + pw / 2}" y2="{mt + ph}" stroke="#1F1F27"/>',
           f'<line x1="{ml}" y1="{mt + ph / 2}" x2="{ml + pw}" y2="{mt + ph / 2}" stroke="#1F1F27"/>',
           f'<text x="{ml}" y="{mt + ph + 20}" font-size="11" fill="#7C7C87" font-family="ui-monospace, Menlo">LIVE PERFORMANCE</text>',
           f'<text x="{ml + pw}" y="{mt + ph + 20}" text-anchor="end" font-size="11" fill="#7C7C87" font-family="ui-monospace, Menlo">POST-PRODUCTION →</text>',
           f'<text x="{ml - 12}" y="{mt + ph}" font-size="11" fill="#7C7C87" font-family="ui-monospace, Menlo" transform="rotate(-90 {ml - 12} {mt + ph})">FIXED INSTRUMENT</text>',
           f'<text x="{ml - 12}" y="{mt + 150}" font-size="11" fill="#7C7C87" font-family="ui-monospace, Menlo" transform="rotate(-90 {ml - 12} {mt + 150})">OPEN TOOLKIT →</text>']
    colors = {"red": "#EE4036", "cy": "#169BC6", "am": "#C08000", "": "#5A5A66"}
    for name, x, y, c in D.MAP_POINTS:
        cx, cy = ml + x * pw, mt + ph - y * ph
        r = 13 if c == "red" else 9
        out.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r}" fill="{colors[c]}" stroke="#0B0B0E" stroke-width="2"/>')
        anchor, dx = ("start", r + 7) if x < 0.8 else ("end", -(r + 7))
        out.append(f'<text x="{cx + dx:.1f}" y="{cy + 4.5:.1f}" text-anchor="{anchor}" font-size="{14 if c == "red" else 12.5}" '
                   f'font-weight="{800 if c == "red" else 600}" fill="{"#FF6F64" if c == "red" else "#E4E4EA"}">{E(name)}</text>')
    out.append("</svg>")
    return "".join(out)


def gantt():
    col = {"Safety & reach": "#169BC6", "Preparation": "#169BC6", "Owner's plan": "#C08000", "The wedge": "#EE4036", "Ready to show": "#5A5A66"}
    W, lw, top, rowh = 1472, 250, 26, 26
    pw = W - lw - 10
    wk = pw / 12
    H = top + len(D.GANTT) * rowh + 8
    out = [f'<svg width="{W}" height="{H}" viewBox="0 0 {W} {H}" xmlns="http://www.w3.org/2000/svg" font-family="system-ui">']
    for w in range(12):
        x = lw + w * wk
        out.append(f'<rect x="{x:.1f}" y="{top - 4}" width="{wk - 2:.1f}" height="{H - top}" fill="{"#101015" if w % 2 == 0 else "#0D0D11"}"/>')
        out.append(f'<text x="{x + wk / 2:.1f}" y="14" text-anchor="middle" font-size="11" fill="#7C7C87" font-family="ui-monospace, Menlo">W{w + 1}</text>')
    last = None
    for i, (trk, label, s, e) in enumerate(D.GANTT):
        y = top + i * rowh
        if trk != last:
            out.append(f'<text x="0" y="{y + 15}" font-size="10.5" fill="#FF6F64" font-family="ui-monospace, Menlo" letter-spacing="1">{E(trk.upper())}</text>')
            last = trk
        x0 = lw + (s - 1) * wk + 2
        x1 = lw + e * wk - 4
        out.append(f'<rect x="{x0:.1f}" y="{y + 4}" width="{x1 - x0:.1f}" height="{rowh - 9}" rx="3" fill="{col[trk]}"/>')
        tx, anchor = x1 + 8, "start"
        if e >= 10:
            tx, anchor = x0 - 8, "end"
        out.append(f'<text x="{tx:.1f}" y="{y + 17}" text-anchor="{anchor}" font-size="12" fill="#F4F4F6">{E(label)}</text>')
    out.append("</svg>")
    return "".join(out)


def dots(n):
    return ('<span style="letter-spacing:2px;color:var(--ink)">' + "●" * n + '</span><span style="letter-spacing:2px;color:var(--ink4)">' +
            "●" * (5 - n) + "</span>")


# ── cover and contents ─────────────────────────────────────────────────────────
def cover():
    body = f"""
<div style="position:absolute;left:64px;right:64px;top:104px">
  <div style="font:600 12px var(--mono);letter-spacing:.18em;color:var(--ink3);text-transform:uppercase">Market &amp; feature report · October 2026</div>
  <div style="font-family:'VBDisplay',var(--sans);font-size:300px;line-height:.82;letter-spacing:.005em;margin:26px 0 0 -6px;color:var(--ink)">VIDEOBOY</div>
  <div style="margin:28px 0 32px">{bars_html(34, "1100px")}</div>
  <div style="font-family:var(--sans);font-weight:900;font-size:62px;letter-spacing:-.03em;line-height:.98;max-width:1300px">
    The analog instrument in a digital market.</div>
  <p class="dek" style="margin-top:18px;max-width:1180px">A checked inventory of what Videoboy does; how it compares with Resolume,
  VDMX, Millumin, QLab, MadMapper, TouchDesigner, Synesthesia, the DJ video tools, vMix, ATEM, DaVinci Resolve, Premiere Pro and
  Logic Pro; what broadcast and DJing can teach it; the owner's roadmap; and what I would do next.</p>
</div>
<div style="position:absolute;left:64px;right:64px;bottom:40px;display:flex;justify-content:space-between;font:10.5px var(--mono);color:var(--ink3);letter-spacing:.04em">
  <span>Videoboy 0.4.10 · branch feature/queue-names · research date 2026-10-01</span>
  <span>Prepared by Claude (Anthropic) for Spencer Starnes · © NewVHS / Spencer Starnes 2026</span>
</div>"""
    return Slide("", "", "", body=body, pad="padding:0", chrome=False)


def contents(toc):
    items = "".join(
        f'<tr><td style="width:64px;font-family:VBDisplay;font-size:34px;color:var(--redText);padding:6px 0 4px">{p:02d}</td>'
        f'<td style="font-size:21px;font-weight:800;letter-spacing:-.01em;color:var(--ink);padding-top:9px">{E(t)}</td>'
        f'<td style="font-size:13px;color:var(--ink2);padding-top:12px">{E(d)}</td></tr>' for p, t, d in toc)
    body = f"""
<div class="grid" style="grid-template-columns:1.35fr 1fr;gap:48px;margin-top:4px">
  <table class="d" style="font-size:12px">{items}</table>
  <div>
    <div class="lbl" style="margin-bottom:8px">How to read the tables</div>
    {LEGEND}
    <div class="rule"></div>
    <div class="dense">
      <p><b>Videoboy claims are checked against the code.</b> 130 features were read from the source, not from the documents
      (two of which are out of date), each with an evidence path. Every path was tested for existence by script and the status
      counts are machine counts. A second read corrected three rows and added three.</p>
      <p><b>Market claims are sourced.</b> Vendor documentation and price pages were fetched on 2026-10-01. Figures from secondary
      sites are marked <span class="k">*</span>. Anything not checked is shown as <span class="k">?</span>, not guessed.</p>
      <p><b>Prices are in the vendor's currency</b> (€, $, £) and are not converted. Subscriptions are annualised as monthly × 12
      where no yearly price is published.</p>
      <p><b>Opinion is labelled.</b> The market map's positions, the interface ratings and the "what I would do" section are the
      author's view; the roadmap is the owner's.</p>
      <p><b>Scope.</b> DMX and lighting are left out, as asked. No competitor was installed or tested hands-on; no market-size figure
      is given because none could be sourced reliably.</p>
    </div>
  </div>
</div>"""
    return Slide("Contents", "Contents", "What's inside.", body=body)


# ── summary and product ────────────────────────────────────────────────────────
def exec_summary(stats):
    tiles = "".join(f'<div class="card stat"><div class="lbl">{E(l)}</div><div class="big">{v}</div><p>{E(d)}</p></div>'
                    for l, v, d in stats)
    finds = [
        ("Nobody else does what the wedge does.",
         "Live datamosh on a real H.264 stream, an NTSC composite signal model, the AVE-5 wipe block and a real Scala titler as a "
         "source: none of the 14 products in the comparison matrices offers any of them as a built-in feature."),
        ("It already speaks broadcast.",
         "Hot Punch, A/B ROLL, ADV, bus keys, tally and one-take ISO recording are switcher behaviour. VJ tools don't have it; ATEM "
         "and vMix do, without the beat."),
        ("The gaps are plumbing, not looks.",
         "OSC, Syphon / NDI, MIDI clock / Link, timecode and undo are standard in the live competitors and absent here. Each is days "
         "of work, not weeks."),
        ("Inside a clip, Videoboy is blind.",
         "One in/out pair per clip. Every DJ app, Resolume, QLab and MadMapper can mark and jump to points inside media. Hot cues are "
         "the single biggest performance gap."),
        ("Live video still sells licences; DJ and editing software increasingly rent.",
         "Resolume €299 / €799, VDMX $199 / $349, Synesthesia $199 / $399 — all one-time. rekordbox, VirtualDJ and Premiere lead with "
         "subscriptions, and Apple bundled its pro apps at $129 a year in January 2026."),
    ]
    rows = "".join(f'<div style="display:grid;grid-template-columns:34px 1fr;gap:12px;margin-bottom:17px">'
                   f'<div style="font-family:VBDisplay;font-size:38px;color:var(--redText);line-height:.85">{i + 1}</div>'
                   f'<div><div style="font-size:20px;font-weight:800;letter-spacing:-.012em;line-height:1.12">{E(t)}</div>'
                   f'<div style="font-size:13.6px;color:var(--ink2);line-height:1.45;margin-top:4px">{E(d)}</div></div></div>'
                   for i, (t, d) in enumerate(finds))
    body = f"""
<div class="grid" style="grid-template-columns:1.35fr 1fr;gap:40px;margin-top:8px">
  <div>{rows}</div>
  <div class="grid g2" style="gap:12px;align-content:start">{tiles}</div>
</div>"""
    return Slide("Summary", "Executive summary",
                 "A real instrument with no rival in its lane, and five gaps between it and a bigger room.",
                 body=body, src="Sources: feature-inventory.md (code-checked) · competitor documentation listed in the appendix")


def what_it_is():
    path = """
<svg width="720" height="292" viewBox="0 0 720 292" font-family="system-ui" xmlns="http://www.w3.org/2000/svg">
 <defs><marker id="ar" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="#7C7C87"/></marker></defs>
 <g font-size="13" font-weight="800">
  <rect x="10" y="14" width="96" height="44" rx="5" fill="#15151B" stroke="#C08000"/><text x="58" y="41" text-anchor="middle" fill="#F4F4F6">SOURCE A</text>
  <rect x="10" y="74" width="96" height="44" rx="5" fill="#15151B" stroke="#C08000"/><text x="58" y="101" text-anchor="middle" fill="#F4F4F6">SOURCE B</text>
  <rect x="10" y="174" width="96" height="44" rx="5" fill="#15151B" stroke="#169BC6"/><text x="58" y="201" text-anchor="middle" fill="#F4F4F6">SOURCE C</text>
  <rect x="10" y="234" width="96" height="44" rx="5" fill="#15151B" stroke="#169BC6"/><text x="58" y="261" text-anchor="middle" fill="#F4F4F6">SOURCE D</text>
  <rect x="190" y="44" width="150" height="44" rx="5" fill="#15151B" stroke="#C08000"/><text x="265" y="71" text-anchor="middle" fill="#F0B640">A/B SUB MIX · ONE</text>
  <rect x="190" y="204" width="150" height="44" rx="5" fill="#15151B" stroke="#169BC6"/><text x="265" y="231" text-anchor="middle" fill="#5CC8EC">C/D SUB MIX · TWO</text>
  <rect x="420" y="124" width="130" height="44" rx="5" fill="#2A1110" stroke="#EE4036"/><text x="485" y="151" text-anchor="middle" fill="#FF6F64">PROGRAM</text>
  <rect x="610" y="74" width="100" height="36" rx="5" fill="#15151B" stroke="#34343F"/><text x="660" y="97" text-anchor="middle" fill="#B4B4BE" font-size="11">OUTPUT · SD</text>
  <rect x="610" y="128" width="100" height="36" rx="5" fill="#15151B" stroke="#34343F"/><text x="660" y="151" text-anchor="middle" fill="#B4B4BE" font-size="11">REC · ISO</text>
  <rect x="610" y="182" width="100" height="36" rx="5" fill="#15151B" stroke="#34343F"/><text x="660" y="205" text-anchor="middle" fill="#B4B4BE" font-size="11">STREAM · OBS</text>
 </g>
 <g stroke="#7C7C87" stroke-width="1.4" fill="none" marker-end="url(#ar)">
  <path d="M106,36 C150,36 150,60 188,62"/><path d="M106,96 C150,96 150,74 188,72"/>
  <path d="M106,196 C150,196 150,222 188,222"/><path d="M106,256 C150,256 150,234 188,232"/>
  <path d="M340,66 C380,66 380,140 418,142"/><path d="M340,226 C380,226 380,152 418,150"/>
  <path d="M550,140 C580,140 580,92 608,92"/><path d="M550,146 L608,146"/><path d="M550,152 C580,152 580,200 608,200"/>
 </g>
 <g font-size="10.5" fill="#7C7C87" font-family="ui-monospace, Menlo">
  <text x="118" y="140">channel FX copies (A · B · MIX focus)</text>
  <text x="300" y="112">bus keys · CUT · FADE · 13 transitions</text>
  <text x="380" y="196">ONE ↔ TWO fader</text>
 </g>
</svg>"""
    facts = [
        ("The wedge", "Musical, playable manipulation of compressed video bitstreams (MPEG family), output clean to SD for an analog chain. "
                      "Everything else is supporting cast (CLAUDE.md)."),
        ("The canvas", "SD NTSC 720×480 at 29.97 is the default and the reference. PAL, HD, square and vertical are approved for 0.4.11, "
                       "not built yet."),
        ("The rules", "Smooth playback outranks every feature. The app is silent: audio comes in only to find the beat. A/B always feed ONE "
                      "and C/D always feed TWO."),
        ("The build", "Native AppKit + Metal, Apple Silicon only. About 80,000 lines of Swift in 252 files; a headless Core with 867 tests; "
                      "40 named self-QA checks."),
    ]
    cards = "".join(f'<div class="card"><h3>{E(t)}</h3><p style="font-size:13px">{E(d)}</p></div>' for t, d in facts)
    health = """
<div class="grid g4" style="gap:12px;margin-top:14px">
 <div class="card stat"><div class="lbl">Frame budget</div><div class="big">33.4<small> ms</small></div><p>one frame at 29.97</p></div>
 <div class="card stat"><div class="lbl">Full-load mean</div><div class="big">6.4<small> ms</small></div><p>stress test, all four channels, every effect (09-28)</p></div>
 <div class="card stat"><div class="lbl">Worst tick</div><div class="big">17.8<small> ms</small></div><p>stress worst; GPU-fence stalls still under study</p></div>
 <div class="card stat"><div class="lbl">10-min HD soak</div><div class="big">0<small> dropped</small></div><p>2× 1080p H.264 + ProRes + 4K HEVC, memory flat</p></div>
</div>"""
    body = f"""
<div class="grid" style="grid-template-columns:740px 1fr;gap:36px;margin-top:8px">
  <div class="card" style="padding:18px 10px 8px">{path}</div>
  <div class="grid g2" style="gap:12px">{cards}</div>
</div>{health}"""
    return Slide("01 · Videoboy", "What it is", "A four-channel live mixer that breaks the bitstream on the beat.",
                 body=body, src="Sources: CLAUDE.md · docs/SPEC.md §2 · docs/AUDIT-2026-09-28.md · Core/Sources/VideoboyCore/VideoboyCore.swift (0.4.10)")


def interface_vj():
    pts = [(50, 5.6), (30.5, 5.6), (5.8, 17), (25, 22), (50, 22), (49, 48.8), (5.6, 59), (50, 60.5), (15, 94.3), (69.5, 98)]
    marks = "".join(f'<div class="callout" style="left:calc({x}% - 11px);top:calc({y}% - 11px)">{i + 1}</div>' for i, (x, y) in enumerate(pts))
    legend = [
        ("Transport cluster", "BPM, CLOCK, DIV, FMT, record, play; Learn, Detect and Hot Punch at the edges"),
        ("Clip Pads 1–8", "whole-clip launchers with A/B · C/D side switches; ⌥ loads + cuts, ⌥⌘ on the beat"),
        ("Sources A–D", "preview, shuttle, scrub, loop mode, FIT"),
        ("Sub Mix monitors", "ONE and TWO with WFM · RGB · HIST · VEC · FILE · TC · OVER · L3 · DATA BURN"),
        ("Program", "the output, with tally"),
        ("Bus rows", "A·B / 1·2 / C·D keys, CUT, FADE, ROLL, ADV, transition and blend keys, DJ-style faders"),
        ("FX panels", "A · B · MIX focus, Source Controls, cards with MIDI · AUD · LFO badges"),
        ("Libraries + Asset Browser", "Sources, Generators, Graphics, Clips, Images, EMU; icon, list and column views"),
        ("Output bar", "OUTPUT, Safe, Overscan, BFI, Test Pat"),
        ("Mode bar + status", "IMPORT · VJ · SETTINGS (⌘1–3); MIDI, OSC, node count, drops, fps"),
    ]
    items = "".join(f'<div style="display:grid;grid-template-columns:24px 1fr;gap:8px;margin-bottom:8px">'
                    f'<div class="callout" style="position:static">{i + 1}</div>'
                    f'<div><div style="font-size:12.8px;font-weight:750">{E(t)}</div>'
                    f'<div style="font-size:11.4px;color:var(--ink2);line-height:1.3">{E(d)}</div></div></div>' for i, (t, d) in enumerate(legend))
    body = f"""
<div class="grid" style="grid-template-columns:1150px 1fr;gap:24px;margin-top:6px">
  <div class="shot"><img src="img/vj-mode.png" alt="Videoboy VJ mode">{marks}</div>
  <div>{items}</div>
</div>"""
    return Slide("01 · Videoboy", "The interface today", "One fixed window. Everything within reach.",
                 body=body, src="Screenshot: selfqa/out/perf/pads/window.png — the real window, captured by the self-QA harness on 2026-09-28")


def interface_modes():
    def crop(img, h, pos="top"):
        return (f'<div class="shot" style="height:{h}px"><img src="img/{img}" style="width:100%;height:100%;object-fit:cover;'
                f'object-position:{pos}"></div>')
    caps = [
        ("Import · ⌘1", crop("import-mode.png", 300, "left top"),
         "Lightroom Classic's model: devices and locations, a checkable grid, Add · Move · Copy, duplicates skipped, choose a bin, optional "
         "Copy + Optimize into linked MPEG-2 GOP 6 media."),
        ("VJ · ⌘2 — compact width", crop("compact.png", 300, "center top"),
         "The performance window. It is width-reactive: at compact widths the sources and FX panels fold to rails; at narrow widths only "
         "Program, the faders and the output bar stay."),
        ("Settings · ⌘3", crop("settings-mode.png", 300, "left top"),
         "A mode, not a dialog: 13 panes, from Project, Media and Optimize to Hot Keys, MIDI Mapping, EMU, Macros & AI and Shaders."),
    ]
    cols = "".join(f'<div><div class="lbl" style="margin-bottom:6px">{E(t)}</div>{img}<p style="font-size:12.6px;color:var(--ink2);'
                   f'margin-top:9px;line-height:1.42">{E(c)}</p></div>' for t, img, c in caps)
    facts = [("Never interrupts", "Switching modes keeps the engine rendering; output and recording continue."),
             ("Discoverable", "⌘1–⌘3 are View-menu items, so they can be remapped in System Settings."),
             ("Separate player", "Import's viewer has its own player; auditioning never touches Program."),
             ("Fixed, not frozen", "Panels collapse and the grid reflows at three breakpoints; nothing ever moves position.")]
    strip = "".join(f'<div class="card"><h3>{E(t)}</h3><p>{E(d)}</p></div>' for t, d in facts)
    body = f'<div class="grid g3" style="gap:22px;margin-top:6px">{cols}</div><div class="grid g4" style="gap:12px;margin-top:16px">{strip}</div>'
    return Slide("01 · Videoboy", "Modes", "Three rooms, one engine that never stops.", body=body,
                 src="Screenshots: selfqa/out/perf/modes/*.png, selfqa/out/phase-2/ui-layout/compact.png · docs/PROPOSAL-2026-09-26.md §4–5 · SPEC §14.4")


# ── inventory ──────────────────────────────────────────────────────────────────
def inventory_pages(sections, counts, first=27, rest=35):
    lines = []
    for title, rows in sections:
        lines.append(("grp", title))
        for r in rows:
            lines.append(("row", r))
    pages, cur, used, budget = [], [], 0, first
    for kind, item in lines:
        cost = 1
        if kind == "row" and len(item[1]) > 140:
            cost = 2
        need = cost + (2 if kind == "grp" else 0)
        if used + need > budget:
            pages.append(cur)
            cur, used, budget = [], 0, rest
        cur.append((kind, item))
        used += cost
    if cur:
        pages.append(cur)
    out = []
    for i, page in enumerate(pages):
        trs = []
        for kind, item in page:
            if kind == "grp":
                trs.append(f'<tr class="grp"><td colspan="4">{E(item)}</td></tr>')
            else:
                rid, feat, st, ev = item
                trs.append(f'<tr><td class="num" style="width:38px">{rid}</td><td class="f">{feat}</td>'
                           f'<td class="c" style="width:44px">{glyph(st)}</td>'
                           f'<td class="ev" style="width:470px;max-width:470px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{ev}</td></tr>')
        table = ('<table class="d tight" style="margin-top:2px;table-layout:fixed;font-size:11px"><colgroup><col style="width:40px"><col><col style="width:46px">'
                 '<col style="width:470px"></colgroup><tr><th>#</th><th>Feature (checked in the code)</th>'
                 '<th class="c">Status</th><th>Evidence</th></tr>' + "".join(trs) + "</table>")
        legend = ('<div class="legend" style="margin:4px 0 4px"><span>' + glyph("✓") + ' shipped, on by default</span><span>' +
                  glyph("◐") + ' partial</span><span>' + glyph("⚑") + ' built, flag off</span><span>' + glyph("✗") + ' not built</span>'
                  f'<span style="color:var(--ink4)">page {i + 1} of {len(pages)}</span></div>')
        if i == 0:
            out.append(Slide("02 · Features", "Feature inventory", "Everything Videoboy does today, checked against the code.",
                             dek=f"{counts['✓']} shipped · {counts['◐']} partial · {counts['⚑']} built but switched off · {counts['✗']} not built — "
                                 f"{sum(counts.values())} rows, every evidence path tested by script.",
                             body=legend + table, src="Source: docs/research/2026-10-01/feature-inventory.md · branch feature/queue-names a92f464"))
        else:
            out.append(Slide("02 · Features", "", "Feature inventory, continued", body=legend + table, h1cls="sm",
                             src="Source: docs/research/2026-10-01/feature-inventory.md · branch feature/queue-names a92f464"))
    return out


def not_built(sections, counts):
    groups = {"✗": [], "⚑": [], "◐": []}
    for title, rows in sections:
        for rid, feat, st, ev in rows:
            if st in groups:
                groups[st].append((rid, feat))

    def col(key, label, note, extra=""):
        items = "".join(f'<li style="font-size:11.2px;color:var(--ink2);line-height:1.32;margin:2px 0"><span class="num">{rid}</span> {feat}</li>'
                        for rid, feat in groups[key])
        return (f'<div class="card"><div class="lbl">{label} · {len(groups[key])}</div>'
                f'<p style="font-size:11.2px;margin:4px 0 6px">{note}</p><ul style="list-style:none;padding:0">{items}</ul>{extra}</div>')
    quote = """<div class="rule"></div><div class="quote" style="font-size:12px">"It is off rather than deleted. Every node, shader, parameter and
 test is intact; this flag is the only thing standing between the app and all of it. Whatever it becomes next will start from the working
 version rather than from a rewrite."</div><p style="font-size:10.5px;color:var(--ink3);margin-top:6px">— the corruptor's flag comment,
 Core/Sources/VideoboyCore/VideoboyCore.swift. Switched off because it "cannot currently be JUDGED on an analog chain".</p>"""
    body = f"""
<div class="grid" style="grid-template-columns:1.55fr 1fr 1fr;gap:14px;margin-top:4px">
  {col("✗", "Not built", "Absent from the code: comments, greyed placeholders or nothing.")}
  {col("◐", "Partial", "Built with a gap that matters on stage.")}
  {col("⚑", "Built, switched off", "Off by the owner's decision, intact behind a flag.", quote)}
</div>"""
    return Slide("02 · Features", "The honest list", "What isn't there yet.",
                 dek=f"{counts['✗']} features are absent, {counts['◐']} are partial and {counts['⚑']} are finished but deliberately switched off — "
                     "including the bitstream corruptor the app was built around.",
                 body=body, src="Source: feature-inventory.md · VIDEOBOY_FLAGS defaults in Core/Sources/VideoboyCore/VideoboyCore.swift")


# ── market ─────────────────────────────────────────────────────────────────────
def market_map():
    cards = "".join(
        f'<div class="card" style="padding:10px 12px"><div class="tag">{E(n)}</div><div style="font-size:13.2px;font-weight:800;margin:3px 0 3px">{E(p)}</div>'
        f'<p style="font-size:11.2px">{E(w)}</p><div style="display:flex;justify-content:space-between;margin-top:5px;font:10px var(--mono);color:var(--ink3)">'
        f'<span>{E(pr)}</span><span>overlap: <b style="color:{"var(--redText)" if ov == "high" else "var(--ink2)"}">{E(ov)}</b></span></div></div>'
        for n, p, w, pr, ov in D.LANES)
    body = f"""
<div class="grid" style="grid-template-columns:660px 1fr;gap:30px;margin-top:4px">
  <div><div class="lbl" style="margin-bottom:6px">Author's map — positions are judgement, not measurement</div>{positioning()}</div>
  <div>
    <div class="grid g2" style="gap:10px">{cards}</div>
    <div class="card" style="margin-top:12px;border-color:rgba(238,64,54,.55);background:rgba(238,64,54,.05)">
      <div class="tag" style="color:var(--redText)">Videoboy's lane · the analog / glitch instrument</div>
      <p style="font-size:12.6px;margin-top:4px">Live like a VJ tool, disciplined like a switcher, timed like a DJ, aimed at an SD analog chain. No product in any
      lane damages a real bitstream live or models an NTSC signal path — that is the moat, and the audience is narrower than any lane's.</p></div>
  </div>
</div>"""
    return Slide("03 · Market", "The market map", "Eight lanes. Videoboy sits in a corner of its own.",
                 body=body, src="Lanes, positions and overlap are the author's grouping; price bands from vendor pages (appendix)")


def who_is_who():
    trs = "".join(
        f'<tr class="{"vb" if n == "Videoboy" else ""}"><td class="f" style="font-weight:700">{E(n)}</td><td>{E(l)}</td><td>{E(p)}</td>'
        f'<td class="num">{E(v)}</td><td class="f">{E(pr)}</td><td>{E(md)}</td>'
        f'<td style="color:var(--ink2)">{E(D.WHO_EDGE[n][0])}</td><td style="color:var(--ink)">{E(D.WHO_EDGE[n][1])}</td></tr>'
        for n, m, l, p, v, pr, md, _ in D.WHO)
    table = ('<table class="d" style="font-size:11.2px"><tr><th>Product</th><th>Lane</th><th>Platform</th><th>Version (2026)</th><th>Price</th>'
             '<th>Model</th><th>Does better than Videoboy</th><th>Videoboy does better</th></tr>' + trs + "</table>")
    return Slide("03 · Market", "Who's who", "The field on 1 October 2026.",
                 dek="Latest versions and list prices as published on 2026-10-01. <b>*</b> = secondary source; — = not published or not checked. "
                     "The two right-hand columns summarise the comparison matrices.",
                 body=table, src="Sources: vendor shops and release notes (appendix) · QLab tiers via Capterra* · rekordbox via dj.studio* · media-server prices via secondary sites*")


def pricing():
    one = hbars(D.ONE_TIME, width=730, bar_h=18, gap=11.5, label_w=210, fs=12.5,
                fmt=lambda v, c: f"{c}{v:,.2f}" if v % 1 else f"{c}{v:,.0f}")
    yr = hbars([(l, v, c) for l, v, c, _ in D.PER_YEAR], width=700, bar_h=18, gap=21.5, label_w=200, fs=12.5,
               fmt=lambda v, c: (f"{c}{v:,.2f}/yr" if v % 1 else f"{c}{v:,.0f}/yr"))
    body = f"""
<div class="grid g2" style="gap:40px;margin-top:6px">
 <div><div class="lbl" style="margin-bottom:10px">Buy once — list price of each licence tier (selected)</div>{one}</div>
 <div><div class="lbl" style="margin-bottom:10px">Pay yearly — subscriptions, rentals and update renewals</div>{yr}
  <p style="font-size:11.4px;color:var(--ink3);margin-top:12px;line-height:1.4">Not shown: Watchout 7 at ~€3,200 a licence*; free tiers (Resolve,
  TouchDesigner non-commercial, QLab core, disguise Starter, Pixera Creator, Smode Community). Currencies are not converted; € and £ amounts would
  read ~10–25% higher in dollars.</p></div>
</div>"""
    return Slide("03 · Market", "Pricing landscape",
                 "Live video still sells licences. DJ and editing software increasingly rent.", body=body,
                 src="Sources: resolume.com/shop · vidvox.net · millumin.com/v5 · madmapper · derivative.ca · synesthesia.live · serato.com · virtualdj.com · vmix.com · Apple · Adobe · * secondary")


def business_models():
    models = [
        ("Perpetual + paid update year", "Resolume, Synesthesia, vMix",
         "Own the version forever; renew to keep getting updates (Resolume €79 / €219, Synesthesia $60, vMix $60*)."),
        ("Perpetual, paid upgrades", "VDMX, MadMapper, Millumin, Modul8, Final Cut Pro, Logic Pro",
         "Buy a major version; pay to upgrade at the next one (Millumin V5 upgrade from €85)."),
        ("Rental beside perpetual", "Millumin, QLab, MadMapper, Notch",
         "Short rentals for shows and tours: Millumin €29/week, QLab $8–15/day*, MadMapper €39/month."),
        ("Subscription-led", "rekordbox, Premiere Pro, VirtualDJ, disguise Pro*",
         "rekordbox ~$180/yr*, Premiere $22.99/mo, VirtualDJ $19/mo (a lifetime licence is also reported*)."),
        ("Bundle subscription", "Apple Creator Studio, Serato DJ Suite",
         "Apple: Final Cut, Logic, Pixelmator Pro, Motion, Compressor, MainStage for $129/yr; Serato Suite $14.99/mo or $499."),
        ("Free tier + paid pro", "DaVinci Resolve, TouchDesigner, QLab, Pixera, Smode",
         "Free with limits (resolution, watermark, features); Resolve Studio $295 once; TouchDesigner $600–2,200."),
    ]
    cards = "".join(f'<div class="card" style="padding:11px 14px"><div class="tag">{E(w)}</div><h3 style="margin-top:3px">{E(m)}</h3><p>{E(d)}</p></div>'
                    for m, w, d in models)
    trs = "".join(f'<tr><td class="f" style="font-weight:700;width:150px">{E(p)}</td><td>{E(t)}</td><td class="num" style="width:190px">{E(s)}</td></tr>'
                  for p, t, s in D.TRIAL_TERMS)
    table = ('<table class="d" style="font-size:11.8px"><tr><th>Product</th><th>Trial, demo and discount terms</th><th>Source</th></tr>' + trs + "</table>")
    body = f"""
<div class="grid g3" style="gap:10px;margin-top:4px">{cards}</div>
<div class="grid" style="grid-template-columns:1.6fr 1fr;gap:14px;margin-top:12px">
 <div>{table}</div>
 <div class="card"><div class="lbl">What the market accepts</div>
  <p style="margin-top:5px"><b style="color:var(--ink)">VJs</b> pay once, in a $199–$399 / €299–€799 band, with a year of updates and an optional renewal.</p>
  <p style="margin-top:5px"><b style="color:var(--ink)">Touring shows</b> rent per machine for a week or a month — that is how a $1,399 tool reaches a one-night user.</p>
  <p style="margin-top:5px"><b style="color:var(--ink)">Everyone</b> expects a free, watermarked way to try it first.</p>
  <p style="margin-top:5px"><b style="color:var(--ink)">2026:</b> Apple priced six pro apps at $129 a year; a specialist tool now has to justify itself on what nobody else does.</p></div>
</div>"""
    return Slide("03 · Market", "Business models", "Six ways to charge. VJ tools agree on one: pay once.",
                 body=body, src="Sources: vendor price and licence pages (appendix) · TidBITS / MacRumors on Apple Creator Studio (Jan 2026) · * secondary")


def signals():
    sig = [
        ("AI is now a control surface", "Resolume documents an MCP server for AI control; MadMapper's Mad AI writes materials from a prompt; Magic 2.5 added AI prompting.", "resolume.com/support · madmapper docs"),
        ("Editors went AI-first", "Premiere 26 (Jan) added AI search, Generative Extend and Object Mask; 26.5 (Sep) a Generative Media Tool. Resolve 21 (Apr) added IntelliSearch and a Photo page.", "Adobe · Blackmagic"),
        ("DJ prep is automated", "rekordbox 7's CUE Analysis places hot and memory cues by phrase and learns a DJ's style; 4-stem separation since 7.2.8 (Apr 2026).", "rekordbox.com · Digital DJ Tips"),
        ("DJ gear talks to visuals", "StageLinQ drives Resolume and SoundSwitch; AlphaTheta added SoundSwitch to rekordbox and PRO DJ LINK Bridge in Sep 2026.", "DJWORX · EDMTunes"),
        ("Theatre tools learned timelines", "Millumin 5 (Apr 2026) added multi-canvas timelines and Bezier keyframes; MadMapper 6's timelines replaced its cues.", "millumin.com · CDM"),
        ("TouchDesigner became a platform", "VDMX6 and Millumin 5 both run TouchDesigner components inside them (commercial TD licence required).", "vidvox.net · millumin.com"),
        ("Apple bundled its pro apps", "Creator Studio, 28 Jan 2026: Final Cut, Logic and four more for $129 a year; one-time licences still sold.", "TidBITS · MacRumors"),
        ("Dependencies kill tools", "CoGe VJ is gone: it was built on Quartz Composer and runs on nothing newer than Mojave.", "imimot.com"),
    ]
    cards = "".join(f'<div class="card" style="padding:16px 18px"><h3 style="font-size:17px">{E(t)}</h3><p style="font-size:13.4px">{E(d)}</p><div class="tag" style="margin-top:8px">{E(s)}</div>'
                    f'<div class="rule" style="margin:11px 0 8px"></div><div class="lbl" style="color:var(--redText)">For Videoboy</div>'
                    f'<p style="margin-top:4px;color:var(--ink);font-size:13.4px">{E(v)}</p></div>'
                    for (t, d, s), v in zip(sig, D.SIGNAL_VB))
    return Slide("03 · Market", "Signals from 2026", "What moved this year, and what it means here.",
                 body=f'<div class="grid g4" style="gap:12px;margin-top:8px">{cards}</div>',
                 src="Sources: listed on each card; full URLs in the appendix · \"For Videoboy\" lines are the author's view")


# ── matrices ───────────────────────────────────────────────────────────────────
def matrix_pages(vb_check):
    rows = D.LIVE_ROWS
    split = next(i for i, r in enumerate(rows) if r[0] == "Look")
    chunks = [rows[:split], rows[split:]]
    titles = ["Against the seven live tools people switch from.", "Looks, time, control, output and the library."]
    out = []
    for ci, chunk in enumerate(chunks):
        head = "".join(f'<th class="c" style="width:90px">{E(name)}</th>' for _, name in D.LIVE_PRODUCTS)
        trs, last = [], None
        for g, feat, cells, note, _ in chunk:
            if g != last:
                trs.append(f'<tr class="grp"><td colspan="{len(D.LIVE_PRODUCTS) + 2}">{E(g)}</td></tr>')
                last = g
            tds = "".join(f'<td class="c" style="{"background:rgba(238,64,54,.07)" if k == "VB" else ""}">{glyph(cells[k])}</td>' for k, _ in D.LIVE_PRODUCTS)
            trs.append(f'<tr><td class="f">{E(feat)}</td>{tds}<td style="font-size:10px;color:var(--ink3)">{E(note)}</td></tr>')
        top = ""
        if ci == 0:
            price = "".join(f'<td class="c num" style="font-size:9.5px">{E(D.LIVE_PRICE[k])}</td>' for k, _ in D.LIVE_PRODUCTS)
            plat = "".join(f'<td class="c num" style="font-size:9.5px">{E(D.LIVE_PLATFORM[k])}</td>' for k, _ in D.LIVE_PRODUCTS)
            top = f'<tr><td class="lbl">Price</td>{price}<td></td></tr><tr><td class="lbl">Platform</td>{plat}<td></td></tr>'
        table = (f'<table class="d tight" style="font-size:11.4px"><tr><th style="width:330px">Feature</th>{head}<th>Note</th></tr>{top}'
                 + "".join(trs) + "</table>")
        out.append(Slide("04 · Comparison", f"Feature matrix · live tools ({ci + 1}/2)", titles[ci],
                         body=LEGEND + '<div style="height:6px"></div>' + table,
                         src="Sources: vendor documentation per product (appendix) · Videoboy cells re-checked against feature-inventory.md " + vb_check))
    return out


def matrix_adjacent():
    head = "".join(f'<th class="c" style="width:104px">{E(n)}</th>' for _, n in D.ADJ_PRODUCTS)
    trs = []
    for feat, cells, note in D.ADJ_ROWS:
        tds = "".join(f'<td class="c" style="{"background:rgba(238,64,54,.07)" if k == "VB" else ""}">{glyph(cells[k])}</td>' for k, _ in D.ADJ_PRODUCTS)
        trs.append(f'<tr><td class="f">{E(feat)}</td>{tds}<td style="font-size:10px;color:var(--ink3)">{E(note)}</td></tr>')
    price = "".join(f'<td class="c num" style="font-size:9.5px">{E(D.ADJ_PRICE[k])}</td>' for k, _ in D.ADJ_PRODUCTS)
    table = (f'<table class="d" style="font-size:12px"><tr><th style="width:300px">Capability</th>{head}<th>Note</th></tr>'
             f'<tr><td class="lbl">Price</td>{price}<td></td></tr>' + "".join(trs) + "</table>")
    side = """
<div class="grid g3" style="gap:12px;margin-top:14px">
 <div class="card"><h3>Against DJ video</h3><p>Serato, VirtualDJ and rekordbox own the beat and the cue points, and their video follows the
 track. Videoboy's picture follows the room's beat instead, from any audio, and its looks and broadcast discipline go far deeper. It cannot
 mark points inside a clip.</p></div>
 <div class="card"><h3>Against live production</h3><p>vMix and ATEM own switching, overlays, ISO recording and streaming; ATEM ISO even writes
 an editable Resolve project of the show. Videoboy matches the switching and the ISO recording, adds the beat, and lacks the overlay layer
 and the edit export.</p></div>
 <div class="card"><h3>Against post and the DAW</h3><p>Resolve, Premiere and Logic are where a live performance ends up and where performers
 learned their habits: markers, inspectors, undo, key commands. Videoboy should export into them, not imitate them.</p></div>
</div>"""
    return Slide("04 · Comparison", "Feature matrix · adjacent tools", "Where the DJs, the switchers and the editors already are.",
                 body=LEGEND + '<div style="height:8px"></div>' + table + side,
                 src="Sources: serato.com · virtualdj.com · vmix.com · blackmagicdesign.com · adobe.com · apple.com (appendix)")


def scoreboard(score_rows, n_rows, unique, group_table):
    chart = stacked(score_rows, width=760, total=n_rows)
    uniq = "".join(f'<li style="font-size:12.4px;color:var(--ink2);margin:3px 0">{E(u)}</li>' for u in unique)
    groups, prods, cells = group_table
    head = "".join(f'<th class="c">{E(g)}<br><span style="color:var(--ink4)">{n}</span></th>' for g, n in groups)
    trs = ""
    for name, vals in zip(prods, cells):
        tds = ""
        for (g, n), (y, p) in zip(groups, vals):
            share = (y + 0.5 * p) / n
            extra = f'<span style="color:var(--amberText)">+{p}</span>' if p else ""
            tds += (f'<td class="c num" style="background:rgba(24,152,196,{0.08 + 0.55 * share:.2f});color:var(--ink)">{y}{extra}</td>')
        trs += f'<tr class="{"vb" if name.startswith("Videoboy") else ""}"><td class="f" style="font-weight:700">{E(name)}</td>{tds}</tr>'
    gt = f'<table class="d" style="font-size:11.4px"><tr><th>Offered (+ partial) by category</th>{head}</tr>{trs}</table>'
    body = f"""
<div class="grid" style="grid-template-columns:790px 1fr;gap:32px;margin-top:6px">
 <div><div class="legend" style="margin-bottom:10px"><span><svg width="12" height="12"><rect width="12" height="12" rx="2" fill="#1898C4"/></svg> offered</span>
   <span><svg width="12" height="12"><rect width="12" height="12" rx="2" fill="#0E5A75"/></svg> partial</span>
   <span style="color:var(--ink3)">? = not verified (counted as neither)</span></div>{chart}</div>
 <div class="card"><div class="lbl" style="color:var(--redText)">Rows only Videoboy fills</div><ul style="margin-top:6px">{uniq}</ul>
   <div class="rule"></div>
   <p>TouchDesigner, Resolume and VDMX lead on breadth. MadMapper would likely join them — 12 of its cells are unverified — and Synesthesia's
   short bar mostly reflects 25 unverified cells, not missing features. Videoboy's count is lower because it is a fixed-format instrument;
   it is the only product with a full mark in every row that defines its lane.</p></div>
</div>
<div style="margin-top:12px">{gt}</div>"""
    return Slide("04 · Comparison", "Scoreboard", "Breadth goes to the open tools. Depth in one lane goes to Videoboy.",
                 body=body, src=f"Computed by build_deck.py from deck_data.py LIVE_ROWS ({n_rows} rows); unverified cells excluded; shading = share offered")


# ── inspectors and gaps ────────────────────────────────────────────────────────
def inspectors(coverage):
    cols = [
        ("Resolume · clip / layer", ["Timeline · BPM Sync · SMPTE · Denon", "Loop, Ping Pong, Random, Play Once and Eject / Hold",
                                     "cue points · Beat Looper · Beat Snap", "trigger Normal / Toggle / Piano · Fader Start",
                                     "Auto Pilot after N loops · per-clip transition", "layer: mask mode, lock, solo, bypass, transition 0–10 s"]),
        ("VDMX6 · layer", ["source: movie rate, range, loop; NDI, Syphon, ISF, TD", "FX chain: CI, ISF, FFGL, shape/chroma/layer masks",
                           "vision: background removal, face/body/hand tracking", "composition: 20+ blends, crop, rect or quad map",
                           "any control ← any data source (LFO, audio, clock)", "plugins: Cue List, Scopes, step sequencer"]),
        ("QLab 5 · video cue", ["Basics, Triggers (hotkey, MIDI, timecode, clock)", "Geometry: fit / fill / stretch, or",
                                "crop, translation, scale, 3-D rotation, anchor", "Time & Loops: start/end, loops, hold at end",
                                "Video FX: blend mode + live effect stack", "fade cues for any of it; GO"]),
        ("Millumin 5 · layer", ["media: video, NDI, Syphon, screen, web, text, TOX", "mesh warp, masks at every level, soft edge",
                                "groups with blend / opacity / effects", "custom and shader transitions",
                                "Bezier keyframes on timelines; cues recall a time", "JavaScript; controls ATEM, PJ-Link, PTZ"]),
        ("MadMapper 6 · surface", ["quads, circles, masks, unlimited-point mesh warp", "soft-edge blending", "ISF-based Materials (+ Mad AI)",
                                   "timelines: keyframes, markers, FFT audio track", "MIDI / OSC output tracks · beat tracking",
                                   "Link, MIDI clock, Syphon, NDI"]),
    ]
    cards = "".join(f'<div class="card"><h3>{E(t)}</h3><ul>' + "".join(f"<li>{E(x)}</li>" for x in xs) + "</ul></div>" for t, xs in cols)
    cats, prods, grid = coverage
    head = "".join(f'<th class="c">{E(p)}</th>' for p in prods)
    trs = "".join(f'<tr><td class="f">{E(c)}</td>' + "".join(
        f'<td class="c" style="{"background:rgba(238,64,54,.07)" if j == 0 else ""}">{glyph(v)}</td>' for j, v in enumerate(row)) + "</tr>"
        for c, row in zip(cats, grid))
    cov = f'<table class="d tight" style="font-size:11.4px"><tr><th>Inspector category (from the matrix rows)</th>{head}</tr>{trs}</table>'
    vb = """
<div class="card" style="border-color:rgba(238,64,54,.55);background:rgba(238,64,54,.045)">
 <div class="tag" style="color:var(--redText)">Videoboy · no single inspector</div>
 <div style="font-size:19px;font-weight:900;letter-spacing:-.02em;line-height:1.08;margin:5px 0 6px">Properties live where they act</div>
 <p><b style="color:var(--ink)">Source Controls</b> (speed, scrub, generator parameters) tops each FX panel; every <b style="color:var(--ink)">card</b>
  shows each parameter on two lines with its code and MIDI · AUD · LFO badges; transitions and blends open from their keys. Closer to a hardware
  mixer than to QLab or Resolve — and right for hands.</p>
 <p style="margin-top:6px"><b style="color:var(--redText)">The missing half is geometry and compositing</b>: crop, anchor, opacity and masks in one
  place, most with keyframes. Videoboy's Transform card has scale, position, rotation and flip; layer opacity (66A) has no fader.</p>
</div>"""
    body = (f'<div class="grid g5" style="gap:12px;margin-top:6px">{cards}</div>'
            f'<div class="grid" style="grid-template-columns:1.25fr 1fr;gap:14px;margin-top:12px">{cov}{vb}</div>')
    return Slide("05 · Inspectors", "Inspectors compared", "Their inspectors are where their features live.",
                 body=body, src="Sources: resolume.com/support (clips, video, layers) · vdmx.vidvox.net · qlab.app/docs/v5/video · millumin.com/v5 · docs.madmapper.com")


def gaps_major():
    trs = "".join(f'<tr><td class="num">{i}</td><td class="f" style="font-weight:650">{E(f)}</td><td>{E(w)}</td>'
                  f'<td class="c" style="font-size:14px;letter-spacing:4px;color:var(--ink)">{E(a)}</td><td class="c num">{E(D.GAP_SIZE[i])}</td>'
                  f'<td style="font-size:11px;color:var(--ink3)">{E(n)}</td></tr>' for i, f, w, a, n in D.MAJOR)
    table = ('<table class="d roomy" style="font-size:13px"><tr><th>#</th><th>Missing from Videoboy</th><th>Who has it</th>'
             '<th class="c">VJ · theatre · artist</th><th class="c">Size</th><th>Note</th></tr>' + trs + "</table>")
    top5 = """
<div class="grid g5" style="gap:10px;margin-top:14px">
 <div class="card"><div class="lbl">Build first</div><h3 style="margin-top:4px">Syphon out + OSC</h3><p>cheap; joins every rig</p></div>
 <div class="card"><div class="lbl">Then</div><h3 style="margin-top:4px">Hot cues</h3><p>the biggest performance gap</p></div>
 <div class="card"><div class="lbl">Then</div><h3 style="margin-top:4px">Undo</h3><p>the owner already called it a bug</p></div>
 <div class="card"><div class="lbl">Then</div><h3 style="margin-top:4px">Presets / snapshots</h3><p>as Setlists and E-MEMs</p></div>
 <div class="card"><div class="lbl">Then</div><h3 style="margin-top:4px">MIDI clock + Link</h3><p>follow the booth</p></div>
</div>"""
    return Slide("05 · Gaps", "Major gaps", "Twelve things a VJ, a theatre designer or a video artist would miss.",
                 dek="● essential · ◐ useful · ○ rarely needed — for VJs, theatre video designers and video artists, in that order. "
                     "Size: S ≈ a day, M ≈ a few days, L ≈ a week or more (author's estimate). DMX left out, as asked.",
                 body=table + top5, src="Source: docs/research/2026-10-01/03-competitors-and-gaps.md §3.1 · sizes are the author's estimates")


def gaps_minor():
    trs = "".join(f'<tr><td class="num">{i}</td><td class="f">{E(f)}</td><td>{E(w)}</td></tr>' for i, f, w in D.MINOR)
    left = ('<table class="d roomy" style="font-size:12.6px"><tr><th>#</th><th>Missing, minor</th><th>Who has it</th></tr>' + trs + "</table>")
    ahead = [(f, w.replace("none in VJ software", "no Add / Move / Copy importer in VJ tools")
              .replace("XML project files", "project files not designed for hand edits")) for f, w in D.AHEAD]
    trs2 = "".join(f'<tr><td class="f">{E(f)}</td><td>{E(w)}</td></tr>' for f, w in ahead)
    right = ('<table class="d roomy" style="font-size:12.6px"><tr><th>Videoboy is ahead</th><th>Nearest competitor</th></tr>' + trs2 + "</table>")
    body = f'<div class="grid g2" style="gap:36px;margin-top:6px"><div>{left}</div><div>{right}</div></div>'
    return Slide("05 · Gaps", "Minor gaps — and where Videoboy leads", "Fifteen nice-to-haves. Ten things nobody else does.",
                 body=body, src="Source: 03-competitors-and-gaps.md §3.2–3.3 · competitor documentation (appendix)")


# ── interface ──────────────────────────────────────────────────────────────────
def _wf(boxes, h=420):
    return f'<div class="frame" style="height:{h}px">' + "".join(
        f'<div class="b {c}" style="left:{x}%;top:{y}%;width:{w}%;height:{hh}%;font-size:9.4px;hyphens:manual;overflow:hidden">{t}</div>' for x, y, w, hh, t, c in boxes) + "</div>"


def interface_compare():
    vb = _wf([(0, 0, 100, 8, "PADS 1–4 · TRANSPORT · PADS 5–8", "hi"), (0, 9, 13, 27, "SRC A/B", "am"), (14, 9, 23, 27, "SUB MIX ONE", "am"),
              (38, 9, 24, 27, "PROGRAM", "hi"), (63, 9, 23, 27, "SUB MIX TWO", "cy"), (87, 9, 13, 27, "SRC C/D", "cy"),
              (0, 37, 13, 55, "A/B FX", "am"), (14, 37, 23, 9, "A/B ROW", ""), (38, 37, 24, 9, "1 / 2 ROW", "hi"),
              (63, 37, 23, 9, "C/D ROW", ""), (87, 37, 13, 55, "C/D FX", "cy"), (14, 47, 23, 37, "LIBRARY", ""),
              (38, 47, 24, 37, "ASSET BROWSER", ""), (63, 47, 23, 37, "LIBRARY", ""), (14, 85, 72, 7, "OUTPUT BAR", ""),
              (0, 93, 100, 7, "MODE BAR", "hi")])
    logic = _wf([(0, 0, 100, 9, "CONTROL BAR · LCD", ""), (0, 10, 14, 60, "LIB.", ""), (15, 10, 17, 60, "INSPEC&shy;TOR", "cy"),
                 (33, 10, 50, 60, "TRACKS · LIVE LOOPS", ""), (84, 10, 16, 60, "BROWSE", ""), (0, 71, 100, 29, "EDITORS · MIXER · SMART CONTROLS", "")])
    resolve = _wf([(0, 0, 100, 8, "TOOLBAR · PANEL TOGGLES", ""), (0, 9, 22, 45, "MEDIA POOL", ""), (23, 9, 27, 45, "SOURCE", ""),
                   (51, 9, 27, 45, "TIMELINE VIEWER", ""), (79, 9, 21, 45, "INSPEC&shy;TOR", "cy"), (0, 55, 100, 35, "TIMELINE", ""),
                   (0, 91, 100, 9, "PAGE BAR · 8 PAGES", "hi")])
    premiere = _wf([(0, 0, 100, 8, "WORKSPACES", ""), (0, 9, 37, 44, "SOURCE · EFFECT CONTROLS", ""), (38, 9, 41, 44, "PROGRAM", ""),
                    (80, 9, 20, 44, "PROPER&shy;TIES", "cy"), (0, 54, 30, 46, "PROJECT · MEDIA", ""), (31, 54, 63, 46, "TIMELINE", ""),
                    (95, 54, 5, 46, "", "")])
    vdmx = _wf([(2, 3, 34, 28, "MEDIA BIN", ""), (40, 2, 26, 24, "LAYER 1", ""), (69, 5, 29, 28, "OUTPUT PREVIEW", ""),
                (3, 38, 28, 28, "CONTROL SURFACE", ""), (34, 32, 22, 20, "LFO", ""), (58, 40, 22, 22, "AUDIO ANALYSIS", ""),
                (10, 72, 36, 24, "WORKSPACE INSPECTOR", "cy"), (52, 68, 30, 26, "UI INSPECTOR", "cy"), (84, 40, 14, 20, "CLOCK", "")])
    cards = [("Videoboy 0.4.10", vb, "Fixed 5×5 grid that collapses but never moves. Seven live monitors. Properties sit on the cards and keys."),
             ("Logic Pro 12", logic, "One window with areas shown or hidden; Inspector at left; tracks or a Live Loops grid in the centre."),
             ("DaVinci Resolve 21", resolve, "Fixed page layouts behind a page bar — the model Videoboy's mode bar copied. Inspector at right."),
             ("Premiere Pro 26", premiere, "Dockable panels saved as workspaces; Source and Program monitors; the new Properties panel."),
             ("VDMX6", vdmx, "Floating plugin windows the user arranges; two inspector windows; any control takes any data source.")]
    html = "".join(f'<div class="wf"><h3>{E(t)}</h3>{f}<p style="font-size:12.6px">{E(d)}</p></div>' for t, f, d in cards)
    body = f'<div class="grid g5" style="gap:12px;margin-top:8px">{html}</div>' + """
<div class="legend" style="margin-top:12px"><span style="color:var(--cyanText)">■ where properties are edited</span>
<span style="color:var(--redText)">■ mode / page / program</span><span>Schematic wireframes drawn for this report from each product's documented layout, not screenshots.</span></div>"""
    return Slide("06 · Interface", "Five windows compared", "Five apps, five ideas about where things go.", body=body,
                 src="Layouts from: Apple Logic Pro user guide · Blackmagic DaVinci Resolve 21 · Adobe Premiere Pro 26 release notes · vdmx.vidvox.net tutorials · Videoboy SPEC §14")


def interface_matrix():
    head = "".join(f'<th style="width:262px">{E(p)}</th>' for p in D.UI_PRODUCTS)
    trs = "".join(f'<tr><td class="lbl" style="width:120px">{E(r)}</td>' + "".join(
        f'<td class="{"f" if i == 0 else ""}" style="{"background:rgba(238,64,54,.06)" if i == 0 else ""}">{E(v)}</td>'
        for i, v in enumerate(vals)) + "</tr>" for r, vals in D.UI_ROWS)
    table = f'<table class="d roomy" style="font-size:12.6px"><tr><th></th>{head}</tr>{trs}</table>'
    return Slide("06 · Interface", "Interface paradigms", "A fixed window, like Resolve and Logic — not Premiere's docks or VDMX's floats.",
                 dek="The fixed grid is a performance decision: a performer's hands are on the controls, so nothing may move. It is the deliberate break "
                     "from VDMX, and the reason Videoboy can't simply add panels.",
                 body=table, src="Sources: as previous page · Videoboy CLAUDE.md \"Layout is fixed\" · SPEC §14")


def interface_borrow():
    cards = "".join(f'<div class="card"><div class="tag">{E(p)}</div><h3 style="margin-top:4px">Borrow next</h3><p>{E(b)}</p>'
                    f'<div class="rule"></div><div class="lbl">Already borrowed</div><p style="margin-top:3px">{E(a)}</p></div>'
                    for p, b, a in D.UI_BORROW)
    extra = """
<div class="grid g3" style="gap:12px;margin-top:12px">
 <div class="card"><h3>A geometry drawer, not an inspector window</h3><p>Resolve-style tabs (Transform · Crop · Composite) that slide out of a
 source panel's title bar on demand — the M9 gap closed without breaking the fixed grid.</p></div>
 <div class="card"><h3>Smart Controls for a whole bank</h3><p>Logic maps one knob to many parameters. A bank macro (one fader sweeps mosh,
 feedback zoom and hue together) is the cheapest performance preset there is, and Settings ▸ Macros &amp; AI already exists.</p></div>
 <div class="card"><h3>Profiles instead of workspaces</h3><p>Premiere lets every user rebuild the room. Videoboy can't, so it should offer states:
 a DJ profile (pads in cue mode), a broadcast profile (Program/Preview on the 1/2 row), a theatre profile (rundown).</p></div>
</div>"""
    heads = "".join(f'<th class="c">{E(p)}</th>' for p in D.UI_PRODUCTS)
    trs = "".join(f'<tr><td class="f" style="font-weight:700">{E(q)}</td>' + "".join(
        f'<td class="c" style="{"background:rgba(238,64,54,.06)" if j == 0 else ""}">{dots(v)}</td>' for j, v in enumerate(vals)) +
        f'<td style="font-size:10.5px;color:var(--ink3)">{E(why)}</td></tr>' for q, vals, why in D.UI_RATINGS)
    score = (f'<div class="lbl" style="margin:14px 0 4px;color:var(--redText)">Interface scorecard — the author\'s ratings, 1–5 (opinion)</div>'
             f'<table class="d tight" style="font-size:11.6px"><tr><th>Quality</th>{heads}<th>Why, for Videoboy</th></tr>{trs}</table>')
    body = f'<div class="grid g4" style="gap:12px;margin-top:6px">{cards}</div>{extra}{score}'
    return Slide("06 · Interface", "What to take from each", "Steal the ideas, keep the grid.", body=body,
                 src="Sources: as previous pages · Videoboy docs/DESIGN-BACKLOG.md, docs/PROPOSAL-2026-09-26.md (already borrowed) · ratings are the author's")


# ── broadcast and DJ, vocabulary ───────────────────────────────────────────────
def two_worlds():
    rows = [
        ("Inside a clip", "8 hot cues, memory cues, loops, beat jump, slip", "cue points marked on the fly (EVS)", "one in/out pair"),
        ("Before it airs", "CUE / PFL in the headphones", "Preview bus + multiviewer", "sub-mix monitors"),
        ("Taking it", "crossfader + curve, quantise", "CUT / AUTO / T-bar, RATE per style, stingers", "CUT / FADE / 13 patterns, beat-quantised ●"),
        ("On top", "—", "keyers + downstream keyers with own CUT / AUTO", "Key blend on a fader"),
        ("Remembering a look", "—", "E-MEM: learn the whole state, recall in one press", "show files; Setlists planned"),
        ("Running order", "playlists, history, smart crates", "rundown (reader · VO · SOT · PKG), back-timing, MOS", "Queue (new); Setlists planned"),
        ("After the show", "recording of the mix", "ISO recordings + a project of every cut", "ISO recordings ●, no cut list"),
        ("Talking to other gear", "Pro DJ Link, StageLinQ, Link, MIDI clock, SMPTE", "tally, GPI, timecode, MOS", "MIDI in only"),
    ]
    trs = "".join(f'<tr><td class="lbl">{E(a)}</td><td>{E(b)}</td><td>{E(c)}</td><td class="f" style="background:rgba(238,64,54,.06)">{E(d)}</td></tr>'
                  for a, b, c, d in rows)
    table = ('<table class="d roomy" style="font-size:13.4px"><tr><th style="width:170px"></th><th>DJs have</th><th>Broadcast has</th>'
             '<th>Videoboy has</th></tr>' + trs + "</table>")
    note = """
<div class="grid g3" style="gap:12px;margin-top:14px">
 <div class="card"><h3>The DJ's clock</h3><p>Videoboy already thinks in beats: BPM, DIV, BEAT, quantised pads and sweeps, a neural beat tracker
 on any app's audio. What it lacks from DJing is <b style="color:var(--ink)">preparation inside the media</b>: hot cues, loops in beats, slip.</p></div>
 <div class="card"><h3>The switcher's discipline</h3><p>Bus keys, Hot Punch ("hot punching" is cutting directly on the program bus), A/B ROLL,
 tally and ISO recording are broadcast behaviour. What it lacks is <b style="color:var(--ink)">memory</b>: E-MEMs, a DSK, a rundown, and the edit export.</p></div>
 <div class="card"><h3>The editor's afterlife</h3><p>Three-point editing, splice-in vs overwrite, markers and EDL/XML interchange are how a
 broadcast editor thinks. Videoboy already shares the source-monitor half; a <b style="color:var(--ink)">cut list</b> gives it the record half.</p></div>
</div>"""
    return Slide("07 · Broadcast + DJ", "Deep dive · two worlds", "A DJ's clock and a switcher's routing. Missing: memory.",
                 body=table + note, src="Sources: ATEM manual · GV Kayenne concepts · NYFA · Rundown Creator · EVS LSM manual · CasparCG · rekordbox 7 · DJ glossaries · Videomaker / Zettl (01-broadcast-and-dj-deep-dive.md)")


def borrowings():
    items = [
        ("5.1", "Hot cues per clip", "DJ", "M", "8 coloured cues in the catalog, beat-quantised jumps, later auto-placed at shot changes"),
        ("5.2", "Cut list with every recording", "Broadcast", "S–M", "EDL + FCPXML beside the ISO files: the ATEM ISO idea without a .drp"),
        ("5.3", "Look memories (E-MEM)", "Broadcast", "M", "learn / recall in one press, numbered slots, partial recall; obeys LOCK"),
        ("5.4", "Downstream key layer", "Broadcast", "M", "own CUT / AUTO / rate after Program for titles, Now Playing, Scala, logos"),
        ("5.5", "One title model", "Broadcast", "S", "PLAY animates in, NEXT steps, STOP animates out, UPDATE swaps data"),
        ("5.6", "Beat from DJ gear", "DJ", "M each", "MIDI clock in, then Ableton Link; Pro DJ Link / StageLinQ only for track data"),
        ("5.7", "Preview discipline", "Both", "S–M", "CUE key per source (PFL), optional Program/Preview on 1/2, tally out over MIDI"),
        ("5.8", "Rates, DIP, stingers, soft edges", "Broadcast", "S–M", "a rate per transition style; DIP to colour; alpha-clip stingers; soft wipes"),
        ("5.9", "Loops in beats, roll, slip", "DJ", "M", "1/4–16 beat loops, momentary roll, slip for any momentary action"),
        ("5.10", "Rundown with back-timing", "Broadcast", "M", "Setlists with lengths, back-timed from a show end time"),
        ("5.11", "Controller ergonomics", "DJ", "S each", "Center Lock on bipolar knobs, fader curves, kill switches, MIDI LED feedback"),
        ("5.12", "Audio-linked FX presets", "DJ video", "S", "Serato's idea: onset → Freeze pulse, lows → feedback zoom, in one click"),
    ]
    trs = "".join(f'<tr><td class="num">{a}</td><td class="f" style="font-weight:700">{E(b)}</td><td>{E(c)}</td>'
                  f'<td class="c num">{E(d)}</td><td>{E(e)}</td></tr>' for a, b, c, d, e in items)
    table = ('<table class="d roomy" style="font-size:12.6px"><tr><th>§</th><th>Borrow</th><th>From</th><th class="c">Size</th><th>What it is</th></tr>'
             + trs + "</table>")
    side = """
<div class="grid g3" style="gap:12px;margin-top:12px">
 <div class="card"><h3>Not recommended</h3><p>Audio output (the app is silent by design; DJs own audio), a full NLE timeline (the cut list gets the
 benefit), a newsroom / MOS integration (a different product).</p></div>
 <div class="card"><h3>Rule 1 · behaviours, not looks</h3><p>Every item is about how a performer cues, takes and remembers. The look stays analog,
 bitstream and NTSC.</p></div>
 <div class="card"><h3>Rule 2 · profiles, not clutter</h3><p>New behaviour arrives as states of existing keys or as modes on the mode bar, never as
 floating panels. S ≈ a day, M ≈ a few days.</p></div>
</div>"""
    return Slide("07 · Broadcast + DJ", "Deep dive · what to borrow", "Twelve borrowings, ranked by what they unlock.",
                 body=table + side, src="Source: docs/research/2026-10-01/01-broadcast-and-dj-deep-dive.md §5–6")


def vocab_core():
    rows = [
        ("Source A–D", "deck ≈", "input / source ✓"), ("Bank (A/B, C/D)", "deck layer ≈", "M/E bank ✓"),
        ("Sub Mix · ONE / TWO", "the two-deck mix ≈", "M/E · ME1 / ME2 ✓"), ("Program", "master ≈", "Program (PGM) ✓"),
        ("CUT", "cut ✓", "CUT ✓"), ("FADE", "crossfade ✓", "AUTO / MIX ≈"), ("BEAT", "quantize ≈", "—"),
        ("crossfader", "crossfader ✓", "T-bar ≈"), ("transition key · AVE-5", "—", "transition style · wipes ✓"),
        ("Hot Punch (!)", "—", "hot punching ✓"), ("ROLL", "loop roll ⚠", "A/B roll · roll VT ✓"),
        ("ADV", "auto-load next ≈", "next playlist item ≈"), ("tally", "ON AIR ✓", "tally ✓"),
        ("Queue · Play Next / Last", "queue ✓", "clip-server playlist ≈"), ("Clip Pads", "sampler pads ≈ · hot-cue pads ⚠", "—"),
        ("AUTO (library)", "auto-play ≈", "AUTO transition ⚠"), ("bin · catalog", "crate · collection ✓", "bin · MAM ✓"),
        ("focus A · B · MIX", "Beat FX channel select ✓", "—"), ("rate key", "beat select ✓", "transition RATE ✓"),
        ("CLOCK · Detect · Learn", "sync source · analyse · MIDI learn ✓", "reference · — · panel map ≈"),
        ("DATA BURN · FILE / TC", "—", "burn-in · UMD ✓"), ("Safe · Overscan · Test Pat", "—", "safe area · overscan · bars ✓"),
        ("Setlist (planned)", "setlist = song order ⚠", "E-MEM ≈"), ("LOCK (planned)", "LOAD LOCK ✓", "panel lock ✓"),
        ("TAKE (EMU)", "—", "TAKE = put on air ⚠ · CG UPDATE"),
    ]

    def cell(v):
        v = E(v)
        return (v.replace("✓", '<span style="color:var(--ink)">✓</span>').replace("≈", '<span style="color:var(--amberText)">≈</span>')
                 .replace("⚠", '<span style="color:var(--redText)">⚠</span>'))
    half = (len(rows) + 1) // 2

    def table(rs):
        trs = "".join(f'<tr><td class="f" style="font-weight:700">{E(a)}</td><td>{cell(b)}</td><td>{cell(c)}</td></tr>' for a, b, c in rs)
        return ('<table class="d roomy" style="font-size:12.6px"><tr><th>Videoboy</th><th>DJ</th><th>Broadcast news</th></tr>' + trs + "</table>")
    body = (f'<div class="legend" style="margin:2px 0 8px"><span style="color:var(--ink)">✓ same meaning</span>'
            f'<span style="color:var(--amberText)">≈ close relative</span><span style="color:var(--redText)">⚠ false friend</span></div>'
            f'<div class="grid g2" style="gap:30px">{table(rows[:half])}{table(rows[half:])}</div>')
    return Slide("08 · Vocabulary", "Vocabulary · three worlds", "Most of Videoboy's words already mean the right thing.",
                 body=body, src="Source: docs/research/2026-10-01/02-vocabulary.md (terms from App/Sources UI strings) · DJ glossaries · ATEM, Kayenne, Zettl, CDJ-3000 manual")


def vocab_fixes():
    fixes = [
        ("Setlist", "To every DJ and band a setlist is the running order of songs. Videoboy's is one bank's state — the broadcast E-MEM.",
         "Keep (owner-set). Tooltip: \"a bank's look\". Watch for confusion; Scene, Look or Memory are the fallbacks."),
        ("AUTO (library)", "Means autoplay-on-load here; on a switcher AUTO runs the transition.", "AUTOPLAY, or a ▶ glyph."),
        ("TAKE (EMU)", "Repaints the Amiga's page here; broadcast TAKE puts the next element on air.", "UPDATE (the CG word for exactly this) or SEND."),
        ("ROLL", "Right for broadcast (A/B roll, roll VT); a DJ's loop roll is a momentary stutter.", "Keep; if loop roll ships, call it STUTTER."),
        ("Clip Pads", "Launch whole clips; DJs expect pads to be hot cues inside a track.", "When hot cues ship, give the pads modes: Clips · Cues."),
        ("Detect", "UI: beat detection. SPEC §7 and DetectSession still call MIDI learn \"shift-to-detect\".", "Docs say Learn; code names can follow."),
        ("VJ (mode)", "CLAUDE.md says Videoboy is not a VJ tool, and the owner wants a room for many creatives.", "LIVE (or SHOW), beside IMPORT and SETTINGS."),
        ("FADE", "Broadcast users look for AUTO beside CUT.", "Keep FADE; tooltip \"(AUTO on a switcher)\"."),
    ]
    cards = "".join(f'<div class="card" style="padding:16px 18px"><div class="tag" style="color:var(--redText);font-size:12px">{E(t)}</div><p style="margin-top:7px;font-size:14px;line-height:1.45">{E(w)}</p>'
                    f'<div class="rule" style="margin:11px 0"></div><p style="font-size:14px;line-height:1.45"><b style="color:var(--ink)">Fix:</b> {E(f)}</p></div>'
                    for t, w, f in fixes)
    foot = """
<div class="card" style="margin-top:14px;display:grid;grid-template-columns:260px 1fr;gap:20px;align-items:center">
 <div style="font-size:21px;font-weight:900;letter-spacing:-.02em;line-height:1.08">The cheap fix for all of them</div>
 <p style="font-size:13.4px">Put the other worlds' words in the tooltips, the way the AVE-5 popover quotes the hardware manual:
 <i>"FADE — an automatic transition at the FADE rate (AUTO on a switcher, a blend on a DJ mixer)."</i> Nothing moves, nobody relearns anything,
 and a DJ or a TD finds their own word under the pointer.</p>
</div>"""
    return Slide("08 · Vocabulary", "Vocabulary · false friends", "Eight words that will trip someone up.",
                 body=f'<div class="grid g4" style="gap:12px;margin-top:6px">{cards}</div>{foot}',
                 src="Source: 02-vocabulary.md §5 · App/Sources/Videoboy/UI (LibraryPanelBody AUTO, EmuBrowserView TAKE) · docs/PROPOSAL-2026-09-28-setlist.md")


# ── roadmap (owner) ────────────────────────────────────────────────────────────
def roadmap():
    tones = {"SHIPPED": "var(--ink3)", "NOW": "var(--redText)", "NEXT": "var(--amberText)", "THEN": "var(--cyanText)",
             "ALSO ASKED FOR": "var(--ink2)", "OPEN": "var(--ink2)"}
    cols = []
    for name, when, items in D.ROADMAP:
        lis = "".join(f'<li style="font-size:12.2px">{E(i)}</li>' for i in items)
        cols.append(f'<div class="phase"><div class="when">{E(when)}</div><h4 style="color:{tones[name]}">{E(name)}</h4><ul>{lis}</ul></div>')
    arrow = ('<svg width="100%" height="22" viewBox="0 0 1472 22" preserveAspectRatio="none"><line x1="0" y1="11" x2="1460" y2="11" '
             'stroke="#34343F" stroke-width="2"/><path d="M1460,4 L1472,11 L1460,18 z" fill="#34343F"/></svg>')
    est = hbars([("0 · Names + Queue (done)", 0.5, ""), ("1 · LOCK", 1.5, ""), ("2 · Playlists + Lists tab", 1.5, ""),
                 ("3 · Setlists", 3.5, ""), ("4 · Song linking", 1.5, "")], width=640, bar_h=16, gap=9, label_w=200, color="#C08000",
                fmt=lambda v, c: f"~{v:g} d")
    body = f"""
{arrow}
<div class="tl" style="grid-template-columns:1.05fr .9fr 1.05fr 1fr 1.1fr 1fr;margin-top:6px">{"".join(cols)}</div>
<div class="grid" style="grid-template-columns:680px 1fr;gap:20px;margin-top:14px">
 <div class="card"><div class="lbl" style="margin-bottom:8px">The setlist plan by its own estimates — about 8½ days in all</div>{est}
  <p style="font-size:11px;color:var(--ink3);margin-top:6px">0.4.11 (any canvas) ~2.5k lines and 0.5.0 (tags) ~1.8k lines, per PROPOSAL-2026-09-26 §9.</p></div>
 <div class="dense" style="padding-top:2px">
  <div class="quote">From the setlist proposal (owner-set 2026-09-29): "Each word has one meaning." LOCK comes first "because it doesn't depend on
  anything else, it's useful the day it ships, and it's what makes an automatic song trigger safe to use."</div>
  <div class="quote" style="margin-top:10px">From the corruptor's flag comment in VideoboyCore.swift: "It is off rather than deleted … Whatever it becomes
  next will start from the working version rather than from a rewrite."</div>
 </div>
</div>"""
    return Slide("09 · Roadmap", "The roadmap — as the owner has set it", "LOCK, Playlists, Setlists, songs. Then any canvas, then tags.",
                 dek="Everything on this page comes from the project's planning documents, which the owner approved or set — the build plan, the two "
                     "proposals, the backlogs and the flag notes — with their dates and estimates. None of it is the author's opinion.",
                 body=body, src="Sources: docs/BUILD-PLAN.md · docs/PROPOSAL-2026-09-26.md §9 · docs/PROPOSAL-2026-09-28-setlist.md §1, §9–10 · docs/FEATURE-LEDGER-2026-09-27.md · VideoboyCore.swift")


# ── what I would do ────────────────────────────────────────────────────────────
def me_generalist():
    cols = [
        ("1 · Turn the wedge back on", [
            "The MPEG corruptor — the reason the app exists — ships switched off because nobody can judge it without an analog chain.",
            "Build the judging rig into the app: Program → HDMI→RCA → DVC100 → capture → a side-by-side monitor. The self-QA loopback already does the hard part.",
            "Ship it as an Experimental card the day it can be judged."]),
        ("2 · Trust before features", [
            "Undo for parameter changes and loads (the owner called its absence \"a consistent bug\").",
            "LOCK as designed, then hot cues.",
            "Write the 1.0 bar that exists only in chat: per-canvas stress and soak gates, a person's click-through of every mode, a manual, crash reports."]),
        ("3 · Plumbing that multiplies", [
            "Syphon out, OSC in/out, MIDI clock and Ableton Link. Days each, not weeks.",
            "Each one lets Videoboy join rigs it will never replace: Resolume, VDMX, QLab, Ableton, the booth."]),
        ("4 · Name it for what it is", [
            "Rename the VJ mode to LIVE; fix AUTO, TAKE and the docs' \"detect\".",
            "Put DJ and broadcast synonyms in every tooltip.",
            "Lead every description with the wedge and the analog output, not the mixer."]),
        ("5 · Protect the code", [
            "Split ShellController (3,116 lines in September, 3,778 today) into a controller per mode, as the 09-26 proposal planned.",
            "Refresh STATUS.md and TODO.md, which describe v0.4.0.",
            "Make build scripts fail loudly instead of rebuilding a signing keychain they cannot read — a sandboxed build check on 2026-10-01 deleted it."]),
    ]
    cards = "".join(f'<div class="card"><h3>{E(t)}</h3><ul>' + "".join(f'<li style="font-size:12.6px">{E(x)}</li>' for x in xs) + "</ul></div>"
                    for t, xs in cols)
    wont = ["projection mapping, warping or edge blending", "audio output", "3-D or a generative node graph", "floating or dockable panels",
            "a full NLE timeline", "DMX or lighting"]
    risks = [("Scope creep", "every gap closed for one audience widens the app; the wedge must stay the reason to buy"),
             ("A narrow niche", "SD-first and Mac-only (Apple Silicon) is a feature for the core user and a ceiling for growth"),
             ("Frame budget at HD", "0.4.11 multiplies pixels ~6×; the ½-resolution fallback is the safety net"),
             ("Distribution", "no signing or notarization today; nobody else can run a release"),
             ("One maintainer", "80k lines written largely by AI sessions — the docs and 867 tests are the insurance")]
    w = "".join(f'<li style="font-size:12.4px;color:var(--ink2);margin:3px 0">{E(x)}</li>' for x in wont)
    r = "".join(f'<tr><td class="f" style="font-weight:700;width:150px">{E(a)}</td><td>{E(b)}</td></tr>' for a, b in risks)
    body = (f'<div class="grid g5" style="gap:12px;margin-top:6px">{cards}</div>'
            f'<div class="grid" style="grid-template-columns:1fr 2fr;gap:12px;margin-top:12px">'
            f'<div class="card"><div class="lbl" style="color:var(--redText)">What I would not build</div><ul style="margin-top:6px">{w}</ul></div>'
            f'<div class="card"><div class="lbl">Risks I would watch</div><table class="d" style="font-size:12px;margin-top:4px">{r}</table></div></div>'
            f'<div class="card" style="margin-top:12px;border-color:rgba(238,64,54,.55);display:grid;grid-template-columns:240px 1fr;gap:22px;align-items:center">'
            f'<div class="tag" style="color:var(--redText)">The one-line version</div>'
            f'<p style="font-size:14.5px;color:var(--ink)">Make the wedge undeniable, make the app trustworthy, and wire it into other people\'s rigs — '
            f'before adding anything that only widens it.</p></div>')
    return Slide("10 · What I would do", "What I would do · as a generalist", "Make the wedge undeniable, then open the doors.",
                 body=body, src="The author's view. Facts from: VideoboyCore.swift (flags) · BUILD-PLAN take-backs entry · FEATURE-LEDGER §4 · PROPOSAL-2026-09-26 §6, §10 · wc -l ShellController.swift")


def me_market():
    body = """
<div class="grid" style="grid-template-columns:1fr 1fr 1fr;gap:12px;margin-top:6px">
 <div class="card"><div class="tag">Position</div><h3 style="margin-top:4px">Sell the instrument</h3>
  <p style="font-size:12.8px">Don't fight Resolume on breadth. Own <b style="color:var(--ink)">"the analog instrument"</b>: musicians and DJs who want pictures with
  character, video artists, music-video directors, streamers chasing tape. Lead with the wedge, the NTSC chain and the vintage titler — the three
  things no competitor has.</p></div>
 <div class="card"><div class="tag">Price</div><h3 style="margin-top:4px">Copy the model VJs already accept</h3>
  <ul><li style="font-size:12.6px">Perpetual licence around <b style="color:var(--ink)">$249</b> with 12 months of updates; renewal around <b style="color:var(--ink)">$79</b> (the Resolume / Synesthesia pattern).</li>
  <li style="font-size:12.6px">Education at 50% (Resolume's rate).</li><li style="font-size:12.6px">Tour rental around <b style="color:var(--ink)">$29 a week</b> per machine (Millumin's precedent).</li>
  <li style="font-size:12.6px">A free, watermarked demo (Resolume, MadMapper and Synesthesia all have one).</li></ul></div>
 <div class="card"><div class="tag">License the sound</div><h3 style="margin-top:4px">The engine may be worth more than the app</h3>
  <ul><li style="font-size:12.6px"><b style="color:var(--ink)">Plug-ins for editors:</b> the NTSC composite model and the datamosh as FxPlug (Final Cut, Motion), OFX (Resolve) and
  Premiere effects. The editing audience is far larger than the VJ audience.</li>
  <li style="font-size:12.6px"><b style="color:var(--ink)">An ISF / FFGL pack</b> for Resolume, VDMX and MadMapper users.</li>
  <li style="font-size:12.6px"><b style="color:var(--ink)">OEM to DJ software:</b> audio-linked video FX is Serato Video's pitch; a real bitstream datamosh locked to the beat is
  not in any DJ app's documented effects.</li></ul></div>
</div>
<div class="grid" style="grid-template-columns:1.1fr 1fr 1fr;gap:12px;margin-top:12px">
 <div class="card"><div class="tag">Illustrative arithmetic — sizes the decision, not a forecast</div>
  <table class="d" style="font-size:12px;margin-top:6px"><tr><th>Line</th><th class="r">Units / yr</th><th class="r">Price</th><th class="r">Revenue / yr</th></tr>
  <tr><td class="f">App licences</td><td class="r num">1,000</td><td class="r num">$249</td><td class="r num">$249,000</td></tr>
  <tr><td class="f">Renewals (40% of base)</td><td class="r num">400</td><td class="r num">$79</td><td class="r num">$31,600</td></tr>
  <tr><td class="f">Editor plug-in</td><td class="r num">3,000</td><td class="r num">$99</td><td class="r num">$297,000</td></tr>
  <tr><td class="f">Tour rentals</td><td class="r num">300 weeks</td><td class="r num">$29</td><td class="r num">$8,700</td></tr></table>
  <p style="font-size:11px;color:var(--ink3);margin-top:7px">Units are placeholders chosen to show proportions: a plug-in line could rival the app on a fraction of the
  effort. No market-size data was found that would make these a forecast.</p></div>
 <div class="card"><div class="tag">Who buys first, and where to find them</div>
  <ul><li style="font-size:12.4px"><b style="color:var(--ink)">Musicians who perform with visuals</b> — through the gear they already own: capture boxes, HDMI→RCA converters, MIDI controllers.</li>
  <li style="font-size:12.4px"><b style="color:var(--ink)">Glitch and tape artists</b> — where the looks travel: short video, art-school workshops, festival VJ lineups.</li>
  <li style="font-size:12.4px"><b style="color:var(--ink)">DJs adding a screen</b> — via song linking with Apple Music now, the booth's protocols later.</li>
  <li style="font-size:12.4px"><b style="color:var(--ink)">Editors</b> — via the plug-in, which then sells the app.</li></ul></div>
 <div class="card"><div class="tag" style="color:var(--redText)">Before any sale</div>
  <ul><li style="font-size:12.4px"><b style="color:var(--ink)">Distribution needs Developer ID signing and notarization</b> — CLAUDE.md currently rules both out. That is the
  first business decision.</li>
  <li style="font-size:12.4px">Licences are in order and must stay so: FFmpeg built LGPL-only (the build fails on GPL), BeatNet weights CC BY 4.0 with attribution
  shipped, Amiberry (GPL) out of process, ROMs and disks user-supplied.</li>
  <li style="font-size:12.4px">Apple Music / Spotify features need the user's Automation permission; say so up front.</li></ul></div>
</div>"""
    return Slide("10 · What I would do", "What I would do · market and money", "Sell the instrument. License the sound.",
                 body=body, src="The author's view. Price anchors: resolume.com/shop · synesthesia.live/pricing · millumin.com/v5 · docs/THIRD-PARTY.md · CLAUDE.md")


def me_artist():
    phases = [
        ("Before the show", [
            "Import with Copy + Optimize (MPEG-2 GOP 6) so every clip is wedge-ready and loops cleanly.",
            "Mark the shots that matter (today: in/out; with hot cues: eight per clip).",
            "One Setlist per song: two Playlists, the bank's FX and pads; link each to its song in Music.",
            "Pads 1–8 hold the hit shots: logo, strobe, crowd, the one perfect frame."]),
        ("Soundcheck", [
            "CLOCK = the DJ's app or System Audio; Detect until it locks; fix 3:2 locks (×2 / ÷2 wanted).",
            "Program to the HDMI→RCA chain; check legality on the scopes.",
            "Arm REC: Program + A/B/C/D, one folder per take.",
            "LOCK the bank you won't touch (planned)."]),
        ("The show", [
            "Verses: FADE between 1 and 2, beat-quantised. Choruses: CUT on the bar.",
            "A/B ROLL keeps both sources rolling so every cut lands on moving footage; ADV feeds the next clip from the Queue.",
            "Hits: Hot Punch a pad straight to air.",
            "Drops: hold MOSH for a bar, HEAL on the downbeat.",
            "Song changes: the linked Setlist lands on the off-air bank and Punches in; Now Playing fades its lower third."]),
        ("After", [
            "The take folder holds Program and every source.",
            "With a cut list (EDL / FCPXML) the night becomes a timeline in Resolve or Premiere — re-cut, colour, deliver.",
            "DATA BURN a reference copy with timecode for the band."]),
    ]
    cols = "".join(f'<div class="phase"><h4>{E(n)}</h4><ul>' + "".join(f'<li style="font-size:11.8px">{E(x)}</li>' for x in xs) + "</ul></div>"
                   for n, xs in phases)
    wants = ["Hot cues, and a Cues mode on the pads", "CUE-to-preview per source (DJ PFL)", "Cut list export with the ISO files",
             "Tally and armed states on the controller's LEDs (MIDI out)", "\"Next song ready\" in the Setlist strip",
             "×2 / ÷2 and a downbeat nudge beside the tempo"]
    w = "".join(f'<li style="font-size:12.2px;color:var(--ink2);margin:2px 0"><b style="color:var(--ink)">{i + 1}.</b> {E(x)}</li>' for i, x in enumerate(wants))
    trs = "".join(f'<tr><td class="f" style="font-weight:700">{E(a)}</td><td class="num">{E(b)}</td><td>{E(c)}</td><td>{E(d)}</td><td>{E(e)}</td><td>{E(f)}</td></tr>'
                  for a, b, c, d, e, f in D.CUE_SHEET)
    sheet = ('<table class="d" style="font-size:11.4px"><tr><th>Song</th><th>BPM</th><th>Setlist (bank)</th><th>Start up</th><th>Sources and pads</th>'
             '<th>Moments</th></tr>' + trs + "</table>")
    body = f"""
<div class="tl" style="grid-template-columns:1fr 1fr 1.25fr 1fr;margin-top:6px">{cols}</div>
<div class="grid" style="grid-template-columns:330px 1fr;gap:12px;margin-top:10px">
 <div class="card"><div class="tag" style="color:var(--redText)">What I'd build for this person, in order</div><ul style="list-style:none;padding:0;margin-top:5px">{w}</ul></div>
 <div class="card"><div class="tag">Illustrative cue sheet — three fictional songs</div><div style="margin-top:5px">{sheet}</div>
  <p style="font-size:11px;color:var(--ink3);margin-top:6px">Why Videoboy fits: Resolume and VDMX cut to the beat but think in clips and layers; vMix and ATEM
  cut a programme without a beat; DJ apps own the beat only for video glued to tracks. Videoboy has the beat clock, broadcast takes and ISO recording in one room.</p></div>
</div>"""
    return Slide("10 · What I would do", "What I would do · as a video artist cutting live to a show",
                 "Prepare like an editor. Perform like a DJ. Deliver like a broadcaster.", body=body,
                 src="The author's view, using shipped features (inventory) and the owner's planned Setlist / LOCK / song-linking design · the cue sheet is illustrative")


def me_90days():
    contrast = """
<div class="grid g2" style="gap:12px;margin-top:12px">
 <div class="card"><div class="tag">Where this agrees with the owner</div><p style="margin-top:5px;font-size:13px">LOCK first, then Playlists, Setlists and songs,
 in the owner's order and with the owner's design. Any canvas (0.4.11) and tags (0.5.0) keep their places after it.</p></div>
 <div class="card"><div class="tag" style="color:var(--redText)">Where it differs</div><p style="margin-top:5px;font-size:13px">It puts undo, Syphon, OSC, hot cues and the
 cut list <b style="color:var(--ink)">before</b> Setlists, because they serve every audience at once; and it brings the corruptor back sooner, because the wedge is the
 only thing a buyer can't get elsewhere.</p></div>
</div>"""
    leg = ('<div class="legend" style="margin:2px 0 8px"><span style="color:var(--cyanText)">■ safety, reach, preparation</span>'
           '<span style="color:var(--amberText)">■ the owner\'s plan</span><span style="color:var(--redText)">■ the wedge</span>'
           '<span style="color:var(--ink3)">■ ready to show · bars are labelled directly</span></div>')
    return Slide("10 · What I would do", "What I would do · the first 90 days", "Twelve weeks, in this order.",
                 body=leg + gantt() + contrast,
                 src="The author's plan · owner-plan durations from the setlist proposal (LOCK ~1½ d, Playlists ~1½ d, Setlists ~3½ d, songs ~1½ d); others are the author's estimates")


# ── appendix ───────────────────────────────────────────────────────────────────
def methodology(stats):
    paths_line = ("all resolve" if not stats["missing"] else "unresolved: " + ", ".join(stats["missing"]))
    trs = "".join(f'<tr><td class="f" style="font-weight:700;width:190px">{E(a)}</td><td style="width:260px">{E(b)}</td><td>{E(c)}</td></tr>'
                  for a, b, c in D.RECHECK_LOG)
    log = ('<table class="d roomy" style="font-size:13.2px"><tr><th>Checked</th><th>How</th><th>What the re-check changed</th></tr>' + trs + "</table>")
    body = f"""
<div class="grid g3" style="gap:14px;margin-top:6px">
 <div class="card dense"><div class="lbl">Videoboy inventory</div>
  <p><b>{stats['rows']} features</b> read from the source on branch feature/queue-names (a92f464). STATUS.md (v0.4.0) and TODO.md (audit L8) are stale, so
  documents were only used to find features, never to confirm them.</p>
  <p><b>{stats['paths']} path references</b> tested for existence by script: {E(paths_line)}. Status counts are grep counts.</p>
  <p><b>Matrix cross-check:</b> every Videoboy cell cites inventory rows and is tested by build_deck.py — {stats['vbcheck']}.</p></div>
 <div class="card dense"><div class="lbl">Competitors</div>
  <p>Vendor documentation, support pages and price pages fetched on 2026-10-01 for Resolume, VDMX, Millumin, QLab, MadMapper, TouchDesigner,
  Synesthesia, Serato, VirtualDJ, vMix, Blackmagic, Adobe and Apple; a second round targeted the uncertain cells.</p>
  <p><b>{stats['unverified']} of {stats['cells']} competitor cells</b> remain <b>?</b> — shown, not guessed. Secondary sources are marked *.</p></div>
 <div class="card dense"><div class="lbl">Limits</div>
  <p>No competitor was installed or tested hands-on; "not found in the documentation reviewed" is not proof of absence. No market-size figure is
  sourced; the revenue table is illustrative. Prices are as published on 2026-10-01, unconverted. Wireframes are schematic. Opinion is labelled.</p></div>
</div>
<div style="margin-top:14px"><div class="lbl" style="margin-bottom:6px;color:var(--redText)">The re-check log</div>{log}</div>"""
    return Slide("Appendix", "Method and verification", "How this was checked — and what the re-check caught.", body=body,
                 src="docs/research/2026-10-01/: feature-inventory.md · 01-broadcast-and-dj-deep-dive.md · 02-vocabulary.md · 03-competitors-and-gaps.md · deck/")


def sources_page(groups):
    blocks = "".join(f'<div style="break-inside:avoid;margin-bottom:9px"><div class="lbl" style="color:var(--redText)">{E(g)}</div>' +
                     "".join(f'<div style="font:9.3px var(--mono);color:var(--ink2);line-height:1.38;word-break:break-all">{E(u)}</div>' for u in us) +
                     "</div>" for g, us in groups)
    return Slide("Appendix", "Sources", "", body=f'<div style="column-count:3;column-gap:26px;margin-top:10px">{blocks}</div>',
                 src="All fetched or searched on 2026-10-01 unless noted · * = secondary source")


def back_cover():
    body = f"""
<div style="position:absolute;left:64px;right:64px;top:290px">
 <div style="margin-bottom:28px">{bars_html(22, "700px")}</div>
 <div style="font-family:'VBDisplay',var(--sans);font-size:150px;line-height:.85">VIDEOBOY</div>
 <p class="dek" style="margin-top:20px">Make the wedge undeniable. Make the app trustworthy. Wire it into other people's rigs.</p>
 <p style="font:10.5px var(--mono);color:var(--ink3);margin-top:40px">Research files: docs/research/2026-10-01/ in the videoboy-perf worktree · source of this deck: deck/build_deck.py</p>
</div>"""
    return Slide("", "", "", body=body, pad="padding:0", chrome=False)
