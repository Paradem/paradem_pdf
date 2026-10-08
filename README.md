# ParademPdf

ParademPdf is a standalone Ruby gem for converting app-supplied HTML to PDF,
adding per-page HTML headers and footers, concatenating PDFs, and caching PDF bytes.

The core provides document conversion, validated PDF concatenation, per-page
decorations, and byte caching. Optional Rails adapters use a supplied renderer
and the configured cache. The generic browser gate has passed on arm64 macOS
with Ruby 3.4.8 and 4.0.7. Application-specific output and Linux CI execution
require their own verification.

## Runtime requirements

- The supported target is Ruby 3.2 or newer, through latest stable, without a
  gemspec upper bound. Executed checks and dependency limits are listed below.
- Grover is pinned to 1.2.10. CombinePDF uses `~> 1.0.31`.
- Node.js, a compatible Puppeteer installation, and Chrome or Chromium for conversion.

The gem does not install Node packages or download a browser during rendering.
Rails is optional. The core must load without a Rails application or database.
Grover 1.2.10 limits Ruby to versions below 4.1. Future Ruby releases require
dependency review and renewed tests of the native option adapter.

Executed checks on arm64 macOS as of 2026-10-07:

| Bundle | Ruby | Evidence |
| --- | --- | --- |
| Core, without Rails | 3.2.9, 3.3.6, 3.4.8, 4.0.7 | Full unit suite, standalone core checks, and StandardRB |
| Rails 7.2.4 | 3.2.9 | Full suite and StandardRB, database-free Rails fixtures |
| Rails 8.1.4 | 3.3.6 | Full suite and StandardRB, database-free Rails fixtures |
| Actual browser, Chrome 139 and Puppeteer 24.17.0 | 3.4.8, 4.0.7 | Portrait/landscape, shared-cache 2/3 totals, fonts, placement, cache hits and owned cleanup |

Ruby's official download page lists 4.0.7 as latest stable on this date.
The root development lock now selects Ruby-3.2-compatible `parallel 1.28.0`.
This resolves the frozen-install failure from `parallel 2.3.0`, which requires
Ruby 3.3. No production dependency or gemspec Ruby requirement changed.
Default root suites skip optional Rails and browser cases. Unit checks replace
PDF conversion at the native processor boundary. The separately enabled browser
gate uses real conversion. Neither proves every possible Rails/Ruby combination.

## Generate a document

```ruby
require "paradem_pdf"

document = ParademPdf::Document.new(
  doc_type: "invoice",
  body_html: "<!doctype html><html><body>Invoice</body></html>",
  origin: "https://documents.example.test/",
  locale: "en",
  footer: ->(page:, total_pages:) {
    "<!doctype html><html><body><div style='position:fixed;bottom:0'>#{page} / #{total_pages}</div></body></html>"
  },
  options: {format: "Letter"},
  body_margins: {bottom: "23mm"},
  footer_margins: {bottom: "15mm"}
)

bytes = document.to_pdf
```

Headers and footers default to `nil`. Each callback returns a complete HTML
document and receives the actual body page count. Each overlay must render
exactly one page with geometry and rotation matching the body. Use the same
format and landscape setting for all parts. HTML metadata can affect geometry.

Applications own templates, styles, fonts, translations, filenames, HTTP
responses, and authorization. Each decoration must include its own font styles.
Margins reserve decoration space. The gem does not measure decorations or
automatically resize margins.

The origin must be an explicit HTTP or HTTPS URL with a host and no credentials,
query, or fragment. Request failures must raise. Origin validation is not an
HTML sanitizer or network allowlist. HTML and callbacks are trusted app inputs.

Caller options and HTML metadata cannot override the required origin or
request-failure policy. Explicit per-part margins override corresponding
global and caller margins. Conflicting metadata raises before conversion.

### Resource readiness

`Document.new` and `GroverRenderer.new` default to `readiness: true` and
`readiness_timeout: 20_000`. The timeout must be an Integer from 1 through
2,147,483,647 milliseconds, even when readiness is disabled. Larger values
overflow JavaScript timers and are rejected before rendering or cache work.
The policy applies to the body
and each header and footer.

After Grover normalizes global options, caller options, and HTML metadata,
readiness supplies `wait_until: "load"` only if no effective wait is set.
The awaited `execute_script` hook promotes lazy images to eager loading,
decodes images, forces layout in the selected media, and waits for fonts.
Failed image decoding, missing intrinsic image width, and failed font faces
raise. Unused unloaded font faces are allowed. The resource deadline raises
`PDF readiness timeout`; other resource errors identify `PDF image failed`
or `PDF font failed`. Failed renders do not publish incomplete PDFs to cache.

An explicit global, caller, or metadata `execute_script` replaces the generic
resource hook. The gem preserves that script unchanged and Grover awaits it
once. Its author owns resource readiness. The independent `load` default still
applies unless a wait is explicitly set. Caller `waitUntil` and `executeScript`
aliases are also accepted. Grover's JavaScript-disabled control remains in
effect and disables the resource hook.

Use `readiness: false` for complete opt-out. This adds neither the wait default
nor the resource script and restores native Grover waiting. Explicit waits
and scripts still apply. Asynchronous-page callers own their readiness policy;
the generic hook does not wait for arbitrary post-load mutations or fetches.

The gem does not force print media or change navigation, conversion, or launch
timeouts. Applications select media with `options: {emulate_media: "print"}`
when needed and may extend the separate resource deadline with
`readiness_timeout`. Both readiness settings enter completed and decoration
cache fingerprints, including opt-out and custom-script renders.

The owned launcher does not attach to page targets. Grover's worker connection
owns page emulation and evaluation. This prevents a second page session from
resetting the worker's selected media during navigation. The launcher still
owns browser shutdown and the same bounded process cleanup.

The separate resource proof is opt-in:

```sh
PARADEM_PDF_READINESS_BROWSER=1 \
PUPPETEER_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
PARADEM_PDF_TEST_FONT="/System/Library/Fonts/Supplemental/Arial.ttf" \
BUNDLE_FROZEN=true bundle exec ruby -Ilib -Itest test/readiness_browser_test.rb
```

When enabled, missing prerequisites fail rather than skip. Test-only transport
and observers exercise real Grover conversion, resource failures, custom scripts,
cache publication, and owned cleanup. Set `PARADEM_PDF_READINESS_ARTIFACTS` to
retain PDFs and event records outside the gem. Run
`ruby -Ilib -Itest test/support/readiness_benchmark.rb --benchmark DIRECTORY`
under the same enabled environment for ten paired serial cold/warm/hot comparisons with identical assets
and instrumentation. It is development evidence, not production CPU evidence.
The benchmark writes `benchmark.json` before exiting nonzero if appearance
differs or the median warm reduction is below 10%. The resource gate also runs
ten actual parallel header/footer pairs, rejecting corrupt print-only fonts
before printing or publishing any new cache entry.

## Managed browser and parallel rendering

Each render owns one headless Chrome. `Document#to_pdf` opens the browser
lazily, only when a conversion is actually needed, passes its WebSocket
endpoint into every Grover conversion, and closes it when the render ends. A
completed-cache hit returns before any browser launches.

At a high level, a render runs the body first (serially, to learn the page
count), then renders each header and footer overlay in parallel across a
bounded thread pool, then merges the overlays back onto their pages in order.
One Chrome serves every conversion in the render. Memory use and rendering
speed have not been measured.

```ruby
bytes = document.to_pdf
```

A batch shares one browser across documents and closes it after the block,
even on error:

```ruby
ParademPdf::Document.browser(options: {executable_path: "/path/to/chrome"}) do |browser|
  first_bytes  = first_document.to_pdf(browser: browser)
  second_bytes = second_document.to_pdf(browser: browser)
end
```

`to_pdf` closes only the browser it opened itself. A `browser:` passed in is
owned by the caller and is never closed by `to_pdf`.

Batch endpoint waiting defaults to 30 seconds, including an explicit nil
timeout. Endpoint and native launch timeouts must be finite positive numbers.
Cleanup uses bounded close and owned-group reaping. Forced cleanup, unsuccessful
native close, or an unreaped launcher raises `ParademPdf::BrowserError`.
A closed browser cannot be reused. Cleanup errors retain any active render
error in their cause chain.

Overlay conversions fan out across a bounded thread pool. Set the per-document
concurrency with the constructor option:

```ruby
document = ParademPdf::Document.new(..., concurrency: 4)
```

`concurrency:` defaults to `max(Etc.nprocessors - 1, 1)` and must be a positive
Integer. Cache reads and writes stay on the main thread; only conversions run
on worker threads.

The launcher reuses the application's existing Node.js and Puppeteer
installation, resolved exactly as Grover's worker does. Runtime prerequisites
are unchanged: Node.js, a compatible Puppeteer installation, and Chrome or
Chromium.

Grover 1.2.10's native worker remains responsible for conversion and cleanup.
Each endpoint conversion loads a small worker-local wrapper. Its Puppeteer
`targetFilter` accepts only targets in that conversion's browser context, plus
the browser target. This prevents parallel connections from retaining sibling
page sessions and resetting their media or other emulation state. It requires
the public `BrowserContext.id`, `Target.browserContext()` and `targetFilter`
APIs. The launcher continues to exclude page targets.

The wrapper extends only that Ruby processor instance. It preserves configured
`js_runtime_bin` arguments, preloads and `node_env_vars`; it does not change
global Grover configuration. Review this private spawn boundary on Grover
upgrades. Native options, CSP controls, caller scripts and the stdout protocol
are unchanged. No conversion service or serial-only policy is introduced.

Cache fingerprints still describe effective rendering inputs, not transport
attachment filters. If reusing entries generated by the unfixed readiness
branch, bump the caller's existing freshness or asset version first. A corrupt
print-only font may previously have been accepted and cached after a media reset.

`browser_ws_endpoint` is infrastructure, never a cache input or fingerprint.
It is a conversion-time argument, not a rendering option.
Global and body-metadata launch options use Grover's captured native
normalization, including timeout coercion. Explicit global/metadata endpoints
are also excluded from rendering fingerprints and do not trigger managed launch.

Naming: `options[:browser]` keeps Grover's meaning — the puppeteer browser
channel (for example `"firefox"`). `to_pdf(browser:)` takes a
`ParademPdf::Browser` instance. `Document.browser` is the batch class method.
These are distinct; the channel option is not the instance.

The gem rejects browser security-bypass flags — `no-sandbox`,
`disable-setuid-sandbox`, `disable-web-security`, and
`ignore-certificate-errors` — and `GROVER_NO_SANDBOX=true`, before launching.

## Cache PDF bytes

Supply a store with `read(key)` and `write(key, bytes, expires_in:)`.
When enabling caching, also supply all of:

- `cache_namespace`: a nonblank application namespace.
- `freshness`: every dependency of callback output, including templates and helper data.
- `assets_version`: an asset fingerprint or explicit asset release version.
- `expires_in`: a positive numeric duration in seconds.

Freshness and asset inputs accept strings or JSON-compatible data with string
hash keys. Hash key order does not change the resulting fingerprint.

Completed-document hits skip conversion and per-page callbacks. The application
must compute freshness from the same data snapshot captured by its callbacks.
Undeclared callback changes cannot be detected. Use `cache: nil` if dependencies
cannot be declared reliably.

Decoration keys include namespace, document type, header or footer kind, locale,
page, total pages, rendered HTML, effective rendering options, margins, origin,
asset version, and render version. Identical decorations can share cached bytes
across documents. The complete body fingerprint is not part of a decoration key.

Cache entries contain valid, nonempty PDF bytes, never mutable page objects.
Corrupt entries regenerate. Overlay entries must contain exactly one page.
Rejected writes return valid generated bytes by default. Use
`document.to_pdf(require_cache_write: true)` to raise
`ParademPdf::CacheWriteFailed` when a required write returns false or nil.
Store exceptions propagate. Concurrent cold misses may duplicate work.

## Optional Rails integration

```ruby
require "paradem_pdf/rails"

renderer = ParademPdf::RailsRenderer.new(
  renderer: supplied_controller_renderer,
  layout: "pdf"
)

html = renderer.render(
  template: "reports/body",
  locals: {title: "Report"},
  assigns: {rows: report_rows}
)

document = ParademPdf::Rails.document(
  doc_type: "report", body_html: html,
  origin: "https://documents.example.test/", locale: "en",
  header: nil, footer: nil, cache: nil
)
bytes = document.to_pdf
```

Use `layout: false` for standalone HTML. The renderer forwards templates,
locals, and assigns without changing locale state.

`ParademPdf::Rails.document(**options)` uses the configured `Rails.cache` only
when `cache` is omitted. Explicit `cache: nil` disables caching. The application
still supplies the namespace, freshness, asset version, and expiry.
The integration installs no engine, routes, migrations, or initializer.

Here `supplied_controller_renderer` and `report_rows` are caller inputs.
Templates can use explicit locals and instance-variable assigns. Decorations
can call the same renderer with page and total locals. Keep translation scopes
and the snapshot used for freshness in the application.

## Image documents

Render image HTML in the application, then pass it as an undecorated document:

```ruby
image_html = <<~HTML
  <!doctype html><html><body style="margin:0">
    <img src="/assets/photo.png" alt="Photo" style="max-width:100%;max-height:90vh">
  </body></html>
HTML

image_pdf_bytes = ParademPdf::Document.new(
  doc_type: "image", body_html: image_html,
  origin: "https://documents.example.test/", locale: "en",
  header: nil, footer: nil, options: {format: "Letter", landscape: true}
).to_pdf
```

The origin resolves slash-prefixed asset URLs through Grover. The application
must supply accessible images, escape dynamic HTML values, and choose sizing
and pagination. The gem does not load attachments or manage storage records.

## Concatenate PDFs

```ruby
combined_bytes = ParademPdf::Document.merge([first_pdf_bytes, second_pdf_bytes])
```

Input order and page geometry are preserved. Empty lists and invalid PDFs raise.
Concatenation does not renumber existing pages. Applications load attachments
and render image-document HTML themselves. For example, merge report bytes,
image-document bytes, and an existing PDF with
`ParademPdf::Document.merge([bytes, image_pdf_bytes, attachment_pdf_bytes])`.
These examples document generic capabilities, not a verified application or
storage migration. Extraction alone makes no cold-render speed claim.

Invalid PDF bytes raise `ParademPdf::InvalidPdf`, a subclass of
`ParademPdf::Error`. Invalid API inputs raise `ArgumentError`. Grover failures
retain their original exception and cause.

## Development

Run the current checks with the reviewed lock:

```sh
BUNDLE_FROZEN=true bundle install
bundle exec rake test
bundle exec standardrb
gem build paradem_pdf.gemspec
```

Tests use Minitest. Each behavior starts with an observed failing test before
implementation. Check the core with the root bundle, without Rails:

```sh
BUNDLE_FROZEN=true bundle exec rake test TEST='test/bootstrap_test.rb,test/document_test.rb,test/cache_test.rb,test/grover_renderer_test.rb'
```

Run each database-free Rails compatibility bundle separately under a compatible
Ruby, then run StandardRB with the same environment:

```sh
BUNDLE_FROZEN=true BUNDLE_GEMFILE=gemfiles/rails_7_2.gemfile bundle exec rake test
BUNDLE_FROZEN=true BUNDLE_GEMFILE=gemfiles/rails_7_2.gemfile bundle exec standardrb
BUNDLE_FROZEN=true BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bundle exec rake test
BUNDLE_FROZEN=true BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bundle exec standardrb
```

The committed CI workflow covers Ruby 3.2, 3.3, 3.4, 4.0, plus `ruby` to track
latest stable. It includes separate Rails 7.2/Ruby 3.2 and Rails 8.1/Ruby 3.3
checks and one normal-security Linux browser job. The workflow has not been
executed in GitHub Actions as part of this verification.

### Opt-in browser check

`test/browser_test.rb` and `test/support/browser_fixture.rb` use the
`PARADEM_PDF_BROWSER=1` opt-in flag. Install Puppeteer in the checkout or expose
an existing compatible installation with `NODE_PATH`. For a new local installation:

```sh
npm install --no-save --package-lock=false puppeteer@24.17.0
```

Use Node 22 or another version supported by that Puppeteer release. Set
`PUPPETEER_EXECUTABLE_PATH` to a compatible Chrome/Chromium executable.
Install Poppler for `pdffonts` and `pdftotext`, for example `brew install poppler`
on macOS or `sudo apt-get install poppler-utils fonts-dejavu-core` on Debian.
Supply a readable platform font with `PARADEM_PDF_TEST_FONT`, such as
`/System/Library/Fonts/Supplemental/Arial.ttf` on macOS or
`/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf` on Linux.
Do not copy application-owned fonts into the repository or gem package.

```sh
env -u GROVER_NO_SANDBOX PARADEM_PDF_BROWSER=1 BUNDLE_FROZEN=true \
  PARADEM_PDF_TEST_FONT="/path/to/platform-font.ttf" \
  PUPPETEER_EXECUTABLE_PATH="/path/to/chrome" \
  bundle exec rake test TEST='test/browser_test.rb'
```

The check uses actual conversion of two- and three-page portrait and
landscape documents with dynamic headers and footers. It inspects embedded
fonts with `pdffonts` and per-page text positions with `pdftotext -bbox`.
Body margins must keep decorations clear of body text. Separate headers and
footers must each load their font. The fixture renders through the managed
browser and expects one browser launch per cold or warm render, none for a
completed hit, and one for a shared batch, not one per conversion. Both totals
reuse a cache store. Warm decorations require one body conversion. Every native
body/header/footer PDF is checked for embedded fonts before capture reset.
It uses finite launch, navigation,
conversion, and worker deadlines and cleans up only its own browser process
group. It rejects sandbox, web-security, or certificate bypass flags.
An opt-in run with missing prerequisites must fail, not silently skip.
A skipped browser test is not browser evidence.

Actual checks passed with platform Arial on arm64 macOS, Node 22.22.2,
Puppeteer 24.17.0 and Chrome for Testing 139.0.7258.138. They cover generic Latin
fixture text, not application-specific fonts, multilingual glyphs or layouts.
Normal close and child reaping were recorded with no forced cleanup.

## License and distribution

Management has not selected the license. Do not assume MIT or redistribution
rights. No license file or gem license declaration is approved yet.
Publishing, pushing, and deployment require separate authorization.
