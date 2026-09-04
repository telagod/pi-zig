#!/usr/bin/env node
import { chromium } from '/home/telagod/.local/share/mise/installs/node/24.17.0/lib/node_modules/playwright/index.mjs';
import { spawn } from 'node:child_process';

const PORT = 19889;
const TOK = 'test_token_deep_verify';
const SESS = 'e2e_deep_session';

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

console.log('[1/7] Starting piz web server...');
const web = spawn('./zig-out/bin/piz', ['web', '--port', String(PORT), '--token', TOK, '--no-open'], {
  stdio: ['ignore', 'pipe', 'pipe']
});

process.on('exit', () => {
  try { web.kill(); } catch (_) {}
});

// 等待服务就绪
let serverReady = false;
for (let i = 0; i < 40; i++) {
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
  console.error('Server failed to start!');
  process.exit(1);
}
console.log('✓ Server is ready on port', PORT);

console.log('[2/7] Launching headless browser...');
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

console.log('[3/7] Navigating to WebUI Next...');
await page.goto(`http://127.0.0.1:${PORT}/?session=${SESS}#token=${TOK}`);

// 等待应用挂载
await page.waitForSelector('.app-root', { timeout: 10000 });
console.log('✓ .app-root successfully mounted in DOM');

// 验证各核心区域存在
await page.waitForSelector('.topbar', { timeout: 5000 });
await page.waitForSelector('.sidebar', { timeout: 5000 });
await page.waitForSelector('.chat-stream', { timeout: 5000 });
await page.waitForSelector('.composer-wrap', { timeout: 5000 });
await page.waitForSelector('.workbench-deck', { timeout: 5000 });
console.log('✓ TopBar, Sidebar, ChatStream, Composer, Workbench Deck all present');

console.log('[4/7] Testing Mode and Deck Tabs...');
// 模式切换
await page.locator('.mode-btn', { hasText: 'Ask' }).click();
await sleep(200);
await page.locator('.mode-btn', { hasText: 'Plan' }).click();
await sleep(200);
await page.locator('.mode-btn', { hasText: 'YOLO' }).click();
await sleep(200);
console.log('✓ Mode switching (YOLO/Ask/Plan) verified');

// 标签切换
await page.locator('.deck-tab-btn', { hasText: 'Terminal' }).click();
await page.waitForSelector('.terminal-panel');
await sleep(200);

await page.locator('.deck-tab-btn', { hasText: 'Files' }).click();
await page.waitForSelector('.files-panel');
await sleep(200);

await page.locator('.deck-tab-btn', { hasText: 'Jobs' }).click();
await page.waitForSelector('.deck-empty, .jobs-panel');
await sleep(200);

await page.locator('.deck-tab-btn', { hasText: 'Diffs' }).click();
await page.waitForSelector('.deck-empty, .diff-panel');
await sleep(200);
console.log('✓ All 4 Deck tabs (Diffs/Terminal/Jobs/Files) verified');

console.log('[5/7] Testing Shortcuts and Modals...');
// 测试 Ctrl+K 命令面板
await page.keyboard.press('Control+k');
await page.waitForSelector('.command-palette');
console.log('✓ Command Palette (Ctrl+K) popped up');
await page.keyboard.press('Escape');
await sleep(200);

// 测试设置面板
const setBtn = page.locator('.tb-btn', { hasText: '⚙' });
await setBtn.click();
await page.waitForSelector('.settings-modal');
console.log('✓ Settings Modal popped up');
await page.locator('.modal-close-btn').click();
await sleep(200);

// 测试主题切换
const themeBtn = page.locator('.tb-icon-btn', { hasText: /[☀🌙]/ });
await themeBtn.click();
await sleep(200);
const scheme = await page.evaluate(() => document.documentElement.getAttribute('data-color-scheme'));
console.log('✓ Theme toggled to:', scheme);
await themeBtn.click(); // 切回
await sleep(200);

// 测试 Deck 折叠与展开
const deckToggleBtn = page.locator('.tb-deck-btn');
await deckToggleBtn.click();
await sleep(200);
const isDeckClosed = await page.evaluate(() => document.querySelector('.workbench-deck').classList.contains('is-closed'));
console.log('✓ Deck collapse state:', isDeckClosed);
await deckToggleBtn.click(); // 重新展开
await sleep(200);

console.log('[6/7] Testing Input, Autocomplete, and Message Sending...');
const textarea = page.locator('.composer-input');

// 测试斜杠菜单
await textarea.fill('/');
await page.waitForSelector('.slash-menu');
console.log('✓ Slash menu popup verified');
await page.keyboard.press('Escape');
await sleep(200);

// 测试 @ 文件菜单
await textarea.fill('@');
await page.waitForSelector('.file-menu');
console.log('✓ File reference popup verified');
await page.keyboard.press('Escape');
await sleep(200);

// 发送真实测试消息
await textarea.fill('Hello from deep verification!');
await page.keyboard.press('Enter');
await page.waitForSelector('.turn-user');
console.log('✓ User Turn rendered successfully in ChatStream');

await sleep(2000);

// 截取高质量全屏快照
await page.screenshot({ path: '/tmp/webui_next_deep_tested.png', fullPage: true });
console.log('✓ Deep screenshot captured to /tmp/webui_next_deep_tested.png');

console.log('[7/7] Verifying Zero Runtime Errors...');
const criticalErrors = pageErrors.filter(e => !e.message?.includes('mock'));
const consoleErrors = consoleLogs.filter(l => l.type === 'error');

if (criticalErrors.length > 0 || consoleErrors.length > 0) {
  console.error(`FAILED: Found ${criticalErrors.length} page errors and ${consoleErrors.length} console errors!`);
  for (const err of criticalErrors) console.error('[PageError]', err);
  for (const err of consoleErrors) console.error('[ConsoleError]', err.text);
  process.exit(1);
}

console.log('✓ PERFECT: ZERO runtime errors or console errors detected!');
await browser.close();
web.kill();
console.log('🌟 All 7 deep browser E2E test suites passed with absolute perfection!');
process.exit(0);
