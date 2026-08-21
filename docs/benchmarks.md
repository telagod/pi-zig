# 性能实测

主打超低资源占用。以下数字皆可 `./scripts/bench.sh` 复跑。

机器:13th Gen Intel i7-13620H(16 线程),x86_64 Linux,Zig 0.16 ReleaseFast(strip 后)。对比组 `pi` 为 node 24 版(0.84.2),同机同刻。

## 体积

| | 磁盘占用 |
|---|---|
| **piz** | **6.3 MB** 单静态二进制(含内嵌 Web UI 与 QuickJS) |
| pi(node) | node 运行时 123 MB + 包 145 MB ≈ **268 MB**(42×) |

## 冷启动与峰值 RSS

| 命令 | 耗时 | 峰值 RSS |
|---|---|---|
| `piz --version` | **0.63 ms** | **3.5 MB** |
| `node --version` | 2.89 ms | 17 MB |
| `pi --version` | 471 ms | 154 MB |

piz 启动快 pi **746 倍**,峰值内存省 **97.7%**。

一次性常驻命令(`sessions` / `usage` / `doctor`):墙钟 ≤20 ms,峰值 RSS ≤4.4 MB。`piz build-web`(内嵌 TS 编译)0.38 s / 13 MB。

## Web 服务(`piz web`)

| 状态 | RSS |
|---|---|
| 空转 | 6.6 MB |
| 100 请求(首页+api/state 各 50)后 | 7.8 MB |
| SSE 长连保持中 | 7.8 MB |
| 200 并发会话请求后 | 8.7 MB |

压完不回落也不涨——无泄漏斜坡,稳态 <9 MB。

## Web 首屏载荷

| 件 | 原始 | gzip |
|---|---|---|
| index.html | 9.0 KB | 2.6 KB |
| app.js(17 模块打包) | 192 KB | 49.8 KB |
| app.css | 82 KB | 12.2 KB |
| **合计(3 请求,零 CDN)** | **283 KB** | **~65 KB** |

本机首屏:DOMContentLoaded **21 ms**,load **72 ms**,传输 286 KB。

## 何以至此

- Zig ReleaseFast 单静态二进制,无运行时、无 node_modules、无冷启动 JIT。
- Web UI 手写无框架:TS → sucrase 去型 → esbuild 单文件,3 请求成页。
- SSE 用 fetch+ReadableStream,无 ws 库;服务全程 std.http,无第三方依赖。
- 工具 schema 编译期入表,不用的不进请求,亦省 token。
