#!/usr/bin/env node
// Renders the manuals in docs/pdf/src/*.html to PDF with headless Chromium.
//
//   node scripts/build_docs_pdf.mjs [name ...]
//
// No npm dependencies: it drives the browser over the DevTools protocol with
// node's built-in fetch and WebSocket (node 22+). Any Chromium works — Brave,
// Chrome, Edge, Chromium — set CHROMIUM to override the search.
//
// Page numbers come from printToPDF's footer template, which the plain
// `--print-to-pdf` command line cannot do.

import { spawn } from 'node:child_process';
import { mkdtempSync, readdirSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = dirname(dirname(fileURLToPath(import.meta.url)));
const srcDir = join(repo, 'docs/pdf/src');
const outDir = join(repo, 'docs/pdf');

const CANDIDATES = [
  process.env.CHROMIUM,
  '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/usr/bin/google-chrome',
  '/usr/bin/chromium',
].filter(Boolean);

const browser = CANDIDATES.find((p) => existsSync(p));
if (!browser) {
  console.error('no Chromium found — set CHROMIUM=/path/to/chrome');
  process.exit(1);
}

// The PDF file name is the <title> of the page, so the manuals keep their
// names in one place: the documents themselves.
const OUT_NAMES = {
  'installazione-it': 'TemplarWallet-Installazione-IT.pdf',
  'installation-en': 'TemplarWallet-Installation-EN.pdf',
  'guida-uso-it': 'TemplarWallet-Guida-Uso-IT.pdf',
  'user-guide-en': 'TemplarWallet-User-Guide-EN.pdf',
};

const footer = (label) => `
  <div style="width:100%;font:9px 'Helvetica Neue',Arial,sans-serif;color:#69737F;
              padding:0 14mm;display:flex;justify-content:space-between;">
    <span>${label}</span>
    <span class="pageNumber"></span>
  </div>`;

const port = 9500 + Math.floor(Math.random() * 400);
const profile = mkdtempSync(join(tmpdir(), 'templar-pdf-'));
const child = spawn(browser, [
  '--headless=new',
  `--remote-debugging-port=${port}`,
  `--user-data-dir=${profile}`,
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-gpu',
  '--hide-scrollbars',
  'about:blank',
], { stdio: 'ignore' });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function endpoint() {
  for (let i = 0; i < 100; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${port}/json/version`);
      return (await r.json()).webSocketDebuggerUrl;
    } catch {
      await sleep(100);
    }
  }
  throw new Error('browser did not open a debugging port');
}

class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.id = 0;
    this.pending = new Map();
    this.events = [];
    ws.addEventListener('message', (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id !== undefined) {
        const p = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        msg.error ? p.reject(new Error(msg.error.message)) : p.resolve(msg.result);
      } else {
        this.events.push(msg);
      }
    });
  }

  static async open(url) {
    const ws = new WebSocket(url);
    await new Promise((res, rej) => {
      ws.addEventListener('open', res, { once: true });
      ws.addEventListener('error', rej, { once: true });
    });
    return new Cdp(ws);
  }

  send(method, params = {}, sessionId) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params, sessionId }));
    });
  }
}

const wanted = process.argv.slice(2);
const pages = readdirSync(srcDir)
  .filter((f) => f.endsWith('.html'))
  .map((f) => basename(f, '.html'))
  .filter((n) => wanted.length === 0 || wanted.includes(n));

const cdp = await Cdp.open(await endpoint());
let failures = 0;

for (const name of pages) {
  const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
  const s = sessionId;
  await cdp.send('Page.enable', {}, s);
  await cdp.send('Page.navigate', { url: `file://${join(srcDir, name)}.html` }, s);

  // Wait for load *and* for every image and web font to be in place —
  // printToPDF paints whatever is ready, so an early call drops screenshots.
  let ready = false;
  for (let i = 0; i < 150 && !ready; i++) {
    await sleep(200);
    const { result } = await cdp.send('Runtime.evaluate', {
      expression: `(document.readyState === 'complete') &&
        [...document.images].every(i => i.complete && i.naturalWidth > 0) &&
        (!document.fonts || document.fonts.status === 'loaded')`,
      returnByValue: true,
    }, s);
    ready = result.value === true;
  }
  if (!ready) {
    console.error(`✗ ${name}: page never finished loading`);
    failures++;
  }

  const { result: title } = await cdp.send('Runtime.evaluate', {
    expression: 'document.title', returnByValue: true,
  }, s);

  // ReturnAsStream, not the inline base64: a manual full of screenshots makes
  // a single CDP message big enough that the socket never delivers it.
  const { stream } = await cdp.send('Page.printToPDF', {
    printBackground: true,
    preferCSSPageSize: true,
    displayHeaderFooter: true,
    headerTemplate: '<div></div>',
    footerTemplate: footer(title.value ?? ''),
    transferMode: 'ReturnAsStream',
  }, s);

  const chunks = [];
  for (;;) {
    const { data, base64Encoded, eof } =
      await cdp.send('IO.read', { handle: stream, size: 1 << 20 }, s);
    if (data) chunks.push(Buffer.from(data, base64Encoded ? 'base64' : 'utf8'));
    if (eof) break;
  }
  await cdp.send('IO.close', { handle: stream }, s);
  const pdf = Buffer.concat(chunks);

  const out = join(outDir, OUT_NAMES[name] ?? `${name}.pdf`);
  await import('node:fs').then(({ writeFileSync }) => writeFileSync(out, pdf));
  const kb = Math.round(pdf.length / 1024);
  console.log(`✓ ${out.replace(repo + '/', '')} (${kb} KB)`);
  await cdp.send('Target.closeTarget', { targetId });
}

child.kill();
process.exit(failures ? 1 : 0);
