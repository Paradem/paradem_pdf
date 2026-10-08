# ParademPdf

Convert application-supplied HTML to PDF, add per-page HTML headers and footers,
cache PDF bytes, and concatenate PDFs. ParademPdf works as a standalone Ruby gem
with optional Rails adapters.

Your application supplies templates, CSS, fonts, translations, asset access,
authorization, and output filenames. The gem uses Grover for conversion and
CombinePDF for assembly.

## Requirements

- Ruby 3.2 or newer, within the limits of the installed dependencies.
- Node.js, compatible Puppeteer, and Chrome or Chromium for HTML conversion.
- Rails only if using the optional adapters.

The current Grover dependency requires Ruby below 4.1. See
[paradem_pdf.gemspec](paradem_pdf.gemspec) for dependency declarations and
[development](docs/development.md) for compatibility checks. The gem does not
install Node packages or download a browser during rendering.

## Setup

For a published release, add this to an existing project's `Gemfile`:

```ruby
gem "paradem_pdf"
```

Before publication, use a local checkout instead:

```ruby
gem "paradem_pdf", path: "../paradem_pdf"
```

Replace the path with the checkout's location. For a new standalone project,
run `bundle init` first, then add one of those entries. Install the Ruby bundle
and a compatible Puppeteer release from your project's directory:

```sh
bundle install
npm install puppeteer@24.17.0
```

Puppeteer 24.17.0 with Node 22 is the fixture setup, not a universal version
requirement. Use an existing compatible installation if your project already
has one. For that Puppeteer installation, select its downloaded Chrome:

```sh
export PUPPETEER_EXECUTABLE_PATH="$(node -p 'require("puppeteer").executablePath()')"
```

Alternatively, pass `options: {executable_path: "/path/to/chrome"}` to a document.
Keep Chrome's normal security controls enabled. Managed launches reject sandbox,
web-security, and certificate bypass flags, and `GROVER_NO_SANDBOX=true`.
See [troubleshooting](docs/troubleshooting.md) for deployment issues.

## Generate a document

Save this as `generate.rb` and run `bundle exec ruby generate.rb`:

```ruby
require "paradem_pdf"

html = <<~HTML
  <!doctype html><html><head><link rel="icon" href="data:,"></head>
  <body><h1>Invoice</h1><p>Total: $25.00</p></body></html>
HTML

document = ParademPdf::Document.new(
  doc_type: "invoice",
  body_html: html,
  origin: "https://documents.example.test/",
  locale: "en",
  options: {format: "Letter"}
)

bytes = document.to_pdf
File.binwrite("invoice.pdf", bytes)
```

`to_pdf` returns PDF bytes, not a filename. `doc_type` and `locale` identify
rendering/cache inputs; they do not select templates or change translation state.

Supply an explicit HTTP(S) origin with a host and no credentials, query, or
fragment. Choose your actual asset origin when the HTML references assets.
Origin validation is not HTML sanitization or a network allowlist. HTML and
callbacks must be trusted application inputs. Request failures must raise.

### Headers and footers

Add a callback returning a complete HTML document. It receives one-based `page`
and the actual `total_pages` from the rendered body:

```ruby
document = ParademPdf::Document.new(
  doc_type: "invoice", body_html: html,
  origin: "https://documents.example.test/", locale: "en",
  footer: ->(page:, total_pages:) {
    <<~HTML
      <!doctype html><html><head><link rel="icon" href="data:,"></head>
      <body><div style="position:fixed;bottom:0">#{page} / #{total_pages}</div></body></html>
    HTML
  },
  options: {format: "Letter"},
  body_margins: {bottom: "23mm"},
  footer_margins: {bottom: "15mm"}
)
File.binwrite("invoice-with-footer.pdf", document.to_pdf)
```

Headers use the same callback contract. Both default to nil. Each decoration
needs its own CSS and fonts and must produce exactly one page matching the body
geometry and rotation. Reserve space with body margins; the gem does not measure
decorations or resize margins. Conflicting effective HTML metadata controls raise.

## Readiness

By default, the gem waits for page load when no effective wait is set, decodes
images, and waits for fonts. Resource failures raise. The separate resource
deadline defaults to 20 seconds; set `readiness_timeout:` in milliseconds to
change it, or `readiness: false` to opt out of the added readiness policy.

A Grover `execute_script` replaces the generic image/font hook. Its author owns
readiness. The default does not wait for arbitrary asynchronous application
updates or force print media. See [design](docs/design.md#resource-readiness).

## Caching

Supply a store supporting `read(key)` and `write(key, bytes, expires_in:)`.
For example, with your application's `supplied_cache_store` and the HTML above:

```ruby
cached_document = ParademPdf::Document.new(
  doc_type: "invoice", body_html: html,
  origin: "https://documents.example.test/", locale: "en",
  cache: supplied_cache_store,
  cache_namespace: "my-app/invoices",
  freshness: {"template" => "invoice-v1", "snapshot" => "invoice-42-revision-3"},
  assets_version: "assets-v1",
  expires_in: 3600
)
bytes = cached_document.to_pdf
```

Declare every callback data/template dependency through `freshness`, and asset
dependencies through `assets_version`. Use JSON-compatible values with String
Hash keys. Render and compute freshness from the same data snapshot.

Completed hits skip conversion, callbacks, and browser launch. Decorations can
also reuse cached bytes. Undeclared callback changes cannot invalidate completed
hits. Authorize access before returning bytes, and use `cache: nil` if dependencies
cannot be declared reliably.

False or nil writes are best-effort by default. Use
`cached_document.to_pdf(require_cache_write: true)` to require successful writes.
Store exceptions propagate. See [optimizations](docs/optimizations.md) and the
[API reference](docs/api-reference.md).

## Parallel rendering

The body renders first to learn the page count. Header/footer conversion misses
then run in a bounded thread pool and merge in page order. Callbacks and cache
operations stay on the calling thread. One managed browser serves the render.

Set `concurrency:` to a positive Integer when constructing a document. The
default is processor count minus one, with a minimum of one; `concurrency: 1`
serializes overlay conversions. Tune for your deployment rather than assuming
more workers are faster. See [optimizations](docs/optimizations.md).

## Optional Rails integration

In an initialized Rails application, supply your controller renderer and a PDF
template/layout:

```ruby
require "paradem_pdf/rails"

renderer = ParademPdf::RailsRenderer.new(
  renderer: ApplicationController.renderer,
  layout: "pdf"
)
html = renderer.render(template: "reports/body", locals: {title: "Report"})

document = ParademPdf::Rails.document(
  doc_type: "report", body_html: html,
  origin: "https://documents.example.test/", locale: "en",
  cache: nil
)
bytes = document.to_pdf
```

Use `layout: false` for a template that produces complete HTML itself. `render`
also accepts `assigns:` for instance-variable inputs. Decorations can use the
same adapter with page and total locals. The adapter does not change locale state.

When `cache` is omitted, `Rails.document` uses `Rails.cache`; supply all required
cache inputs. Explicit `cache: nil` disables caching. The gem installs no engine,
routes, migrations, or initializer. See the [API reference](docs/api-reference.md).

## Images

Render images as HTML, then convert the HTML like any other document:

```ruby
image_html = <<~HTML
  <!doctype html><html><body style="margin:0">
    <img src="/assets/photo.png" alt="Photo" style="max-width:100%;max-height:90vh">
  </body></html>
HTML

image_bytes = ParademPdf::Document.new(
  doc_type: "image", body_html: image_html,
  origin: "https://documents.example.test/", locale: "en",
  options: {format: "Letter", landscape: true}
).to_pdf
```

Replace the example URL and origin with accessible assets. Grover resolves
slash-prefixed asset URLs against the origin. Your application escapes dynamic
HTML values, chooses sizing and pagination, and loads attachments. The gem does
not integrate with storage records.

## Concatenation

Given PDF bytes from rendering or existing files:

```ruby
attachment_bytes = File.binread("attachment.pdf")
combined_bytes = ParademPdf::Document.merge([bytes, image_bytes, attachment_bytes])
File.binwrite("combined.pdf", combined_bytes)
```

Input order and page geometry are preserved. Empty lists and invalid PDFs raise
`ParademPdf::InvalidPdf`. Concatenation does not renumber existing page labels.
See the [error reference](docs/api-reference.md#errors).

## Standalone use

No Rails application or database is needed. You can render HTML with your own
template system, or read a complete HTML file:

```ruby
require "paradem_pdf"

document = ParademPdf::Document.new(
  doc_type: "report", body_html: File.read("report.html"),
  origin: "https://documents.example.test/", locale: "en"
)
File.binwrite("report.pdf", document.to_pdf)
```

## Batching

Share one browser across existing document instances:

```ruby
ParademPdf::Document.browser do |browser|
  File.binwrite("report.pdf", document.to_pdf(browser: browser))
  File.binwrite("invoice.pdf", cached_document.to_pdf(browser: browser))
end
```

The block closes its browser even on error. Individual `to_pdf` calls never close
the supplied browser. This is browser reuse, not parallel document scheduling.
The batch opens a browser even if every document is cached. Use ordinary `to_pdf`
for individual completed hits when no browser is needed. Batch launch options go
on `Document.browser(options: ...)`. See the [API reference](docs/api-reference.md).

## Running tests

Run these commands from the gem checkout's root directory. Install the committed
Ruby bundle if needed, then run the Minitest suite:

```sh
BUNDLE_FROZEN=true bundle install
BUNDLE_FROZEN=true bundle exec rake test
```

To run one test file:

```sh
BUNDLE_FROZEN=true bundle exec rake test TEST='test/bootstrap_test.rb'
```

Real-browser tests are skipped unless explicitly enabled. They require Node.js,
Puppeteer, Chrome/Chromium, and Poppler. Both the font and Chrome paths must be
supplied. For macOS with Google Chrome installed in `/Applications`, run:

```sh
env -u GROVER_NO_SANDBOX -u NODE_OPTIONS \
PARADEM_PDF_TEST_FONT='/System/Library/Fonts/Supplemental/Arial.ttf' \
PUPPETEER_EXECUTABLE_PATH='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
PARADEM_PDF_BROWSER=1 BUNDLE_FROZEN=true bundle exec rake test TEST='test/browser_test.rb'
```

Use your platform's font and browser paths on other systems. See
[browser checks](docs/browser-check.md) for installation and Linux examples.
When enabled, missing prerequisites fail rather than skip.
The command unsets inherited sandbox bypass settings and Node preloads for this
run only; the browser fixture rejects them.

To check Ruby formatting:

```sh
BUNDLE_FROZEN=true bundle exec standardrb
```

See [development](docs/development.md) for separate Rails compatibility checks.

## Technical documentation

- [Architecture](docs/architecture.md)
- [Design](docs/design.md)
- [Optimizations](docs/optimizations.md)
- [Development](docs/development.md)
- [Browser checks](docs/browser-check.md)
- [API reference](docs/api-reference.md)
- [Troubleshooting](docs/troubleshooting.md)

These guides link to implementation and tests rather than copying internal code.
Source/test links refer to the repository; the gem packages the usage and
technical guides, not its test fixtures.

## License

MIT. See [LICENSE](LICENSE).
