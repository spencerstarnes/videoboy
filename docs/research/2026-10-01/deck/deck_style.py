"""Visual system for the Videoboy market report.

Dark, bold, dense. Every colour used for data was run through the dataviz
validator against the #0B0B0E surface (dark band L 0.48-0.67):
    categorical  #C08000 amber · #169BC6 cyan · #EE4036 red   -> ALL CHECKS PASS
    ordinal      #0E5A75 -> #1898C4 (partial -> full)          -> ALL CHECKS PASS
Text never wears a series colour; status glyphs differ in SHAPE as well as tone.
"""

BEBAS = "/Users/spencerstarnes/Library/Fonts/BebasNeue-Regular.ttf"

CSS = r"""
@font-face { font-family: "VBDisplay"; src: local("Bebas Neue"), url("file://__BEBAS__") format("truetype"); }
@page { size: 1600px 900px; margin: 0; }
* { box-sizing: border-box; margin: 0; padding: 0; }
:root {
  --bg: #0B0B0E; --panel: #131318; --panel2: #1A1A21; --line: #262630; --line2: #1B1B22;
  --ink: #F4F4F6; --ink2: #B4B4BE; --ink3: #7C7C87; --ink4: #50505A;
  --red: #EE4036; --redText: #FF6F64; --amber: #C08000; --amberText: #F0B640;
  --cyan: #169BC6; --cyanText: #5CC8EC; --cyanDeep: #0E5A75; --cyanFull: #1898C4;
  --mono: ui-monospace, "SF Mono", Menlo, monospace;
  --sans: system-ui, -apple-system, "Helvetica Neue", sans-serif;
}
html, body { background: var(--bg); }
body { font-family: var(--sans); color: var(--ink); -webkit-print-color-adjust: exact; print-color-adjust: exact;
       font-variant-numeric: tabular-nums; -webkit-font-smoothing: antialiased; }
.slide { width: 1600px; height: 900px; position: relative; overflow: hidden; background: var(--bg);
         padding: 46px 64px 48px; break-after: page; page-break-after: always; }
.slide:last-child { break-after: auto; page-break-after: auto; }
.bars { position: absolute; top: 0; left: 0; right: 0; height: 5px; display: flex; }
.bars i { flex: 1; display: block; }
.hdr { display: flex; justify-content: space-between; align-items: baseline; font: 500 10.5px var(--mono);
       color: var(--ink4); letter-spacing: .1em; text-transform: uppercase; }
.hdr b { color: var(--ink3); font-weight: 600; }
.kicker { font-family: "VBDisplay", var(--sans); font-size: 27px; letter-spacing: .07em; color: var(--redText);
          line-height: 1; margin-top: 18px; }
h1 { font-family: var(--sans); font-weight: 900; font-size: 64px; line-height: .95; letter-spacing: -.028em;
     margin: 8px 0 12px; max-width: 1400px; }
h1.xl { font-size: 92px; }
h1.sm { font-size: 40px; margin: 6px 0 8px; }
h1 em { font-style: normal; color: var(--redText); }
.dek { font-size: 17.5px; line-height: 1.38; color: var(--ink2); max-width: 1180px; }
.dek b { color: var(--ink); font-weight: 650; }
.foot { position: absolute; bottom: 16px; left: 64px; right: 64px; display: flex; justify-content: space-between;
        font: 9px var(--mono); color: var(--ink4); letter-spacing: .03em; gap: 40px; }
.foot .src { max-width: 1080px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.foot span:last-child { white-space: nowrap; }
.grid { display: grid; gap: 18px; }
.g2 { grid-template-columns: 1fr 1fr; } .g3 { grid-template-columns: repeat(3, 1fr); }
.g4 { grid-template-columns: repeat(4, 1fr); } .g5 { grid-template-columns: repeat(5, 1fr); }
.card { background: var(--panel); border: 1px solid var(--line); border-radius: 6px; padding: 14px 16px; }
.card h3 { font-size: 15.5px; font-weight: 800; letter-spacing: -.005em; margin-bottom: 6px; line-height: 1.15; }
.card p, .card li { font-size: 12.3px; line-height: 1.42; color: var(--ink2); }
.card ul { padding-left: 15px; } .card li { margin: 2px 0; }
.card .tag { font: 600 9.5px var(--mono); letter-spacing: .08em; text-transform: uppercase; color: var(--ink3); }
.lbl { font: 600 9.5px var(--mono); letter-spacing: .1em; text-transform: uppercase; color: var(--ink3); }
.big { font-family: var(--sans); font-weight: 900; font-size: 56px; letter-spacing: -.03em; line-height: 1; }
.big small { font-size: 22px; font-weight: 800; color: var(--ink3); letter-spacing: -.01em; }
.stat .big { margin: 6px 0 4px; }
.stat p { font-size: 12px; color: var(--ink2); line-height: 1.35; }
code, .mono { font-family: var(--mono); font-size: .92em; }
table.d { width: 100%; border-collapse: collapse; font-size: 11px; line-height: 1.28; }
table.d th { font: 650 9px var(--mono); text-transform: uppercase; letter-spacing: .07em; color: var(--ink3);
             text-align: left; border-bottom: 1px solid var(--line); padding: 5px 6px 4px; vertical-align: bottom; }
table.d td { border-bottom: 1px solid var(--line2); padding: 3.4px 6px; vertical-align: top; color: var(--ink2); }
table.d.tight td { padding: 2.2px 6px; line-height: 1.22; }
table.d.tight tr.grp td { padding-top: 6px; }
table.d.roomy td { padding: 7px 8px; }
table.d.roomy th { padding: 7px 8px 6px; }
table.d td.f { color: var(--ink); }
table.d tr.grp td { padding-top: 8px; font: 700 9.5px var(--mono); letter-spacing: .1em; text-transform: uppercase;
                    color: var(--redText); border-bottom: 1px solid var(--line); }
table.d td.c, table.d th.c { text-align: center; }
table.d td.r, table.d th.r { text-align: right; }
table.d .ev { font: 9px var(--mono); color: var(--ink4); }
table.d tr.vb td { background: rgba(238,64,54,.06); }
.s { display: inline-block; width: 16px; text-align: center; font-size: 13px; line-height: 1; }
.sY { color: var(--ink); } .sP { color: var(--amberText); } .sN { color: var(--ink4); }
.sU { color: var(--ink3); font-family: var(--mono); font-size: 11px; } .sF { color: var(--cyanText); } .sNA { color: var(--ink4); font: 9px var(--mono); }
.pill { display: inline-block; font: 650 9px var(--mono); letter-spacing: .06em; padding: 2px 6px 1px; border-radius: 3px;
        border: 1px solid var(--line); color: var(--ink2); margin: 0 3px 3px 0; text-transform: uppercase; }
.pill.red { border-color: rgba(238,64,54,.6); color: var(--redText); }
.pill.cy { border-color: rgba(22,155,198,.6); color: var(--cyanText); }
.pill.am { border-color: rgba(192,128,0,.65); color: var(--amberText); }
.legend { display: flex; gap: 16px; font: 10px var(--mono); color: var(--ink3); align-items: center; flex-wrap: wrap; }
.legend span { display: inline-flex; gap: 5px; align-items: center; }
.rule { height: 1px; background: var(--line); margin: 12px 0; }
.num { font-family: var(--mono); color: var(--ink3); }
.shot { border: 1px solid var(--line); border-radius: 6px; overflow: hidden; position: relative; background: #000; }
.shot img { display: block; width: 100%; }
.callout { position: absolute; width: 22px; height: 22px; border-radius: 50%; background: var(--red); color: #fff;
           font: 800 12px var(--sans); display: flex; align-items: center; justify-content: center;
           box-shadow: 0 0 0 2px #0B0B0E; }
.wf { background: var(--panel); border: 1px solid var(--line); border-radius: 6px; padding: 10px; }
.wf .frame { position: relative; height: 196px; background: #0E0E12; border: 1px solid var(--line); border-radius: 4px; }
.wf .b { position: absolute; border: 1px solid #34343F; border-radius: 2px; font: 600 8.5px var(--mono); color: var(--ink3);
         display: flex; align-items: center; justify-content: center; text-align: center; padding: 1px; letter-spacing: .02em;
         background: #15151B; line-height: 1.15; }
.wf .b.hi { border-color: rgba(238,64,54,.7); color: var(--redText); background: rgba(238,64,54,.07); }
.wf .b.cy { border-color: rgba(22,155,198,.7); color: var(--cyanText); background: rgba(22,155,198,.07); }
.wf .b.am { border-color: rgba(192,128,0,.7); color: var(--amberText); background: rgba(192,128,0,.07); }
.wf h3 { font-size: 15px; font-weight: 800; margin: 2px 0 6px; } .wf p { font-size: 11.2px; color: var(--ink2); line-height: 1.38; margin-top: 7px; }
.tl { display: grid; gap: 10px; }
.tl .phase { background: var(--panel); border: 1px solid var(--line); border-radius: 6px; padding: 12px 14px; position: relative; }
.tl .phase h4 { font-family: "VBDisplay", var(--sans); font-size: 22px; letter-spacing: .05em; line-height: 1; margin-bottom: 4px; }
.tl .phase .when { font: 600 9.5px var(--mono); letter-spacing: .08em; text-transform: uppercase; color: var(--ink3); }
.tl .phase li { font-size: 11.6px; line-height: 1.38; color: var(--ink2); margin: 2px 0 2px 14px; }
.quote { font-size: 13px; color: var(--ink2); border-left: 2px solid var(--red); padding: 2px 0 2px 12px; line-height: 1.45; }
.dense p { font-size: 12.4px; line-height: 1.45; color: var(--ink2); margin-bottom: 7px; }
.dense p b { color: var(--ink); }
.k { color: var(--ink); font-weight: 700; }
"""

# SMPTE-style 75% colour bars: the brand stripe across the top of every page.
BARS = ["#C0C0C0", "#C0C000", "#00C0C0", "#00C000", "#C000C0", "#C00000", "#0000C0"]
