# Architecture

ParademPdf is a standalone Ruby gem. Applications supply HTML, templates, CSS,
fonts, data, authorization, and filenames. The gem converts HTML, adds per-page
decorations, caches PDF bytes, and concatenates existing PDFs.

## Components

| Component | Responsibility | Source |
| --- | --- | --- |
| `Document` | Validate inputs, render and assemble pages, coordinate cache and browser use | [document.rb](../lib/paradem_pdf/document.rb) |
| `GroverRenderer` | Capture effective Grover options, enforce rendering controls, convert HTML | [grover_renderer.rb](../lib/paradem_pdf/grover_renderer.rb) |
| `Cache` | Fingerprint inputs, validate cached bytes, read and write the supplied store | [cache.rb](../lib/paradem_pdf/cache.rb) |
| `Browser` | Launch Chrome, supply its endpoint, close and reap owned processes | [browser.rb](../lib/paradem_pdf/browser.rb), [browser.js](../lib/paradem_pdf/browser.js) |
| Rails adapters | Forward template rendering and optionally use `Rails.cache` | [rails_renderer.rb](../lib/paradem_pdf/rails_renderer.rb), [rails.rb](../lib/paradem_pdf/rails.rb) |

Grover owns native HTML preprocessing, option normalization, and PDF conversion.
CombinePDF parses, overlays, and concatenates PDFs. The gem does not implement
its own PDF parser or application cache store.

## Rendering flow

`Document#to_pdf` in [document.rb](../lib/paradem_pdf/document.rb) performs these steps:

1. Capture the body's effective rendering inputs.
2. Return validated completed-document bytes on a cache hit.
3. Obtain a browser endpoint. Open an owned browser only if conversion needs one.
4. Convert and validate the body to learn its actual page count.
5. Call headers and footers on the calling thread, in page order, header before footer.
6. Read cached decorations on the calling thread. Convert misses in a bounded thread pool.
7. Validate decorations and write their cache entries on the calling thread.
8. Overlay decorations onto body pages in order. Validate the completed PDF before caching it.
9. Close the browser if this render opened it, including when rendering raises.

Only conversions run on worker threads. Applications do not need thread-safe
callbacks or cache stores for this internal pool. Separate concurrent callers
still need to account for their own shared application state.

See [render_thread_test.rb](../test/render_thread_test.rb) for thread placement,
pool bounds, ordering, and error behavior. See
[document_test.rb](../test/document_test.rb) for assembly and cache behavior.

## Browser ownership

A normal render uses one managed browser for its body and all decoration
conversions. `Document.browser` opens one browser shared by documents in its
block. A render never closes a browser passed through `to_pdf(browser:)`.
The batch block owns that browser's cleanup.

Explicit Grover WebSocket endpoints use caller-owned infrastructure instead of
launching a managed browser. Endpoints are conversion transport, not cache inputs.
They are an advanced integration path, not needed for ordinary rendering.

The Node launcher does not attach to page targets. A conversion-local preload in
[worker_context.cjs](../lib/paradem_pdf/worker_context.cjs) limits each Grover
connection to its own browser context and the browser target. This prevents
sibling connections from changing a page's selected media or emulation state.
Grover still owns conversion and its native worker protocol.

The launcher and private worker boundary need review when Grover or Puppeteer
changes. Ownership and bounded cleanup tests are in
[managed_browser_test.rb](../test/managed_browser_test.rb) and
[browser_lifecycle_test.rb](../test/browser_lifecycle_test.rb).

## Optional Rails loading

[paradem_pdf.rb](../lib/paradem_pdf.rb) loads the core without Rails. Requiring
`paradem_pdf/rails` adds the adapters. It installs no engine, routes, models,
migrations, or initializer. Rails and its renderer remain application dependencies.

[bootstrap_test.rb](../test/bootstrap_test.rb) checks standalone loading.
[rails_test.rb](../test/rails_test.rb) and
[rails_renderer_test.rb](../test/rails_renderer_test.rb) exercise the optional
adapters in database-free Rails subprocesses.
