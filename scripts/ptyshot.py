#!/usr/bin/env python3
"""ptyshot — 在 pty 里跑 TUI,发按键,用 pyte 渲染终屏为文本。
用法: ptyshot.py --cols 100 --rows 32 --out /tmp/shot.txt -- cmd arg...
按键脚本经 PTY_KEYS 环境变量:[[延迟秒, "文本"], ...],文本支持 \\x1b 等转义。
"""
import json, os, pty, select, sys, time

def main():
    args = sys.argv[1:]
    cols, rows, out, settle = 100, 32, None, 1.0
    while args and args[0].startswith("--") and args[0] != "--":
        k = args.pop(0)
        v = args.pop(0)
        if k == "--cols": cols = int(v)
        elif k == "--rows": rows = int(v)
        elif k == "--out": out = v
        elif k == "--settle": settle = float(v)
    if args and args[0] == "--": args.pop(0)
    if not args:
        print("no cmd", file=sys.stderr); sys.exit(2)
    keys = json.loads(os.environ.get("PTY_KEYS", "[]"))
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.execvp(args[0], args)
    import fcntl, termios, struct
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    raw = b""
    start = time.time()
    ki = 0
    deadline = start + 3.0
    while True:
        now = time.time()
        if ki < len(keys) and now - start >= keys[ki][0]:
            os.write(fd, keys[ki][1].encode())
            ki += 1
            deadline = now + settle
        if ki >= len(keys) and now > deadline:
            break
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                chunk = os.read(fd, 65536)
                if not chunk: break
                raw += chunk
                if ki >= len(keys): deadline = time.time() + settle
            except OSError:
                break
        if now - start > 60: break
    try: os.close(fd)
    except OSError: pass
    try: os.kill(pid, 9)
    except OSError: pass
    try: os.waitpid(pid, 0)
    except OSError: pass
    import pyte
    screen = pyte.Screen(cols, rows)
    stream = pyte.ByteStream(screen)
    stream.feed(raw)
    lines = [screen.display[i] for i in range(rows)]
    text = "\n".join(lines)
    if out:
        with open(out, "w") as f: f.write(text)
        with open(out + ".raw", "wb") as f: f.write(raw)
    else:
        print(text)

main()
