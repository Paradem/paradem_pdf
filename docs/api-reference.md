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
| `body_html` | String containing application-rendered HTML, or zero-argument callable resolved only after a completed miss |
| `locale` | String identifying the locale; does not change translation state |

| Optional keyword | Default | Contract |
| --- | --- | --- |
| `origin` | Configuration | Explicit HTTP(S) URL with host, no credentials, query, or fragment; required directly or in configuration |
| `header`, `footer` | `nil` | Callable receiving `page:` and `total_pages:`, returning complete HTML as a String |
| `options` | Configuration | Grover option Hash, merged over a copy of configured options |
| `body_margins`, `header_margins`, `footer_margins` | `{}` | Per-part margin Hashes; corresponding values override caller and global margins |
| `cache` | Configuration, then Rails default | Store with `read(key)` and `write(key, bytes, expires_in:)`; explicit nil disables caching |
| `cache_namespace` | Configuration | Required nonblank String when caching |
| `cache_key` | `nil` | Required non-nil caller-owned dependency value when caching |
| `deploy_version` | Configuration | Immutable code and asset revision |
| `expires_in` | Configuration | Nil for no expiry, or finite positive Numeric seconds |
| `concurrency` | Processor count minus one, minimum one | Positive Integer bounding overlay conversion workers; nil selects the default |
| `readiness` | `true` | Boolean enabling the default image/font readiness policy |
| `readiness_timeout` | `20_000` | Integer milliseconds, 1 through 2,147,483,647, validated even when readiness is disabled |

Cache key and deployment values accept JSON-compatible data: Strings, Integers,
finite Floats, booleans, nil within containers, Arrays, and Hashes with String
keys. Cycles and unsupported objects raise. A cache key cannot be top-level nil.
See [cache.rb](../lib/paradem_pdf/cache.rb). Applications must declare HTML metadata
and dynamic translation changes in the key, since a hit never renders HTML.

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

Returns a `Document` with the same keyword contracts as `Document.new`. Both use
`Rails.cache` when no store is configured and `cache` is omitted. Explicit
configured or per-document `cache: nil` disables caching. When caching, supply a
namespace and cache key, directly or through the supported configuration defaults.
The adapter requires an initialized Rails environment to use its default cache.

Source and checks: [rails.rb](../lib/paradem_pdf/rails.rb),
[rails_test.rb](../test/rails_test.rb).

## Selective pruning

`ParademPdf.prune(version: nil, doc_type: nil, keys: nil, dry_run: false)` uses
the configured store. `Cache#prune` provides the same operation for an explicit
store. A version alone selects all entries for that deployment. Supplied filters
combine with AND; multiple keys match within the list. Blank or malformed supplied
filters raise instead of broadening the selection. Only nil omits a filter;
false is invalid. No selectors also raises.

The store implements `paradem_pdf_prune` with those keywords and returns
`{count: Integer, versions: Array}`. A dry run does not delete. Versions can contain
nil for unversioned entries. Stores can opt into write metadata with
`paradem_pdf_metadata_support?`; writes then receive `metadata:` containing
`"doc_type"` and `"deploy_version"`. Plain stores receive no additional keywords.

Applications own prune confirmation and deployment warnings. No Active Record or
Kamal dependency is required by the gem.

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
