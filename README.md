# ParademPdf

ParademPdf is a standalone Ruby gem for converting app-supplied HTML to PDF,
adding per-page HTML headers and footers, concatenating PDFs, and caching PDF bytes.

The core provides document conversion, validated PDF concatenation, per-page
decorations, and byte caching. Optional Rails adapters use a supplied renderer
and the configured cache. Browser output verification is still pending.

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
| Core, without Rails | 3.2.9, 3.3.6, 3.4.6, 3.4.8, 4.0.1, 4.0.7 | Full unit suite, standalone core checks, and StandardRB |
| Rails 7.2.4 | 3.2.9 | Full suite and StandardRB, database-free Rails fixtures |
| Rails 8.1.4 | 3.3.6 | Full suite and StandardRB, database-free Rails fixtures |

Ruby's official download page lists 4.0.7 as latest stable on this date.
The root development lock now selects Ruby-3.2-compatible `parallel 1.28.0`.
This resolves the frozen-install failure from `parallel 2.3.0`, which requires
Ruby 3.3. No production dependency or gemspec Ruby requirement changed.
Root suites skip optional Rails cases. These checks replace PDF conversion at
the native processor boundary and do not prove browser output or every possible
Rails/Ruby combination.

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

## Managed browser and parallel rendering

Each render owns one headless Chrome. `Document#to_pdf` opens the browser
lazily, only when a conversion is actually needed, passes its WebSocket
endpoint into every Grover conversion, and closes it when the render ends. A
completed-cache hit returns before any browser launches.

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

Overlay conversions fan out across a bounded thread pool. Set the per-document
concurrency with the constructor option:

```ruby
document = ParademPdf::Document.new(..., concurrency: 4)
```

`concurrency:` defaults to `[Etc.nprocessors, 4].min` and must be a positive
Integer. Cache reads and writes stay on the main thread; only conversions run
on worker threads.

The launcher reuses the application's existing Node.js and Puppeteer
installation, resolved exactly as Grover's worker does. Runtime prerequisites
are unchanged: Node.js, a compatible Puppeteer installation, and Chrome or
Chromium.

`browser_ws_endpoint` is infrastructure, never a cache input or fingerprint.
It is a conversion-time argument, not a rendering option.

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

CI is planned for Ruby 3.2, 3.3, 3.4, 4.0, plus `ruby` to track latest stable.
It will include the separate Rails 7.2/Ruby 3.2 and Rails 8.1/Ruby 3.3 checks.
No CI run is claimed here.

### Planned opt-in browser check

The following fixture and flag are documented before their implementation.
`test/browser_test.rb` and `test/support/browser_fixture.rb` are not available
yet. After implementation, install Puppeteer in the checkout or expose an
existing compatible installation with `NODE_PATH`. For a new local installation:

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

The planned check uses actual conversion of two- and three-page portrait and
landscape documents with dynamic headers and footers. It inspects embedded
fonts with `pdffonts` and per-page text positions with `pdftotext -bbox`.
Body margins must keep decorations clear of body text. Separate headers and
footers must each load their font. The fixture renders through the managed
browser and expects one browser launch per render (two for the fixture), or
one per batch, not one per conversion. It uses finite launch, navigation,
conversion, and worker deadlines and cleans up only its own browser process
group. It rejects sandbox, web-security, or certificate bypass flags.
An opt-in run with missing prerequisites must fail, not silently skip.
A skipped browser test is not browser evidence.

## License and distribution

Management has not selected the license. Do not assume MIT or redistribution
rights. No license file or gem license declaration is approved yet.
Publishing, pushing, and deployment require separate authorization.
