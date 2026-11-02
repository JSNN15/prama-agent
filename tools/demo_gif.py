#!/usr/bin/env python3
# tools/demo_gif.py — lays out the README demo from the captures of tools/demo.sh: a caption per
# scene, a terminal window (commands typed, then their real output), the Telegram alert and a final
# card; renders each frame with headless Chromium and writes an animated GIF with Pillow.
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0
"""Usage: demo_gif.py <en|es> <capture dir> <out.gif> <chromium>"""
import html
import os
import subprocess
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ansi2html import render  # noqa: E402

W, H = 1040, 600

TEXT = {
    "en": {
        "s1": "Start a team: a coordinator and two agents, each on its own git branch",
        "s2": "The coordinator plans with one-line commands; prama shows the plan live",
        "s3": "“Done”, without evidence: prama flags the task as unverified",
        "s3b": "prama runs T2's acceptance check on the agent's branch: it fails, T2 is reopened",
        "s4": "An agent goes silent: the task is flagged stale…",
        "s4b": "…and the alert reaches your phone, with buttons to act on it",
        "s5": "Merge it anyway? The tests run after the merge: it is undone, main never breaks",
        "tag": "Don't trust what your agents say. Check it.",
        "sub": "A control plane for Claude Code and Antigravity agents on your server.<br>"
               "bash + tmux · survives SSH drops · Apache-2.0",
        "bot": "prama-agent bot", "now": "now",
        "swarm": 'prama-agent swarm backend --team sec --workers agy:2 --task "Harden authentication"',
    },
    "es": {
        "s1": "Crea un equipo: un coordinador y dos agentes, cada uno en su propia rama de git",
        "s2": "El coordinador planifica con comandos de una línea; prama muestra el plan en vivo",
        "s3": "«Lista», sin evidencia: prama marca la tarea como no verificada",
        "s3b": "prama corre la verificación de T2 en la rama del agente: falla y T2 se reabre",
        "s4": "Un agente deja de trabajar: la tarea se marca estancada…",
        "s4b": "…y la alerta llega a tu teléfono, con botones para actuar",
        "s5": "¿Y si se mergea igual? Los tests corren tras el merge: se deshace, main nunca se rompe",
        "tag": "No le creas a tus agentes. Verifica.",
        "sub": "Un plano de control para agentes Claude Code y Antigravity en tu servidor.<br>"
               "bash + tmux · sobrevive a cortes de SSH · Apache-2.0",
        "bot": "prama-agent bot", "now": "ahora",
        "swarm": 'prama-agent swarm backend --team sec --workers agy:2 --task "Endurecer la autenticación"',
    },
}

CSS = """
*{box-sizing:border-box}
html,body{margin:0;width:%(w)dpx;height:%(h)dpx;overflow:hidden;
 background:radial-gradient(1200px 600px at 15%% -10%%,#1e293b 0,#0b1220 55%%,#070b14 100%%)}
.cap{position:absolute;left:36px;right:36px;top:22px;display:flex;align-items:center;gap:14px;
 font:600 22px/1.25 ui-sans-serif,system-ui,"DejaVu Sans",sans-serif;color:#f1f5f9}
.step{flex:none;font:700 13px/1 ui-sans-serif,system-ui,sans-serif;color:#0b1220;background:#38bdf8;
 border-radius:999px;padding:6px 10px;letter-spacing:.04em}
.stage{position:absolute;left:0;right:0;top:78px;bottom:18px;display:flex;align-items:flex-start;justify-content:center}
.win{border-radius:12px;overflow:hidden;background:#0b1220;max-width:%(mw)dpx;
 box-shadow:0 24px 60px rgba(2,6,23,.6),0 0 0 1px rgba(148,163,184,.2)}
.bar{height:30px;background:linear-gradient(#1f2937,#111827);display:flex;align-items:center;padding:0 12px;gap:7px;
 font:600 12px/1 ui-sans-serif,system-ui,sans-serif;color:#94a3b8}
.dot{width:11px;height:11px;border-radius:50%%;display:inline-block}
.t{margin-left:10px}
pre{margin:0;padding:12px 16px 16px;color:#e2e8f0;font:14px/1.36 "DejaVu Sans Mono","Noto Sans Mono",monospace;
 white-space:pre;min-height:%(minh)dpx}
.ps{color:#34d399}.cur{background:#e2e8f0;color:#e2e8f0}
.phone{width:380px;border-radius:28px;background:#0e1621;padding:14px 12px 22px;
 box-shadow:0 24px 60px rgba(2,6,23,.6),0 0 0 2px #334155}
.tgh{display:flex;align-items:center;gap:10px;padding:4px 6px 12px;border-bottom:1px solid #1f2b38;
 font:600 15px/1.2 ui-sans-serif,system-ui,sans-serif;color:#e9eef3}
.av{width:34px;height:34px;border-radius:50%%;background:linear-gradient(135deg,#38bdf8,#a855f7);display:flex;
 align-items:center;justify-content:center;font-size:17px}
.on{font:400 12px ui-sans-serif,system-ui,sans-serif;color:#6c8aa5}
.msg{margin:16px 6px 6px;background:#182533;color:#e9eef3;border-radius:14px 14px 14px 4px;padding:11px 13px 8px;
 font:400 14.5px/1.42 ui-sans-serif,system-ui,"DejaVu Sans",sans-serif;white-space:pre-wrap;word-break:break-word}
.msg b{color:#7dd3fc}
.tm{text-align:right;font-size:11px;color:#6c8aa5;margin-top:4px}
.btns{display:flex;gap:6px;margin:0 6px}
.btn{flex:1;text-align:center;background:#24384c;color:#e9eef3;border-radius:8px;padding:9px 6px;
 font:600 13.5px ui-sans-serif,system-ui,sans-serif}
.card{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:18px;
 text-align:center;color:#e2e8f0;font-family:ui-sans-serif,system-ui,"DejaVu Sans",sans-serif}
.logo{font:800 64px/1 ui-sans-serif,system-ui,sans-serif;letter-spacing:-.02em;
 background:linear-gradient(90deg,#38bdf8,#a855f7,#f472b6);-webkit-background-clip:text;color:transparent}
.tag{font:700 30px/1.2 ui-sans-serif,system-ui,sans-serif;color:#f8fafc}
.sub{font:400 17px/1.5 ui-sans-serif,system-ui,sans-serif;color:#94a3b8}
.code{font:15px "DejaVu Sans Mono",monospace;background:#111827;border:1px solid #334155;border-radius:10px;
 padding:12px 18px;color:#e2e8f0}
.url{font:600 18px ui-sans-serif,system-ui,sans-serif;color:#7dd3fc}
"""


def page(body, cols=104, rows=15):
    css = CSS % {"w": W, "h": H, "mw": W - 40, "minh": int(rows * 14 * 1.36)}
    return '<!doctype html><html><head><meta charset="utf-8"><style>%s</style></head><body>%s</body></html>' % (css, body)


def caption(step, text):
    return '<div class="cap"><span class="step">%s</span><span>%s</span></div>' % (step, html.escape(text))


def window(title, inner):
    return ('<div class="stage"><div class="win"><div class="bar"><span class="dot" style="background:#f87171"></span>'
            '<span class="dot" style="background:#fbbf24"></span><span class="dot" style="background:#34d399"></span>'
            '<span class="t">%s</span></div><pre>%s</pre></div></div>') % (html.escape(title), inner)


def ansi(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return render(f.read().replace("\r", ""))


def prompt(cmd, cursor=False):
    return '<span class="ps">server-01 ~ $</span> %s%s' % (html.escape(cmd), '<span class="cur">▌</span>' if cursor else "")


def terminal(blocks, typing_last=None):
    """blocks: [(command, output html or None)]; typing_last: chars of the last command shown so far."""
    out = []
    for i, (cmd, res) in enumerate(blocks):
        last = i == len(blocks) - 1
        if last and typing_last is not None:
            out.append(prompt(cmd[:typing_last], cursor=True))
            break
        out.append(prompt(cmd))
        if res:
            out.append(res.rstrip("\n"))
    return "\n".join(out)


def typed(blocks, title, cap, ms_out):
    """Frames that type the last command, then show its output."""
    cmd = blocks[-1][0]
    frames = []
    for n in (len(cmd) // 4, len(cmd) // 2, 3 * len(cmd) // 4, len(cmd)):
        frames.append((page(cap + window(title, terminal(blocks, n))), 140))
    frames.append((page(cap + window(title, terminal(blocks))), ms_out))
    return frames


def telegram(t, alert_lines, cap):
    head, body = alert_lines[0], alert_lines[1]
    b1, b2 = alert_lines[2], alert_lines[3]
    phone = ('<div class="stage"><div class="phone"><div class="tgh"><div class="av">◆</div><div>%s'
             '<div class="on">bot</div></div></div><div class="msg"><b>%s</b>\n%s<div class="tm">%s</div></div>'
             '<div class="btns"><div class="btn">%s</div><div class="btn">%s</div></div></div></div>') % (
        html.escape(t["bot"]), html.escape(head), html.escape(body), html.escape(t["now"]),
        html.escape(b1), html.escape(b2))
    return page(cap + phone)


def card(t):
    return page('<div class="card"><div class="logo">prama-agent</div><div class="tag">%s</div>'
                '<div class="sub">%s</div><div class="code">curl -fsSL https://raw.githubusercontent.com/'
                'JSNN15/prama-agent/main/install.sh | sudo bash</div>'
                '<div class="url">github.com/JSNN15/prama-agent</div></div>' % (html.escape(t["tag"]), t["sub"]))


def main():
    lang, d, out, chrome = sys.argv[1:5]
    t = TEXT[lang]
    p = lambda n: os.path.join(d, n)  # noqa: E731
    frames = []
    frames += typed([(t["swarm"], ansi(p("swarm.ansi")))], "prama-agent", caption("1/6", t["s1"]), 3200)
    board = "prama-agent plan backend --team sec"
    frames.append((page(caption("2/6", t["s2"]) + window(board, ansi(p("board.ansi")))), 3600))
    coord = "coordinator · prama-backend-sec-coord"
    frames += typed([("prama-agent plan done T2", ansi(p("done.ansi")))], coord, caption("3/6", t["s3"]), 1500)
    frames.append((page(caption("3/6", t["s3"]) + window(board, ansi(p("board-unverified.ansi")))), 3000))
    frames += typed([("prama-agent plan verify T2", ansi(p("verify.ansi")))], coord, caption("4/6", t["s3b"]), 4600)
    frames.append((page(caption("5/6", t["s4"]) + window(board, ansi(p("board-stale.ansi")))), 2600))
    with open(p("alert.txt"), encoding="utf-8") as f:
        alert = [line for line in f.read().split("\n") if line.strip()]
    frames.append((telegram(t, alert, caption("5/6", t["s4b"])), 3600))
    merge = 'prama-agent worktree merge prama-backend-sec-agy --test "sh tests/run.sh"'
    frames += typed([(merge, ansi(p("merge.ansi")))], "prama-agent", caption("6/6", t["s5"]), 1500)
    frames += typed([(merge, ansi(p("merge.ansi"))), ("git log --oneline -1", ansi(p("gitlog.ansi")))],
                    "prama-agent", caption("6/6", t["s5"]), 3800)[-1:]
    frames.append((card(t), 4200))

    pngs = []
    for i, (doc, _ms) in enumerate(frames):
        hp, pp = p("frame-%02d.html" % i), p("frame-%02d.png" % i)
        with open(hp, "w", encoding="utf-8") as f:
            f.write(doc)
        subprocess.run([chrome, "--headless=new", "--no-sandbox", "--disable-gpu", "--hide-scrollbars",
                        "--force-device-scale-factor=1", "--window-size=%d,%d" % (W, H),
                        "--screenshot=" + pp, "file://" + hp], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=False)
        if not os.path.exists(pp):
            sys.exit("frame %d failed to render" % i)
        pngs.append(pp)

    # One shared palette keeps the colors steady from frame to frame (and the file small).
    imgs = [Image.open(x).convert("RGB") for x in pngs]
    sheet = Image.new("RGB", (W, H * len(imgs)))
    for i, im in enumerate(imgs):
        sheet.paste(im, (0, H * i))
    pal = sheet.quantize(colors=128, method=Image.Quantize.MEDIANCUT)
    q = [im.quantize(palette=pal, dither=Image.Dither.NONE) for im in imgs]
    q[0].save(out, save_all=True, append_images=q[1:], duration=[ms for _d, ms in frames], loop=0,
              optimize=True, disposal=1)
    print("  %s (%d frames, %.1f s, %d KB)" % (out, len(q), sum(ms for _d, ms in frames) / 1000,
                                                os.path.getsize(out) // 1024))


if __name__ == "__main__":
    main()
