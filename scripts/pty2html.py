#!/usr/bin/env python3
"""pty2html — ptyshot 的 .raw 经 pyte 渲成带 ANSI 色的 HTML(供 playwright 截 PNG)。
用法: pty2html.py in.raw out.html [--cols N --rows N]
"""
import sys, pyte, html

def main():
    raw_path, out_path = sys.argv[1], sys.argv[2]
    cols, rows = 100, 34
    args = sys.argv[3:]
    while args:
        k, v = args.pop(0), args.pop(0)
        if k == "--cols": cols = int(v)
        elif k == "--rows": rows = int(v)
    raw = open(raw_path, "rb").read()
    screen = pyte.Screen(cols, rows)
    pyte.ByteStream(screen).feed(raw)
    # 主题:贴近 piz 暗色实拍
    FG_MAP = {"black":"#000","red":"#e06c75","green":"#98c379","yellow":"#d19a66","blue":"#61afef","magenta":"#c678dd","cyan":"#56b6c2","white":"#abb2bf"}
    BG = "#1e1f24"; FG = "#d7d9e0"
    lines = []
    for y in range(rows):
        spans = []
        cur_style, buf = None, []
        def flush():
            if not buf: return
            text = html.escape("".join(buf))
            if cur_style: spans.append(f'<span style="{cur_style}">{text}</span>')
            else: spans.append(text)
        for x in range(cols):
            ch = screen.buffer[y][x]
            style = []
            fg = ch.fg if ch.fg == "default" else FG_MAP.get(ch.fg, None)
            if fg: style.append(f"color:{fg}")
            if ch.bold: style.append("font-weight:600")
            if ch.italics: style.append("font-style:italic")
            if ch.reverse: style.append(f"background:{FG};color:{BG}")
            # pyte 不直接给 dim 位;faint 属性名是 'faint'? pyte 用 bold/italics/underscore/blink/reverse
            s = ";".join(style) or None
            if s != cur_style:
                flush(); buf = []; cur_style = s
            buf.append(ch.data or " ")
        flush()
        lines.append("".join(spans).rstrip() or "&nbsp;")
    doc = f"""<!doctype html><meta charset=utf-8><style>
body{{background:{BG};margin:0;padding:18px 20px;display:inline-block}}
pre{{margin:0;color:{FG};font:14px/1.32 'DejaVu Sans Mono','Noto Sans Mono CJK SC',monospace;white-space:pre}}
</style><pre>{chr(10).join(lines)}</pre>"""
    open(out_path, "w").write(doc)
    print("wrote", out_path)

main()
