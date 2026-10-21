# Opt-in Rails precaching

Require `paradem_pdf/rails`. Applications own inputs, rendering, cache identity,
authorization, locale scope, and event relevance. The optional integration owns
batch execution and best-effort in-process scheduling. Core loading needs no Rails.

## Opt in a document type

Configure class-name Strings during boot, without loading classes or querying data:

```ruby
ParademPdf.configure do |config|
  config.precache_document_classes = %w[GuidePdf ReceiptPdf]
end
```

Each class includes `ParademPdf::Rails::Precacheable`, defines `.precache_entries`,
and uses its normal instance `#to_pdf` path. Entries are an Array of Symbol-keyed
keyword Hashes. They cannot contain `:browser` or `:require_cache_write`.
Enumeration returns inputs only. Each attempt constructs a fresh instance.

For example, a second document can use the same infrastructure:

```ruby
class ReceiptPdf
  include ParademPdf::Rails::Precacheable

  def self.precache_entries
    [{locale: "en"}]
  end

  def self.precache_affected_by?(event, payload)
    event == "receipts.changed"
  end

  def to_pdf(locale:, browser: nil, require_cache_write: false)
    ParademPdf::Rails.document(
      doc_type: "receipt", locale: locale,
      body_html: "<html><body>Receipt</body></html>",
      cache_key: {"template" => "receipt-v1"}
    ).to_pdf(browser: browser, require_cache_write: require_cache_write)
  end
end
```

The example assumes the app has configured an origin, cache, namespace, and its
own cache version. Real documents declare all content dependencies in their key.
The default relevance predicate returns false. Missing `.precache_entries` raises
`ParademPdf::PrecacheConfigurationError`.

## Execute

```ruby
result = ParademPdf::Rails.precache
result = ParademPdf::Rails.precache(documents: ["ReceiptPdf"], on_warning: ->(warning) { puts warning })
status = ParademPdf::Rails.precache_later(reason: :manual)
```

Synchronous execution returns `Precache::Result` with `attempted`, `succeeded`,
and `failed` counts. Selection must be a subset of configured names. Classes are
resolved inside the Rails reloader on every pass. All entries are validated and
materialized before Chrome starts. Empty selections or entries open no browser.
Otherwise one owned browser serves every serial attempt across all selected types.

Each attempt receives `browser:` and `require_cache_write: true`. Strict rendering
requires an effective document cache before HTML or browser work. Explicit nil
disables even a global cache; a document-owned cache works without a global cache.
Nil and false cache versions remain valid. Cache hits need no new writes. Strict
writes enforce the store's existing success contract, not read-after-write durability.

Construction and rendering failures count as failed attempts and do not stop later
entries or types. Configuration, enumeration, browser ownership/cleanup, warning
callback, and warning logger failures abort with `Precache::InfrastructureError`.
The public exception has a sanitized exception-class diagnostic and nil cause.
Do not expose internal exception messages. Warnings contain only configured class,
one-based entry index within that type, and exception class. Tokens are bounded
and whitespace is collapsed. Each warning is logged once and sent to `on_warning`.

## Schedule after application events

An application event bridge resolves configured classes, asks each current class's
`.precache_affected_by?(event, payload)`, and calls `.precache_later` once when any
type matches. Predicate failures must not prevent later types being consulted.
The gem neither subscribes to events nor understands application payloads.
Additional types need no new scheduler, subscriber, initializer, or operational task.

Background admission returns `:started`, `:pending`, `:failed`, or `:skipped` for
an empty allowlist. Each process has one worker and one pending bit. Relevant
events request a complete pass of all opted-in types, not a selective queue.
Repeated submissions coalesce into one follow-up complete pass using current
classes and inputs. Unchanged entries reuse their normal caches.

Worker state survives application reloads and configuration resets. It retains no
application classes, entries, or notification payloads. Worker failures are logged
without leaking private messages and cannot break an already-committed save.
Save warnings go to logs only. Applications own synchronous tasks, stdout warnings,
timeouts, exit policy, deployment hooks, and subscriptions.

This is not durable delivery. Restarts can lose work. Multiple processes can warm
concurrently. There are no cross-process locks or automatic retries. Normal
downloads remain correct on a cache miss. Overlay concurrency is unchanged.
