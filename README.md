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

**Status:** Model + Migration generator hook (Phase 1 of
[ADR 0002](https://github.com/gabrieletassoni/thecore/blob/release/3/docs/adr/0002-thecore-generators-gem-and-generator-hook-mechanism.md)).
`ThecoreGenerators::Railtie` registers `config.app_generators.orm :thecore, migration:
true, timestamps: true`, so plain `rails generate model`/`rails generate migration`
transparently apply thecore's scaffolding conventions — no new command vocabulary.

### What `rails generate model`/`rails generate migration` do now

- **Context-aware placement.** `Thecore::Generators::WorkspaceContext` detects whether
  the invoking process's `Dir.pwd` is inside a host app or an ATOM (`vendor/submodules/<atom>/`,
  by gemspec presence — a Ruby port of `thecore_code_extension`'s `workspaceContext.js`).
  When an ATOM is detected, the model/migration/test files land inside that ATOM's own
  `app/models`/`db/migrate`/`test` instead of the host app's. Pass `--atom=NAME` to
  override detection explicitly (works independent of `cwd`, e.g. from CI or the host-app
  root).
- **Default concerns, unchanged.** `Api::ModelName`/`RailsAdmin::ModelName` concern files
  are generated and `include`d into the model, exactly as `thecore_code_extension`'s
  `addModel.js` templates do today.
- **No `Endpoints::ModelName` by default** (per
  [ADR 0001](https://github.com/gabrieletassoni/thecore/blob/release/3/docs/adr/0001-application-record-defaults-over-generated-concerns.md)) —
  add one by hand, following the `after_initialize` + `class_eval` pattern, only when a
  real custom action is needed.
- **Test file generation is never suppressed** — a real Minitest file is generated, same
  as Rails' own `active_record:model` default.
- **`rails generate active_record:model`/`active_record:migration` still work directly**
  as an escape hatch, entirely unaffected by the hook above.

Both `Thecore::Generators::ModelGenerator` and `MigrationGenerator` wrap (not reimplement)
`ActiveRecord::Generators::ModelGenerator`/`MigrationGenerator` — all attribute parsing and
template content is inherited as-is; only file placement and the two default concerns are
added on top.

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
bundle exec ruby -Itest test/generators/thecore/model_generator_test.rb
```

## Releasing

Version lives in `lib/thecore_generators/version.rb`. Pushing a commit that bumps it
triggers `.github/workflows/gempush.yml`, which tags the commit with that version and
publishes to RubyGems (skipped if the tag already exists) — the same pattern used by the
other gems in this ecosystem (`model_driven_api`, `thecore_backend_commons`, etc.).

## License

MIT — see [`MIT-LICENSE`](MIT-LICENSE).
