# thecore_generators

Part of the [Thecore framework](https://github.com/gabrieletassoni/thecore/tree/release/3).

Rails-native generators for Thecore 3 apps and ATOMs — replacing the scaffolding logic
currently duplicated in the [Thecore VS Code extension](https://github.com/gabrieletassoni/thecore_code_extension).
Wherever Rails already has a native generator command to override (`rails generate
model`/`migration`), this gem hooks it instead of inventing new vocabulary; operations with
no Rails-native equivalent (ATOM creation, action scaffolding, app bootstrapping) get their
own `thecore:*`-namespaced generators or an application template. See
[`docs/adr/0002-thecore-generators-gem-and-generator-hook-mechanism.md`](https://github.com/gabrieletassoni/thecore/blob/release/3/docs/adr/0002-thecore-generators-gem-and-generator-hook-mechanism.md)
in the thecore repo for the full design.

**Status:** bootstrap only. This release makes the gem buildable, testable, and
publishable — it ships no generator behaviour yet. `ThecoreGenerators::Railtie`
(`lib/thecore_generators/railtie.rb`) is a deliberate no-op; the `config.app_generators.orm`
hook lands in a follow-up ticket.

## Installation

Add to your host app's or ATOM's `Gemfile`:

```ruby
gem "thecore_generators", "~> 3.0"
```

## Running tests locally

Tests use a `Rails::Generators::TestCase`-based harness against the `test/dummy` Rails
app included in this repo (needed to exercise generators the way a real host app would).

```bash
bundle install
bundle exec rake test
```

`bundle exec rake` alone runs the same suite (`test` is the default Rake task).

To run a single test file:

```bash
bundle exec ruby -Itest test/generators/placeholder_generator_test.rb
```

## Releasing

Version lives in `lib/thecore_generators/version.rb`. Pushing a commit that bumps it
triggers `.github/workflows/gempush.yml`, which tags the commit with that version and
publishes to RubyGems (skipped if the tag already exists) — the same pattern used by the
other gems in this ecosystem (`model_driven_api`, `thecore_backend_commons`, etc.).

## License

MIT — see [`MIT-LICENSE`](MIT-LICENSE).
