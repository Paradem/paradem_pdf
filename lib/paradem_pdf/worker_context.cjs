// Grover 1.2.10 still owns conversion, options, protocol and cleanup. Its worker
// connects with no target filter, so sibling connections can reset page state.
// This preload runs only in that conversion's Node process, after caller preloads.
const Module = require('node:module');
let puppeteer;
try {
  puppeteer = require(require.resolve('puppeteer', { paths: Module._nodeModulePaths(process.cwd()) }));
} catch {
  try {
    puppeteer = require(require.resolve('puppeteer-core', { paths: Module._nodeModulePaths(process.cwd()) }));
  } catch {
    // Let the native worker report its normal package error on stdout.
    return;
  }
}

const connect = puppeteer.connect.bind(puppeteer);
puppeteer.connect = async options => {
  let contextId;
  const browser = await connect({
    ...options,
    targetFilter: target => target.type() === 'browser' ||
      (contextId !== undefined && target.browserContext().id === contextId)
  });
  const create = browser.createBrowserContext.bind(browser);
  browser.createBrowserContext = async (...args) => {
    const context = await create(...args);
    contextId = context.id;
    if (typeof contextId !== 'string') {
      await context.close();
      throw new Error('ParademPdf requires Puppeteer BrowserContext.id');
    }
    return context;
  };
  return browser;
};
