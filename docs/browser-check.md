# Browser checks

Browser gates use actual Grover conversion. They are separate from the unit
suite and fail on missing prerequisites when enabled. A skipped browser case is
not evidence of browser compatibility.

## Prerequisites

- Node.js supported by the chosen Puppeteer release. The fixture setup uses Node 22.
- A compatible Puppeteer installation and Chrome/Chromium executable.
- Poppler's `pdffonts` and `pdftotext`; the benchmark also needs `pdftoppm`.
- A readable platform TrueType font supplied through `PARADEM_PDF_TEST_FONT`.

For the checkout's fixture environment:

```sh
npm install --no-save --package-lock=false puppeteer@24.17.0
```

This installation is for development checks. The gem does not install Node
packages or download Chrome during rendering. The generic fixture specifically
requires the `puppeteer` package, even though the runtime launcher can resolve
`puppeteer-core`.

Install Poppler with `brew install poppler` on macOS or
`sudo apt-get install poppler-utils fonts-dejavu-core` on Debian-based Linux.
Example platform fonts:

- macOS: `/System/Library/Fonts/Supplemental/Arial.ttf`
- Linux: `/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf`

Set `PUPPETEER_EXECUTABLE_PATH` to the full executable path. With the fixture
Puppeteer installation, obtain it using:

```sh
node -p 'require("puppeteer").executablePath()'
```

Do not copy application fonts into the repository. Do not enable
`GROVER_NO_SANDBOX=true` or security-bypass launch flags. The fixture also rejects
external `NODE_OPTIONS` preloads. Use a non-root Linux environment with working
Chrome sandbox support. See the CI setup in
[test.yml](../.github/workflows/test.yml).

## Generic output gate

Replace the executable and font paths with those available on your machine:

```sh
env -u GROVER_NO_SANDBOX PARADEM_PDF_BROWSER=1 BUNDLE_FROZEN=true \
  PARADEM_PDF_TEST_FONT="/path/to/platform-font.ttf" \
  PUPPETEER_EXECUTABLE_PATH="/path/to/chrome" \
  bundle exec rake test TEST='test/browser_test.rb'
```

[browser_test.rb](../test/browser_test.rb) and
[browser_fixture.rb](../test/support/browser_fixture.rb) check portrait and
landscape output with two and three pages, dynamic totals, embedded fonts, and
header/body/footer text placement. They reuse a cache store and inspect cold,
decoration-warm, completed-hit, and shared-batch behavior.

The fixture checks one launch per cold or warm render, none for completed hits,
and one launch for a shared batch. It checks finite conversion and worker
deadlines and normal close/reaping of owned processes. Forced or failed cleanup
fails the proof even if PDF bytes were produced.

These are generic Latin fixtures. They do not prove an application's fonts,
multilingual glyph coverage, layouts, assets, or deployment compatibility.

## Resource readiness gate

```sh
env -u GROVER_NO_SANDBOX PARADEM_PDF_READINESS_BROWSER=1 BUNDLE_FROZEN=true \
  PARADEM_PDF_TEST_FONT="/path/to/platform-font.ttf" \
  PUPPETEER_EXECUTABLE_PATH="/path/to/chrome" \
  bundle exec ruby -Ilib -Itest test/readiness_browser_test.rb
```

[readiness_browser_test.rb](../test/readiness_browser_test.rb) and
[readiness_fixture.rb](../test/support/readiness_fixture.rb) exercise image and
font loading, resource failures and deadlines, selected media, custom scripts,
explicit waits, opt-out, cache publication, context isolation, and owned cleanup.
Repeated serial and parallel decoration cases check that sibling connections do
not reset print media or allow corrupt print-only fonts into new cache entries.

Set `PARADEM_PDF_READINESS_ARTIFACTS` to an external directory to retain PDFs and
observer records. Without it, temporary scenario artifacts are cleaned up.
Keep retained output outside the checkout and gem package.

## Readiness benchmark

Under the same prerequisites, choose an external artifact directory:

```sh
env -u GROVER_NO_SANDBOX PARADEM_PDF_READINESS_BROWSER=1 BUNDLE_FROZEN=true \
  PARADEM_PDF_TEST_FONT="/path/to/platform-font.ttf" \
  PUPPETEER_EXECUTABLE_PATH="/path/to/chrome" \
  bundle exec ruby -Ilib -Itest test/support/readiness_benchmark.rb \
  --benchmark /path/to/external-artifacts
```

The [benchmark](../test/support/readiness_benchmark.rb) runs ten paired serial
comparisons with identical assets and instrumentation, alternating policy order.
It compares readiness disabled and enabled across cold, decoration-warm, and
completed-hot states. It records phase timings and checks page geometry, text,
fonts, and raster equality using Poppler.

It writes `benchmark.json` before failing if appearance differs or the median
warm reduction is below its 10% gate. That threshold is a development acceptance
check, not a guaranteed application speedup. The benchmark does not measure
production CPU or parallel rendering performance.

## Recording evidence

Record the commit, platform, Ruby, Node, Puppeteer, Chrome, font, command, and
results for each actual run. Separate generic and readiness results. Do not
describe configured Linux CI as executed Linux evidence or carry dated local
results forward as proof of a later release.
