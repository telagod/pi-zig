# sucrase.standalone.js 复现步骤

sucrase(MIT)单文件 IIFE bundle,供 jsrt 在 QuickJS 内做 TS 类型剥离。
纯 JS,无 node 依赖(仅生成模板字符串里出现 require 字样)。

```sh
mkdir /tmp/tsstrip && cd /tmp/tsstrip
npm init -y && npm i --no-audit --no-fund sucrase esbuild ts-interface-checker lines-and-columns
printf 'module.exports = require("sucrase/dist/index.js");\n' > entry.js
npx esbuild entry.js --bundle --format=iife --global-name=Sucrase --minify \
  --platform=browser --outfile=sucrase.standalone.js
cp sucrase.standalone.js <repo>/src/embedded/
```

注意:platform 必须 browser(neutral 解析不了 ts-interface-checker 的 exports)。
2026-08-20 打:sucrase 最新版,产物 295213 字节。用法见 src/jsrt.zig tsStrip。
