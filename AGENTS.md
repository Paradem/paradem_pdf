# ParademPdf agent workflow

## Scope

This is a standalone Ruby gem, not a Rails engine. Keep application models,
templates, fonts, CSS, routes, authorization, filenames, and locale policies
outside the gem. Optional Rails integration must not affect core loading.

## Implementation

- Use Minitest in `test/`, not RSpec.
- Use TDD. Write a behavior test, observe its intended failure, implement the
  smallest fix, and run the complete test suite before marking work complete.
- Reuse Grover and CombinePDF. Do not add custom cache stores, browser services,
  locks, schedulers, model integrations, or dependencies without a concrete need.
- Keep version-dependent Grover normalization and private calls in
  `GroverRenderer`. Capture native effective options once for both fingerprints
  and conversion. Review this boundary when updating Grover.
- Test through the latest stable Ruby. Do not add an arbitrary Ruby upper bound
  to this gem. Report dependency limits and verified environments honestly.

## PDF and cache safety

Validate explicit origins and preserve request-failure rejection. Reject
conflicting effective origin, failure, or selected margin controls before
conversion. HTML metadata is part of effective rendering inputs.

Validate generated and cached PDF bytes. Decorations must contain one page and
match body geometry and rotation. Parse fresh pages for each assembly. Never
cache mutable CombinePDF objects or publish incomplete documents.

Use only cache `read` and `write` operations. Keep page and total pages in
decoration keys. Completed keys include explicit callback freshness and asset
dependencies. Keep authorization and data snapshot ownership in the caller.
Store exceptions propagate. Strict mode rejects false or nil writes.

## Verification

```sh
bundle exec rake test
bundle exec standardrb
```

Run core loading checks without Rails. Run Rails compatibility bundles
separately. Browser proof requires actual browser conversion, bounded timeouts,
and cleanup of only owned processes. Do not describe skipped browser tests as
passing browser evidence.

- Use frozen locks for verification. Report an incompatible development lock
  separately from the gem's Ruby requirement; do not silently re-resolve it.
- CI targets Ruby 3.2, 3.3, 3.4, 4.0 and latest stable. Keep database-free Rails
  7.2/Ruby 3.2 and Rails 8.1/Ruby 3.3 checks separate from the core bundle.
- The planned generic browser gate is `PARADEM_PDF_BROWSER=1 bundle exec rake
  test TEST='test/browser_test.rb'`. When enabled, missing prerequisites fail.
  Use platform fonts supplied by `PARADEM_PDF_TEST_FONT`, not application font
  files. Check actual multi-page portrait/landscape output, changing totals,
  embedded fonts, and header/body/footer positions with Poppler tools.
- Browser fixtures must reject security-bypass flags. Bound launch, navigation,
  conversion, worker lifetime, and owned-process close/reaping. Forced or failed
  cleanup is a failed proof, even if PDF bytes were produced. Do not signal
  unrelated browser processes or assume a PID is a process group.
- Keep PDFs, temporary font copies, observer records, node_modules, and browser
  caches out of the gem package. Generic test assets do not become app assets.

## Parallel work

Use subagents for independent work when possible. Give each worker explicit
file ownership and interfaces. Do not let workers edit the same file in
parallel. Serialize shared integration, browser verification, and commits.
Workers must not spawn additional subagents unless explicitly requested.

## Commits

The story id is `1`.

- Subjects use `[1] <type>: <description>`.
- Explain why the change is needed in the commit body.
- Commit documentation before the related implementation and test changes.
- Commit only when the complete currently applicable suite is green.
- Stage explicit paths for files actually worked on. Never use blanket staging.
- Group related changes. Prefer a moderate number of reviewable commits rather
  than one commit per test or file.
- Preserve unrelated user work. Never reset it or delete source branches.

## License and distribution

Management owns the license decision. Do not commit an MIT license or any other
license declaration until approved. Do not publish, push, or deploy without
separate authorization. Do not invent a repository URL or approved source rights.
