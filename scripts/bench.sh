#!/usr/bin/env bash
# bench.sh —— piz 超低资源占用实测。结果落 docs/benchmarks.md 之表可复跑。
# 用法: ./scripts/bench.sh [port]   (需 zig build 已产 ReleaseFast 二进制)
set -u
PIZ="${PIZ:-./zig-out/bin/piz}"
PORT="${1:-18798}"
TOK="bench$RANDOM"

hr() { printf -- '--- %s ---\n' "$1"; }
rss_kb() { awk '/VmRSS/{print $2}' "/proc/$1/status" 2>/dev/null || echo '?'; }

hr "二进制"
ls -la "$PIZ" | awk '{printf "piz: %.1f MB\n", $5/1048576}'

hr "冷启动(hyperfine 若在,30 次)"
if command -v hyperfine >/dev/null; then
  hyperfine --warmup 3 -r 30 --style basic "$PIZ --version" 2>/dev/null | grep -iE 'Time' || true
else
  t0=$(date +%s%N); for _ in $(seq 1 100); do "$PIZ" --version >/dev/null; done
  echo "mean: $(( ($(date +%s%N) - t0) / 100000 )) ms / 100 runs"
fi

hr "一次性命令峰值 RSS(/usr/bin/time -v)"
for c in "--version" "sessions" "usage" "doctor"; do
  /usr/bin/time -v "$PIZ" $c >/dev/null 2>/tmp/piz-bench.t
  printf '%-12s %s KB\n' "$c" "$(awk '/Maximum resident/{print $NF}' /tmp/piz-bench.t)"
done

hr "web 服务(端口 $PORT)"
"$PIZ" web --port "$PORT" --no-open --token "$TOK" >/tmp/piz-bench.log 2>&1 &
WPID=$!; sleep 1
echo "idle:           $(rss_kb $WPID) KB"
for _ in $(seq 1 50); do curl -s "http://127.0.0.1:$PORT/" -H "Authorization: Bearer $TOK" -o /dev/null; done
for _ in $(seq 1 50); do curl -s "http://127.0.0.1:$PORT/api/state?session=b" -H "Authorization: Bearer $TOK" -o /dev/null; done
echo "100 req 后:     $(rss_kb $WPID) KB"
seq 1 200 | xargs -P 20 -I{} curl -s "http://127.0.0.1:$PORT/api/state?session=s{}" -H "Authorization: Bearer $TOK" -o /dev/null
echo "200 并发会话后: $(rss_kb $WPID) KB"

hr "web 首屏载荷"
curl -s "http://127.0.0.1:$PORT/" -H "Authorization: Bearer $TOK" -o /tmp/piz-bench.html
printf 'index.html: %s B (gzip %s B)\n' "$(wc -c < /tmp/piz-bench.html)" "$(gzip -c /tmp/piz-bench.html | wc -c)"
printf 'app.js:     %s B (gzip %s B)\n' "$(wc -c < src/webui.js)" "$(gzip -c src/webui.js | wc -c)"
printf 'app.css:    %s B (gzip %s B)\n' "$(wc -c < src/webui.css)" "$(gzip -c src/webui.css | wc -c)"
kill $WPID 2>/dev/null; wait 2>/dev/null
echo OK
