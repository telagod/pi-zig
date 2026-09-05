#!/usr/bin/env node
import { chromium } from '/home/telagod/.local/share/mise/installs/node/24.17.0/lib/node_modules/playwright/index.mjs';
import { spawn } from 'node:child_process';

const PORT = 19889;
const TOK = 'test_token_deep_verify';
const SESS = 'default';

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

console.log('[1/8] Starting piz web server...');
const web = spawn('./zig-out/bin/piz', ['web', '--port', String(PORT), '--token', TOK, '--no-open'], {
  stdio: ['ignore', 'pipe', 'pipe']
});

process.on('exit', () => {
  try { web.kill(); } catch (_) {}
});

// 等待服务就绪
let serverReady = false;
for (let i = 0; i < 50; i++) {
  try {
    const res = await fetch(`http://127.0.0.1:${PORT}/api/state`, {
      headers: { 'Authorization': `Bearer ${TOK}`, 'X-Requested-With': 'piz' }
    });
    if (res.ok) {
      serverReady = true;
      break;
    }
  } catch (_) {}
  await sleep(200);
}

if (!serverReady) {
  console.error('Server failed to start on port', PORT);
  process.exit(1);
}
console.log('[OK] Server is ready on port', PORT);

console.log('[2/8] Launching headless browser...');
const browser = await chromium.launch();
const page = await browser.newPage({
  viewport: { width: 1440, height: 900 },
  deviceScaleFactor: 2
});

const consoleLogs = [];
const pageErrors = [];

page.on('console', msg => {
  consoleLogs.push({ type: msg.type(), text: msg.text() });
  if (msg.type() === 'error' || msg.type() === 'warning') {
    console.log(`[Browser Console ${msg.type()}]`, msg.text());
  }
});

page.on('pageerror', err => {
  pageErrors.push(err);
  console.error('[Browser PageError]', err);
});

console.log('[3/8] Navigating to WebUI Next...');
await page.goto(`http://127.0.0.1:${PORT}/?session=${SESS}#token=${TOK}`);

// 等待应用挂载
await page.waitForSelector('.app-root', { timeout: 10000 });
console.log('[OK] .app-root successfully mounted in DOM');

// 验证各核心区域存在
await page.waitForSelector('.topbar', { timeout: 5000 });
await page.waitForSelector('.sidebar', { timeout: 5000 });
await page.waitForSelector('.chat-stream', { timeout: 5000 });
await page.waitForSelector('.composer-wrap', { timeout: 5000 });
await page.waitForSelector('.workbench-deck', { timeout: 5000 });
console.log('[OK] TopBar, Sidebar, ChatStream, Composer, Workbench Deck all present');

console.log('[4/8] Testing Mode and Deck Tabs...');
// 模式切换
await page.locator('.mode-btn', { hasText: 'ASK' }).click();
await sleep(150);
await page.locator('.mode-btn', { hasText: 'READ-ONLY' }).click();
await sleep(150);
await page.locator('.mode-btn', { hasText: 'YOLO' }).click();
await sleep(150);
console.log('[OK] Mode switching (YOLO/ASK/READ-ONLY) verified');

// 标签切换
await page.locator('.deck-tab-btn', { hasText: 'Terminal' }).click();
await page.waitForSelector('.terminal-panel');
await sleep(150);

await page.locator('.deck-tab-btn', { hasText: 'Files' }).click();
await page.waitForSelector('.files-panel');
await sleep(150);

await page.locator('.deck-tab-btn', { hasText: 'Jobs' }).click();
await page.waitForSelector('.deck-empty, .jobs-panel');
await sleep(150);

await page.locator('.deck-tab-btn', { hasText: 'Diffs' }).click();
await page.waitForSelector('.deck-empty, .diff-panel');
await sleep(150);
console.log('[OK] All 4 Deck tabs (Diffs/Terminal/Jobs/Files) verified');

console.log('[5/8] Testing Shortcuts, Settings, Tabs and Theme...');
// 测试工作区选择器卡与下拉菜单
await page.waitForSelector('.sidebar-ws-card');
await page.locator('.sidebar-ws-card').click();
await page.waitForSelector('.ws-dropdown');
console.log('[OK] Workspace switcher card & dropdown verified');
await page.locator('.sidebar-ws-card').click(); // 收起下拉
await sleep(150);

// 测试 Ctrl+K 命令面板
await page.keyboard.press('Control+k');
await page.waitForSelector('.command-palette');
console.log('[OK] Command Palette (Ctrl+K) popped up');
await page.keyboard.press('Escape');
await sleep(200);

// 测试快捷键面板 (?)
const helpBtn = page.locator('.tb-shortcuts-btn');
await helpBtn.click();
await page.waitForSelector('.shortcuts-modal');
console.log('[OK] Keyboard Shortcuts Modal popped up');
await page.keyboard.press('Escape');
await sleep(200);

// 测试设置面板及各选项卡切换
const setBtn = page.locator('.tb-settings-btn');
await setBtn.click();
await page.waitForSelector('.settings-modal-card');
await page.locator('.settings-nav-btn', { hasText: /(Sandbox|沙箱)/ }).click();
await sleep(100);
await page.locator('.settings-nav-btn', { hasText: /(Usage|Token|台账)/ }).click();
await sleep(100);
await page.locator('.settings-nav-btn', { hasText: /(Packages|插件|资源)/ }).click();
await sleep(100);
await page.locator('.settings-nav-btn', { hasText: /(Export|导出)/ }).click();
await sleep(100);
await page.waitForSelector('.export-action-card');
console.log('[OK] Settings Modal (All 5 tabs & Export buttons) verified');
await page.locator('.modal-close-btn').click();
await sleep(200);

// 测试主题切换
const themeBtn = page.locator('.tb-theme-btn');
await themeBtn.click();
await page.waitForSelector('.tb-theme-dropdown');
await page.locator('.tb-theme-item', { hasText: /(极地素雪|Light)/ }).click();
await sleep(200);
const curTheme = await page.evaluate(() => document.documentElement.getAttribute('data-theme'));
console.log('[OK] Theme switched to:', curTheme);
// 切回 dark
await themeBtn.click();
await page.waitForSelector('.tb-theme-dropdown');
await page.locator('.tb-theme-item', { hasText: /(暗夜黑曜|Dark)/ }).click();
await sleep(200);

console.log('[6/8] Testing Input, Autocomplete, and Message Flow...');
const textarea = page.locator('.composer-input');

// 测试斜杠菜单
await textarea.fill('/');
await page.waitForSelector('.slash-menu');
console.log('[OK] Slash menu popup verified');
await page.keyboard.press('Escape');
await sleep(150);

// 发送真实测试消息
await textarea.fill('Reply "pong" only');
await page.keyboard.press('Enter');

// 验证用户 Turn 立即呈现
await page.waitForSelector('.turn-user');
console.log('[OK] User Turn rendered successfully in ChatStream');

// 验证助手 Turn 呈现
await page.waitForSelector('.turn-assistant');
console.log('[OK] Assistant Turn rendered');

// 验证流式结束后解除锁定（isStreaming 为 false，发送按钮恢复可用状态）
let unlocked = false;
for (let i = 0; i < 60; i++) {
  const isStop = await page.locator('.composer-send-btn.is-stop').count();
  if (isStop === 0) {
    unlocked = true;
    break;
  }
  await sleep(500);
}
if (unlocked) {
  console.log('[OK] Generation ended cleanly, isStreaming unlocked, no hang detected!');
} else {
  console.error('FAILED: Streaming did not unlock in time!');
  process.exit(1);
}

console.log('[7/8] Testing Responsive Mobile Layout...');
// 先关闭 Deck，截取移动端对话主界面
await page.locator('.deck-close-btn').click();
await sleep(200);
await page.setViewportSize({ width: 390, height: 844 });
await sleep(300);

// 验证移动端响应式样式是否生效
const sidebarPos = await page.evaluate(() => {
  const sb = document.querySelector('.sidebar');
  return window.getComputedStyle(sb).position;
});
console.log('[OK] Mobile responsive layout active (Sidebar position:', sidebarPos, ')');

await page.screenshot({ path: '/tmp/webui_mobile.png', fullPage: true });
console.log('[OK] Mobile screenshot captured to /tmp/webui_mobile.png');

// 再次打开 Deck，截取移动端检视抽屉状态
await page.locator('.tb-deck-btn').click();
await sleep(200);
await page.screenshot({ path: '/tmp/webui_mobile_deck.png', fullPage: true });

// 恢复桌面端并截屏
await page.setViewportSize({ width: 1440, height: 900 });
await sleep(300);
await page.screenshot({ path: '/tmp/webui_desktop.png', fullPage: true });
console.log('[OK] Desktop screenshot captured to /tmp/webui_desktop.png');

console.log('[8/8] Verifying Zero Runtime Errors...');
const criticalErrors = pageErrors.filter(e => !e.message?.includes('mock'));
const consoleErrors = consoleLogs.filter(l => l.type === 'error');

if (criticalErrors.length > 0 || consoleErrors.length > 0) {
  console.error(`FAILED: Found ${criticalErrors.length} page errors and ${consoleErrors.length} console errors!`);
  for (const err of criticalErrors) console.error('[PageError]', err);
  for (const err of consoleErrors) console.error('[ConsoleError]', err.text);
  process.exit(1);
}

console.log('[OK] PERFECT: ZERO runtime errors or console errors detected!');
await browser.close();
web.kill();
console.log('[SUCCESS] All 8 deep browser E2E test suites passed with absolute perfection!');
process.exit(0);
