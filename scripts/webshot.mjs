#!/usr/bin/env node
// webshot — 截图 piz WebUI:mockai + piz web + playwright
// 用法: node scripts/webshot.mjs <out.png> [scenario] [optsJSON]
// scenario: chat(工具轮回) | md(markdown 大餐) | welcome | snap(纯等待)
// opts: { theme:'light'|'dark', width, height, session, full:true, expand:true }
import { chromium } from '/home/telagod/.local/share/mise/installs/node/24.17.0/lib/node_modules/playwright/index.mjs';
import { spawn } from 'node:child_process';

const out = process.argv[2] || '/tmp/webshot.png';
const scenario = process.argv[3] || 'chat';
const opts = JSON.parse(process.argv[4] || '{}');
const PORT = 5600 + Math.floor(Math.random() * 300), TOK = 'shot';
const SESS = opts.session || ('shot_' + Math.random().toString(36).slice(2, 8));

function sh(cmd, args) {
  const p = spawn(cmd, args, { stdio: ['ignore', 'pipe', 'pipe'] });
  p.stdout.on('data', () => {});
  p.stderr.on('data', () => {});
  return p;
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function waitHttp(url, tries = 80) {
  for (let i = 0; i < tries; i++) {
    try { const r = await fetch(url, { headers: { authorization: 'Bearer ' + TOK } }); if (r.status < 500) return; } catch {}
    await sleep(250);
  }
  throw new Error('server not up: ' + url);
}

let mock = null;
try { await fetch('http://127.0.0.1:8899/v1/models').then(r => r.ok); } catch { mock = sh('python3', ['scripts/mockai.py']); await sleep(400); }
// 默认模型切到 mock(备份/还原 settings.json)
import { readFileSync, writeFileSync } from 'node:fs';
const setPath = process.env.HOME + '/.piz/settings.json';
const setBak = readFileSync(setPath, 'utf8');
const setObj = JSON.parse(setBak);
setObj.defaultProvider = 'mock'; setObj.defaultModel = 'mock-slow';
if (opts.settings) Object.assign(setObj, opts.settings);
writeFileSync(setPath, JSON.stringify(setObj, null, 1));
process.on('exit', () => writeFileSync(setPath, setBak));
const web = sh('./zig-out/bin/piz', ['web', '--port', String(PORT), '--token', TOK, '--no-open']);
process.on('exit', () => { try { web.kill(); } catch {} try { if (mock) mock.kill(); } catch {} });
await waitHttp('http://127.0.0.1:' + PORT + '/api/state');

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: opts.width || 1440, height: opts.height || 900 }, deviceScaleFactor: 2 });
page.on('pageerror', e => console.error('[pageerror]', e.message));
if (opts.theme) {
  await page.addInitScript(t => {
    localStorage.setItem('piz.prefs', JSON.stringify({ scheme: t }));
  }, opts.theme);
}
await page.goto('http://127.0.0.1:' + PORT + '/?session=' + SESS + '#token=' + TOK);
await page.waitForSelector('#splash', { state: 'hidden', timeout: 15000 }).catch(() => {});
await sleep(700);

async function send(text) {
  await page.fill('#inp', text);
  await page.press('#inp', 'Enter');
}
async function waitIdle(ms = 4000) {
  // 等运行指示消失(send 钮从停止态回发送态)
  await page.waitForFunction(() => !document.querySelector('.a-turn.gen'), { timeout: 45000 }).catch(() => {});
  await sleep(ms);
}

if (scenario === 'chat') {
  await send('帮我看下这个目录里有什么');
  await page.waitForSelector('.a-turn', { timeout: 30000 });
  await waitIdle(2500);
} else if (scenario === 'md') {
  await send('用 markdown 展示一下这个项目');
  await page.waitForSelector('.a-turn', { timeout: 30000 });
  await waitIdle(2500);
} else if (scenario === 'fail') {
  await send('跑个会 fail 的命令');
  await page.waitForSelector('.a-turn', { timeout: 30000 });
  await waitIdle(2000);
  await page.evaluate(() => {
    document.querySelectorAll('.work:not(.open) > .work-sum').forEach((e) => (e).click());
  });
  await sleep(500);
} else if (scenario === 'write') {
  await send('改文件试试');
  await page.waitForSelector('.a-turn', { timeout: 30000 });
  await waitIdle(2000);
  await page.evaluate(() => {
    document.querySelectorAll('.work:not(.open) > .work-sum').forEach((e) => (e).click());
    const rows = document.querySelectorAll('.tcall .bh');
    if (rows.length) (rows[rows.length - 1]).click();
  });
  await sleep(1200);
} else if (scenario === 'inspect') {
  await send('帮我看下这个目录里有什么');
  await page.waitForSelector('.a-turn', { timeout: 30000 });
  await waitIdle(2000);
  await page.evaluate(() => {
    const rows = document.querySelectorAll('.tcall .bh');
    if (rows.length) (rows[rows.length - 1]).click();
  });
  await sleep(1200);
} else if (scenario === 'think') {
  await send('帮我看下这个目录里有什么');
  await page.waitForSelector('.a-turn', { timeout: 30000 });
  await waitIdle(2000);
  await page.evaluate(() => {
    document.querySelectorAll('.think:not(.open) > .think-sum').forEach((e) => (e).click());
  });
  await sleep(600);
} else if (scenario === 'approve') {
  await send('帮我看下这个目录里有什么');
  await page.waitForSelector('.ap, .approval, [class*="appr"]', { timeout: 30000 }).catch(() => {});
  await sleep(2500);
} else if (scenario === 'welcome' || scenario === 'snap') {
  await sleep(Number(opts.wait || 800));
}
if (opts.expand) {
  await page.evaluate(() => {
    document.querySelectorAll('.work:not(.open) > .work-sum, .tcall:not(.open) > .tc-sum, .think:not(.open) > .think-sum')
      .forEach((e) => (e).click());
  });
  await sleep(500);
}
await page.screenshot({ path: out, fullPage: !!opts.full });
console.log('shot →', out);
await browser.close();
web.kill(); if (mock) mock.kill();
process.exit(0);
