// Test-only transport and phase observation. All navigation, evaluation and PDF
// calls go through to Puppeteer; only generic fixture resource bytes are supplied.
require('./browser_observer.cjs');
const fs = require('node:fs');
const Module = require('node:module');
const puppeteer = require(require.resolve('puppeteer', { paths: Module._nodeModulePaths(process.cwd()) }));
const root = process.env.PARADEM_PDF_READINESS_RECORD;
const now = () => Number(process.hrtime.bigint()) / 1e6;
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const svg = color => `<svg xmlns="http://www.w3.org/2000/svg" width="80" height="30"><rect width="80" height="30" fill="${color}"/></svg>`;
let sequence = 0;

if (process.env.PARADEM_PDF_READINESS_TRACE === '1') {
  const { CdpCDPSession } = require('puppeteer-core/lib/cjs/puppeteer/cdp/CdpSession.js');
  const { Connection } = require('puppeteer-core/lib/cjs/puppeteer/cdp/Connection.js');
  const path = `${root}/protocol-${process.pid}.jsonl`;
  const role = process.env.PARADEM_PDF_BROWSER_LAUNCHER === '1' ? 'owner' : 'worker';
  const onMessage = Connection.prototype.onMessage;
  Connection.prototype.onMessage = function (message) {
    const incoming = JSON.parse(message);
    if (incoming.method === 'Target.attachedToTarget') {
      fs.appendFileSync(path, JSON.stringify({ role, at: now(), incoming }) + '\n');
    }
    return onMessage.call(this, message);
  };
  for (const klass of [CdpCDPSession, Connection]) {
    const send = klass.prototype.send;
    klass.prototype.send = function (method, params, ...args) {
      if (!['Emulation.setEmulatedMedia', 'Target.createBrowserContext', 'Target.createTarget', 'Target.setAutoAttach', 'Target.attachToTarget', 'Target.detachFromTarget', 'Browser.close'].includes(method)) {
        return send.call(this, method, params, ...args);
      }
      const entry = { role, method, params, at: now(), session: typeof this.id === 'function' ? this.id() : 'connection' };
      fs.appendFileSync(path, JSON.stringify(entry) + '\n');
      return send.call(this, method, params, ...args).then(result => {
        fs.appendFileSync(path, JSON.stringify({ ...entry, at: now(), response: result }) + '\n');
        return result;
      }, error => {
        fs.appendFileSync(path, JSON.stringify({ ...entry, at: now(), error: error.message }) + '\n');
        throw error;
      });
    };
  }
}

if (process.env.PARADEM_PDF_BROWSER_LAUNCHER === '1') {
  const launch = puppeteer.launch.bind(puppeteer);
  puppeteer.launch = async options => {
    const record = { launch_start: now() };
    const browser = await launch(options);
    record.launch_end = now();
    const file = `${root}/launch-${process.pid}.json`;
    fs.writeFileSync(file, JSON.stringify(record));
    const close = browser.close.bind(browser);
    browser.close = async () => {
      record.close_start = now();
      try { return await close(); }
      finally { record.close_end = now(); fs.writeFileSync(file, JSON.stringify(record)); }
    };
    return browser;
  };
} else {
  const connect = puppeteer.connect.bind(puppeteer);
  puppeteer.connect = async options => {
    const browser = await connect(options);
    const record = { events: [], phases: {}, contexts: 0 };
    const file = `${root}/conversion-${process.pid}-${++sequence}.json`;
    const save = () => fs.writeFileSync(file, JSON.stringify(record));
    const event = (name, details = {}) => { record.events.push({ name, at: now(), ...details }); save(); };
    const watchdog = setTimeout(() => { event('worker-deadline'); process.exit(1); }, 75000);
    const create = browser.createBrowserContext.bind(browser);
    browser.createBrowserContext = async () => {
      const context = await create();
      record.contexts++;
      event('context-open', { id: context.id });
      const close = context.close.bind(context);
      context.close = async () => {
        try { return await close(); }
        finally { event('context-close'); }
      };
      const newPage = context.newPage.bind(context);
      context.newPage = async () => {
        const page = await newPage();
        page.setDefaultNavigationTimeout(20000);
        page.setDefaultTimeout(20000);
        let held;
        page.on('request', request => {
          const url = new URL(request.url());
          if (url.hostname !== 'resources.example.test') return;
          const [scenario, asset] = url.pathname.slice(1).split('/');
          event('resource-request', { asset, scenario });
          // Grover's own listener invokes continue. Replace that transport call,
          // not its HTML interception, avoiding two competing request handlers.
          request.continue = async () => {
            if (asset === 'unrelated') { held = request; event('unrelated-held'); return; }
            if (asset === 'lazy.svg' && scenario === 'stall') { event('image-stalled'); return; }
            await delay(asset === 'style.css' ? 90 : asset.endsWith('.ttf') ? 140 : 110);
            let body, contentType;
            if (asset === 'style.css') {
              contentType = 'text/css';
              body = `@font-face {font-family: Fixture; src: url(https://resources.example.test/${scenario}/font.ttf)}
                @font-face {font-family: Unused; src: url(https://resources.example.test/${scenario}/unused.ttf)}
                @media print {body {font-family: Fixture}} .marker {margin-left: 48px}`;
            } else if (asset.endsWith('.ttf')) {
              contentType = 'font/ttf';
              body = scenario === 'bad-font' ? Buffer.from('corrupt font') : fs.readFileSync(process.env.PARADEM_PDF_TEST_FONT);
            } else {
              contentType = 'image/svg+xml';
              body = scenario === 'bad-image' && asset === 'normal.svg' ? 'corrupt image' : svg(asset === 'lazy.svg' ? 'green' : 'red');
            }
            const status = scenario === 'bad-style' && asset === 'style.css' ? 404 : 200;
            event('resource-response', { asset, status });
            try { await request.respond({ status, contentType, body, headers: { 'access-control-allow-origin': '*' } }); }
            catch (error) { event('transport-closed', { asset, message: error.message }); }
          };
        });
        page.on('requestfinished', request => {
          if (request.url().startsWith('https://resources.example.test/')) event('resource-finished', { asset: new URL(request.url()).pathname.split('/').pop() });
        });
        page.on('load', () => event('load'));
        const goto = page.goto.bind(page);
        page.goto = async (...args) => {
          record.waitUntil = args[1].waitUntil;
          record.phases.navigation_start = now();
          try { return await goto(...args); }
          catch (error) { event('navigation-error', { message: error.message }); throw error; }
          finally {
            record.phases.navigation_end = now();
            record.media_after_load = await evaluate(() => matchMedia('print').matches);
            save();
          }
        };
        const evaluate = page.evaluate.bind(page);
        const emulate = page.emulateMediaType.bind(page);
        page.emulateMediaType = async media => {
          record.media = media;
          const result = await emulate(media);
          event('media-selected', { media, actual: await evaluate(() => matchMedia('print').matches) });
          return result;
        };
        page.evaluate = async (...args) => {
          record.phases.readiness_start = now();
          event('script-start', { print: await evaluate(() => matchMedia('print').matches) });
          try { return await evaluate(...args); }
          catch (error) { event('script-error', { message: error.message }); throw error; }
          finally {
            record.phases.readiness_end = now();
            record.media_after_readiness = await evaluate(() => matchMedia('print').matches);
            event('script-end');
          }
        };
        const pdf = page.pdf.bind(page);
        page.pdf = async (...args) => {
          record.snapshot = await evaluate(() => ({
            images: Array.from(document.images, image => ({ id: image.id, width: image.naturalWidth, loading: image.loading })),
            fonts: Array.from(document.fonts, face => ({ family: face.family, status: face.status })),
            print: matchMedia('print').matches,
            customCount: window.customCount || 0, customDone: window.customDone || false,
            markerLeft: document.querySelector('.marker')?.getBoundingClientRect().left
          }));
          event('print-start', { unrelatedPending: !!held });
          record.phases.print_start = now();
          if (held) {
            await held.respond({ status: 200, contentType: 'text/plain', body: 'released at print' });
            event('unrelated-release');
          }
          try { return await pdf(...args); }
          finally { record.phases.print_end = now(); event('print-end'); }
        };
        return page;
      };
      return context;
    };
    const disconnect = browser.disconnect.bind(browser);
    browser.disconnect = async () => {
      try { return await disconnect(); }
      finally { clearTimeout(watchdog); event('disconnect'); }
    };
    return browser;
  };
}
