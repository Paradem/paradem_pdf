# API reference

Require `paradem_pdf` for the standalone API. Require `paradem_pdf/rails` for the
optional Rails adapters. This reference covers integration methods; helper
methods in the implementation are not application extension points.

## `ParademPdf::Document.new`

Construct a document without converting it or invoking decoration callbacks.
The keyword signature and validation are in
[document.rb](../lib/paradem_pdf/document.rb).

| Required keyword | Contract |
| --- | --- |
| `doc_type` | String identifying the application document type and cache grouping |
| `body_html` | String containing application-rendered HTML |
| `origin` | Explicit HTTP(S) URL with host, no credentials, query, or fragment; used for asset preprocessing and display URL |
| `locale` | String identifying the locale; does not change translation state |

| Optional keyword | Default | Contract |
| --- | --- | --- |
| `header`, `footer` | `nil` | Callable receiving `page:` and `total_pages:`, returning complete HTML as a String |
| `options` | `{}` | Grover option Hash, subject to this gem's origin and request-failure controls |
| `body_margins`, `header_margins`, `footer_margins` | `{}` | Per-part margin Hashes; corresponding values override caller and global margins |
| `cache` | `nil` | Store with `read(key)` and `write(key, bytes, expires_in:)`; nil disables caching |
| `cache_namespace` | `nil` | Required nonblank String when caching |
| `freshness` | `nil` | Required non-nil callback dependency value when caching |
| `assets_version` | `nil` | Required non-nil asset dependency value when caching |
| `expires_in` | `nil` | Required finite positive Numeric seconds when caching |
| `concurrency` | Processor count minus one, minimum one | Positive Integer bounding overlay conversion workers; nil selects the default |
| `readiness` | `true` | Boolean enabling the default image/font readiness policy |
| `readiness_timeout` | `20_000` | Integer milliseconds, 1 through 2,147,483,647, validated even when readiness is disabled |

Freshness and asset values accept JSON-compatible data: Strings, Integers,
finite Floats, booleans, nil within containers, Arrays, and Hashes with String
keys. Cycles and unsupported objects raise. Top-level nil is not accepted for
these required caching values. See [cache.rb](../lib/paradem_pdf/cache.rb).

Page numbers start at one. Each decoration must render one page matching its
body page's geometry, rotation, and user unit. Callbacks run on the calling
thread in page order, header before footer. Completed cache hits skip them.
Applications reserve space and include CSS and fonts in each HTML part.

For Grover's general option catalog, see its
[documentation](https://github.com/Studiosity/grover#configuration).
The pinned adapter is [grover_renderer.rb](../lib/paradem_pdf/grover_renderer.rb).
This gem rejects conflicting origin, request-failure, and effective metadata
margin controls. `options[:browser]` is Grover's browser channel, not a
`ParademPdf::Browser` instance.

## `document.to_pdf`

Returns a String of validated PDF bytes. Write it with `File.binwrite` or pass
it to the application's response or storage layer.

| Keyword | Default | Contract |
| --- | --- | --- |
| `browser` | `nil` | Caller-owned `ParademPdf::Browser`; the render does not close it |
| `require_cache_write` | `false` | Raise `CacheWriteFailed` if a cache write returns false or nil |

Without a supplied browser or an explicit Grover endpoint, the render lazily
opens one managed browser and closes it on success or error. A completed hit
does not launch a browser. Strict writes do not force writes on hits and have
no effect when caching is disabled. Store exceptions propagate in both modes.

Source: `to_pdf` in [document.rb](../lib/paradem_pdf/document.rb).
Checks: [document_test.rb](../test/document_test.rb).

## `ParademPdf::Document.browser`

Requires a block, yields one open browser, returns the block's result, and closes
the browser when the block exits, including on error. Pass the yielded browser
to each `to_pdf(browser:)` call. The browser cannot be reused after closing.

| Keyword | Default | Contract |
| --- | --- | --- |
| `options` | `{}` | Grover launch options, such as `executable_path` and `launch_timeout` |
| `root_path` | `nil` | Working directory for Node package resolution; defaults through native Grover configuration |
| `timeout` | `nil` | Endpoint wait in seconds; nil selects 30 seconds; otherwise a finite positive Numeric |

A larger effective `launch_timeout`, measured in milliseconds, extends the
endpoint wait. Launch options come from the batch call, not from the individual
documents passed into the block. Rendering options still belong to each document.
The batch browser opens immediately, even for an all-cache-hit batch.

See [browser.rb](../lib/paradem_pdf/browser.rb) for launch and cleanup bounds,
and [browser_lifecycle_test.rb](../test/browser_lifecycle_test.rb) for checks.

## `ParademPdf::Document.merge(pdfs)`

Accepts a nonempty Array of PDF byte Strings and returns validated combined PDF
bytes. Input page order and geometry are preserved. It neither converts HTML
nor renumbers existing page labels. Invalid inputs, including an empty Array,
raise `InvalidPdf`.

Source and checks: `merge` in [document.rb](../lib/paradem_pdf/document.rb),
[document_test.rb](../test/document_test.rb).

## Optional Rails adapters

### `ParademPdf::RailsRenderer.new(renderer:, layout:)`

Both keywords are required. Supply a controller renderer and the layout name,
or `layout: false` for a template that produces complete HTML itself.

### `renderer.render(template:, locals: {}, assigns: {})`

Forwards those keywords and the configured layout to the supplied renderer.
The adapter does not change locale state. Applications choose the templates,
helper context, locals, assigns, and translation scope.

Source and checks: [rails_renderer.rb](../lib/paradem_pdf/rails_renderer.rb),
[rails_renderer_test.rb](../test/rails_renderer_test.rb).

### `ParademPdf::Rails.document(**options)`

Returns a `Document` with the same keyword contracts as `Document.new`. It uses
`Rails.cache` only when `cache` is omitted. Explicit `cache: nil` disables
caching. When caching, supply namespace, freshness, asset version, and expiry.
The adapter requires an initialized Rails environment to use its default cache.

Source and checks: [rails.rb](../lib/paradem_pdf/rails.rb),
[rails_test.rb](../test/rails_test.rb).

## Errors

| Exception | Meaning |
| --- | --- |
| `ParademPdf::Error` | Base class for gem-specific errors |
| `ParademPdf::InvalidPdf` | Invalid generated, decoration, or concatenation PDF bytes or geometry |
| `ParademPdf::CacheWriteFailed` | False or nil cache write in strict mode |
| `ParademPdf::BrowserError` | Managed browser launch, closed-browser use, or cleanup failure |
| `ArgumentError` | Invalid constructor, rendering control, cache dependency, or browser option input |

Corrupt cache entries normally regenerate instead of raising `InvalidPdf`.
A valid single-page cached overlay with incompatible geometry still raises.
Grover conversion errors, callback errors, and store exceptions propagate
without being converted to `ParademPdf::Error`. A cleanup failure can be the
top-level error with the active render error retained as its cause.

See [errors.rb](../lib/paradem_pdf/errors.rb),
[document_test.rb](../test/document_test.rb), and
[browser_lifecycle_test.rb](../test/browser_lifecycle_test.rb).
