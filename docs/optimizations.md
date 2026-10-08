# Optimizations

These mechanisms reduce repeated work. They are not a guarantee of a particular
latency, memory usage, CPU cost, or speedup in an application.

## Completed-document caching

A valid completed hit returns stored bytes without conversion, per-page
callbacks, or a managed browser launch. The gem still captures effective
rendering inputs to find the key.

The key includes body rendering inputs, decoration presence and configuration,
namespace, document type, locale, render version, asset version, and explicit
callback freshness. Changing callback output without changing declared freshness
cannot invalidate a completed hit.

The application must compute freshness and render from the same snapshot.
Use `cache: nil` when callback dependencies cannot be declared reliably.

See `completed_inputs` in [document.rb](../lib/paradem_pdf/document.rb) and
`test_completed_hit_skips_all_conversion_and_callbacks` in
[document_test.rb](../test/document_test.rb).

## Decoration reuse

Headers and footers have separate entries. Their keys include page, actual total
pages, decoration HTML, effective rendering inputs, and shared cache identifiers.
They do not include the complete body fingerprint or callback freshness.
Identical decorations can therefore reuse bytes across documents.

When only decorations hit, the body still converts to establish the page count,
and callbacks still run to produce decoration inputs. Only overlay conversion
is avoided. Totals remain in the key so a two-page footer cannot be reused for a
three-page document.

Keys are bounded SHA-256 fingerprints of canonical JSON inputs. String-keyed
hash order does not change a key; array order does. Browser endpoints are not
rendering inputs.

See `overlay_inputs` and `resolve_overlays` in
[document.rb](../lib/paradem_pdf/document.rb), [cache.rb](../lib/paradem_pdf/cache.rb),
and the cache reuse cases in [document_test.rb](../test/document_test.rb).

## Parallel overlay conversions

The body converts serially. Decoration misses use a bounded stdlib thread pool
inside the same browser. Callbacks, cache operations, validation, and merging
stay on the calling thread. Results merge in page order rather than completion
order.

The default pool size is one fewer than the detected processor count, with a
minimum of one. `concurrency: 1` serializes overlay conversions. Increasing the
pool does not parallelize the body or callbacks. Tune it for the deployment's
browser and memory budget rather than assuming more workers are faster.

The bounds and thread behavior are checked in
[render_thread_test.rb](../test/render_thread_test.rb). Browser context isolation
is implemented in [worker_context.cjs](../lib/paradem_pdf/worker_context.cjs).

## Browser reuse in batches

`Document.browser` opens one browser for its block. Pass it to each document's
`to_pdf(browser:)` to avoid launching a separate browser for every document.
Documents in a normal sequential block still render sequentially. Batching is
browser reuse, not a document scheduler.

The batch browser opens even if every document is a completed-cache hit. For
isolated hits, ordinary `to_pdf` avoids browser launch entirely.

See `Document.browser` in [document.rb](../lib/paradem_pdf/document.rb) and the
batch cases in [document_test.rb](../test/document_test.rb).

## Measuring changes

[browser-check.md](browser-check.md) describes real conversion gates and the
readiness benchmark. The benchmark compares readiness policies with identical
instrumentation and assets across cold, decoration-warm, and completed-hot
states. It uses serial overlay conversions and is not a parallel-rendering
benchmark or production CPU evidence.

Measure application layouts, fonts, assets, and cache hit rates before making
application performance claims. Concurrent cold misses can duplicate work;
there is no built-in locking or single-flight cache coordination.
