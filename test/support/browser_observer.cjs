const { once, EventEmitter } = require('node:events');
const assert = require('node:assert/strict');

function validateLaunch(options) {
  if ((options.args || []).some(arg => /no-sandbox|disable-setuid-sandbox|disable-web-security|ignore-certificate-errors/.test(arg))) {
    throw new Error('Unsafe browser security arguments');
  }
}
async function deadline(promise, timeout, message) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(message)), timeout);
    })]);
  } finally {
    clearTimeout(timer);
  }
}

async function closeOwned(browser, record, save, timeout = 5000) {
  const child = browser.process();
  if (!child) throw new Error('No owned browser child');
  record.pid = child.pid;
  const reaped = once(child, 'close').then(([code, signal]) => {
    record.reaped = { code, signal };
    save();
  });
  try {
    await deadline((async () => { await browser.close(); await reaped; })(), timeout, 'Browser close deadline');
    record.closed = true;
  } catch (error) {
    record.error = error.message;
    if (browser.process() === child && child.exitCode === null && child.signalCode === null) {
      try {
        record.forced = child.kill('SIGKILL');
        await deadline(reaped, 2000, 'Browser reaping deadline');
      } catch (cleanupError) {
        record.cleanupError = cleanupError.message;
        throw new AggregateError([error, cleanupError], 'Owned browser cleanup failed');
      }
    }
    throw error;
  } finally {
    save();
  }
}

async function selfTest() {
  for (const flag of ['--no-sandbox', '--disable-setuid-sandbox', '--disable-web-security', '--ignore-certificate-errors']) {
    assert.throws(() => validateLaunch({ args: [flag] }), /Unsafe/);
  }
  validateLaunch({ args: [] });
  const child = () => Object.assign(new EventEmitter(), { pid: 123, exitCode: null, signalCode: null });
  const exit = (process, code, signal) => {
    process.exitCode = code;
    process.signalCode = signal;
    process.emit('exit', code, signal);
    process.emit('close', code, signal);
  };
  const normal = child();
  normal.kill = () => { throw new Error('Normal close must not signal'); };
  const clean = {};
  await closeOwned({ process: () => normal, close: async () => exit(normal, 0, null) }, clean, () => {});
  assert.equal(clean.closed, true);
  assert.deepEqual(clean.reaped, { code: 0, signal: null });
  const stalled = child();
  let signals = 0;
  stalled.kill = signal => {
    signals++;
    assert.equal(signal, 'SIGKILL');
    exit(stalled, null, signal);
    return true;
  };
  const failed = {};
  await assert.rejects(closeOwned({ process: () => stalled, close: () => new Promise(() => {}) }, failed, () => {}, 1), /close deadline/);
  assert.equal(signals, 1);
  assert.equal(failed.forced, true);
  assert.equal(failed.closed, undefined);
  assert.equal(failed.reaped.signal, 'SIGKILL');
  const dead = child();
  dead.exitCode = 0;
  dead.kill = () => { throw new Error('Exited child must not be signaled'); };
  await assert.rejects(closeOwned({ process: () => dead, close: async () => { throw new Error('close failed'); } }, {}, () => {}, 1), /close failed/);
  const denied = child();
  denied.kill = () => { throw new Error('EPERM'); };
  const deniedRecord = {};
  await assert.rejects(closeOwned({ process: () => denied, close: async () => { throw new Error('close failed'); } }, deniedRecord, () => {}), /Owned browser cleanup failed/);
  assert.equal(deniedRecord.cleanupError, 'EPERM');
  assert.equal(deniedRecord.closed, undefined);
  process.stdout.write('Browser observer self-check passed\n');
}

if (process.argv.includes('--self-test')) {
  selfTest().catch(error => { console.error(error); process.exitCode = 1; });
} else if (process.env.PARADEM_PDF_BROWSER_LAUNCHER === '1') {
  const fs = require('node:fs');
  const Module = require('node:module');
  const puppeteer = require(require.resolve('puppeteer', { paths: Module._nodeModulePaths(process.cwd()) }));
  const file = `${process.env.PARADEM_PDF_BROWSER_RECORD}-${process.pid}.json`;
  const record = { args: [], cleanup: {} };
  const save = () => fs.writeFileSync(file, JSON.stringify(record));
  let closeBrowser;
  const watchdog = setTimeout(async () => {
    record.error = 'Worker deadline';
    try { if (closeBrowser) await closeBrowser(); }
    catch (error) { record.error += ': ' + error.message; }
    finally { save(); process.exit(1); }
  }, 60000);
  const launch = puppeteer.launch.bind(puppeteer);
  puppeteer.launch = async options => {
    validateLaunch(options);
    if (process.env.GROVER_NO_SANDBOX === 'true') throw new Error('Unsafe sandbox environment');
    const browser = await launch({ ...options, timeout: 20000, protocolTimeout: 20000 });
    record.args = options.args || [];
    const owned = { process: () => browser.process(), close: browser.close.bind(browser) };
    let closing;
    closeBrowser = browser.close = () => (closing ||= closeOwned(owned, record.cleanup, save).finally(() => clearTimeout(watchdog)));
    const newPage = browser.newPage.bind(browser);
    browser.newPage = async () => {
      const page = await newPage();
      page.setDefaultNavigationTimeout(20000);
      page.setDefaultTimeout(20000);
      return page;
    };
    save();
    return browser;
  };
}
