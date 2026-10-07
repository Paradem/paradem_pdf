// Resolve puppeteer from the CWD exactly like Grover's worker does.
const Module = require('module');

let puppeteer;
try {
  puppeteer = require(require.resolve('puppeteer', { paths: Module._nodeModulePaths(process.cwd()) }));
} catch (puppeteerError) {
  try {
    puppeteer = require(require.resolve('puppeteer-core', { paths: Module._nodeModulePaths(process.cwd()) }));
  } catch (coreError) {
    throw puppeteerError;
  }
}

const FORBIDDEN = /no-sandbox|disable-setuid-sandbox|disable-web-security|ignore-certificate-errors/;

function validateArgs(args) {
  if ((args || []).some(arg => FORBIDDEN.test(arg))) {
    throw new Error('Unsafe browser security arguments');
  }
}

async function main() {
  const options = JSON.parse(process.argv[process.argv.length - 1]);
  const args = options.args || [];
  validateArgs(args);

  const launchParams = { headless: options.headless === undefined ? true : options.headless };
  if (options.devtools !== undefined) launchParams.devtools = options.devtools;
  if (options.executablePath) launchParams.executablePath = options.executablePath;
  if (Array.isArray(args)) launchParams.args = args;
  if (options.browser) launchParams.browser = options.browser;
  if (options.timeout) launchParams.timeout = options.timeout;

  const browser = await puppeteer.launch(launchParams);
  process.stdout.write(browser.wsEndpoint() + '\n');

  let closing = false;
  const close = async () => {
    if (closing) return;
    closing = true;
    try {
      await browser.close();
    } catch (error) {
      process.stderr.write(error.toString() + '\n');
      process.exit(1);
      return;
    }
    process.exit(0);
  };

  process.on('SIGTERM', close);
  process.stdin.on('end', close);
  process.stdin.resume();
}

main().catch(error => {
  process.stderr.write(error.toString() + '\n');
  process.exit(1);
});
