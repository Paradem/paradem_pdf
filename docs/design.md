# Design

## Application boundary

HTML and callbacks are trusted application inputs. The application owns
authorization, data snapshots, translation policy, templates, asset access, and
output delivery. `locale` identifies rendering and cache inputs; the gem does
not set `I18n.locale` or translate HTML.

The origin must be an explicit HTTP or HTTPS URL with a host. Credentials,
queries, and fragments are rejected. Grover preprocesses supported asset paths
against that origin. Origin validation does not sanitize HTML or restrict network
access to an allowlist.

See `normalize_origin` in [grover_renderer.rb](../lib/paradem_pdf/grover_renderer.rb)
and [grover_renderer_test.rb](../test/grover_renderer_test.rb).

## Effective rendering options

`GroverRenderer` keeps version-dependent normalization and private Grover calls
in one place. It captures effective options once and uses those inputs for both
conversion and fingerprints. Global configuration, caller options, and HTML
metadata can all contribute to those options.

Required controls cannot be overridden:

- The effective display URL must match the selected origin.
- Request failures must raise.
- Explicit per-part margins override corresponding caller and global margins.
  Metadata that conflicts with the selected effective margins raises.

Other Grover options retain native normalization and precedence. The adapter
accepts selected caller aliases; it does not promise every raw Puppeteer option
name. Use Grover's documented snake_case options.

Review this boundary when updating the pinned Grover dependency. The
normalization, alias, metadata, and fingerprint checks are in
[grover_renderer_test.rb](../test/grover_renderer_test.rb).

## Resource readiness

The default readiness policy supplies `wait_until: "load"` when no effective wait
is set. It then uses Grover's awaited script hook to promote lazy images, decode
images, request layout in the selected media, and await fonts. Image decoding
errors, images without intrinsic width, failed font faces, and the resource
deadline raise. Unused unloaded font faces are allowed.

An effective `execute_script` replaces the generic hook. Its author owns
resource readiness. Disabling JavaScript also disables the hook. Setting
`readiness: false` removes both the added wait default and the resource hook;
explicit Grover waits and scripts still apply.

The policy does not force print media or wait for arbitrary post-load DOM
mutations or fetches. The resource timeout is separate from browser launch,
navigation, and PDF conversion timeouts. Readiness settings enter fingerprints
even with a custom script or opt-out.

Sources: [grover_renderer.rb](../lib/paradem_pdf/grover_renderer.rb),
[readiness.js](../lib/paradem_pdf/readiness.js).
Checks: [readiness_script_test.rb](../test/readiness_script_test.rb),
[readiness_browser_test.rb](../test/readiness_browser_test.rb).

## PDF validation and assembly

Generated and cached data must be nonempty PDF bytes with pages and valid page
geometry. A decoration must contain exactly one page. Its visible page box,
rotation, and user unit must match the body page. The gem does not scale an
overlay to fit a different page.

Each assembly parses fresh pages. Cache entries never hold mutable CombinePDF
objects. A completed document is written only after successful assembly and
validation. Earlier successful decoration writes may remain if a later
decoration or completed write fails.

The application reserves header and footer space with margins and positions
its own HTML. The gem does not measure decorations or prevent visual overlap.

See `parse_pdf`, `page_geometry`, and `validate_overlay` in
[document.rb](../lib/paradem_pdf/document.rb), plus
[document_test.rb](../test/document_test.rb).

## Cache ownership

Only the supplied store's `read` and `write` methods are used. Invalid cached
PDFs are misses. Store exceptions propagate. False or nil writes are best-effort
by default and raise in strict mode.

The application declares every callback dependency through `freshness`, using
the same data snapshot that the callbacks capture. Completed hits skip callbacks,
so the gem cannot discover undeclared changes. Authorization must occur before
using cached bytes. Asset dependencies belong in `assets_version`.

There is no cache lock or single-flight coordination. Concurrent cold misses
may duplicate conversion. See [optimizations.md](optimizations.md) for reuse and
[cache.rb](../lib/paradem_pdf/cache.rb) for canonicalization and validation.

## Browser security and cleanup

Managed launches reject sandbox, web-security, and certificate bypass flags,
as well as `GROVER_NO_SANDBOX=true`. Configure a browser environment with its
normal security controls instead of disabling them. Caller-managed browser
infrastructure remains the caller's responsibility.

Launch endpoint waiting, normal close, and forced reaping have explicit bounds.
The Ruby owner signals only the launcher's owned process group. Forced cleanup,
unsuccessful native close, or an unreaped launcher raises `BrowserError`.
Cleanup errors preserve an active render error in their cause chain.

See [browser.rb](../lib/paradem_pdf/browser.rb),
[browser.js](../lib/paradem_pdf/browser.js), and
[browser_lifecycle_test.rb](../test/browser_lifecycle_test.rb).
