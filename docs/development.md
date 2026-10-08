# Development

## Local checks

Use the committed lock. Do not silently re-resolve dependencies to make a
verification environment work.

```sh
BUNDLE_FROZEN=true bundle install
BUNDLE_FROZEN=true bundle exec rake test
BUNDLE_FROZEN=true bundle exec standardrb
gem build paradem_pdf.gemspec
```

Tests use Minitest. Runtime and packaging changes start with an observed failing
behavior test, then the smallest implementation, then the complete suite.
Human-facing prose is reviewed against code and tested examples rather than
assertions on its exact wording. See [AGENTS.md](../AGENTS.md) for repository
workflow and commit rules.

## Standalone core

The root [Gemfile](../Gemfile) does not depend on Rails. Run the full root suite
to check the core; optional Rails and real-browser cases report skips when not
enabled. [bootstrap_test.rb](../test/bootstrap_test.rb) checks that requiring
`paradem_pdf` does not load application constants.

For a focused standalone loading check:

```sh
BUNDLE_FROZEN=true bundle exec rake test TEST='test/bootstrap_test.rb'
```

Unit tests replace conversion at the native processor boundary. They do not
prove real browser output. The readiness JavaScript tests also need Node.js.

## Rails compatibility

Run the database-free adapters with each compatibility bundle under its
compatible Ruby. For example, when using mise:

```sh
mise exec ruby@3.2.9 -- env BUNDLE_FROZEN=true BUNDLE_GEMFILE=gemfiles/rails_7_2.gemfile bundle exec rake test
mise exec ruby@3.2.9 -- env BUNDLE_FROZEN=true BUNDLE_GEMFILE=gemfiles/rails_7_2.gemfile bundle exec standardrb
mise exec ruby@3.3.6 -- env BUNDLE_FROZEN=true BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bundle exec rake test
mise exec ruby@3.3.6 -- env BUNDLE_FROZEN=true BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bundle exec standardrb
```

Mise is an example Ruby selector, not a gem dependency. Use your installed Ruby
manager if different. Install missing bundles with `BUNDLE_FROZEN=true` and the
same `BUNDLE_GEMFILE` before running these commands.

The fixtures and subprocess setup are in
[rails_app.rb](../test/support/rails_app.rb), with adapter coverage in
[rails_test.rb](../test/rails_test.rb) and
[rails_renderer_test.rb](../test/rails_renderer_test.rb). These checks do not
cover every Rails/Ruby combination or an application's templates.

## CI and evidence

[test.yml](../.github/workflows/test.yml) is the source of truth for configured
CI jobs and version selections. It defines separate core, Rails compatibility,
and real-browser jobs. Configured jobs are not evidence that GitHub Actions has
executed successfully.

When reporting verification, record the commit, Ruby and dependency versions,
platform, command, failures, and skips. Separate the gem's Ruby requirement
from dependency limits and executed environments. Do not label skipped browser
tests as passing browser evidence. See [browser-check.md](browser-check.md).

## Package review and release

[paradem_pdf.gemspec](../paradem_pdf.gemspec) declares runtime dependencies,
license, and package files. Review the built archive as well as the source list.
Keep test PDFs, temporary fonts, observer records, `node_modules`, and browser
caches out of the package. Generic test assets are not application assets.

Commit reviewed documentation sections incrementally, before related packaging
implementation and tests. Subjects use `[<story-id>] <type>: <description>` and
bodies explain why. Stage explicit paths and preserve unrelated work.

MIT licensing does not authorize publishing, pushing, or deployment. Each needs
separate approval. Do not invent repository or release URLs. A documentation-only
release uses a patch version; the version is defined in
[version.rb](../lib/paradem_pdf/version.rb).
