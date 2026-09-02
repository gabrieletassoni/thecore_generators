# CLAUDE.md — thecore_generators

Rails-native generators for Thecore 3 apps and ATOMs. This gem replaces scaffolding logic that
used to live only in the [Thecore VS Code extension](https://github.com/gabrieletassoni/thecore_code_extension)
(`addModel.js`/`addMigration.js`) by hooking Rails' own `rails generate model`/`rails generate
migration` commands directly, so the exact same Thecore conventions apply regardless of whether
a developer types the command in a terminal or triggers it from the extension. See
[ADR 0002](https://github.com/gabrieletassoni/thecore/blob/release/3/docs/adr/0002-thecore-generators-gem-and-generator-hook-mechanism.md)
in the `thecore` repo for the full design rationale, and
[ADR 0001](https://github.com/gabrieletassoni/thecore/blob/release/3/docs/adr/0001-application-record-defaults-over-generated-concerns.md)/
[ADR 0003](https://github.com/gabrieletassoni/thecore/blob/release/3/docs/adr/0003-migration-driven-inverse-association-wiring.md)
for the two ADRs this gem's own feature set implements.

## Why a generator *hook*, not a new command

Rails already lets an ORM register itself as the target of `rails generate model`/`migration`
via `config.app_generators.orm :name, ...` — ActiveRecord does this for itself, and Mongoid does
the same for its own ORM. `ThecoreGenerators::Railtie` (`lib/thecore_generators/railtie.rb`)
does the identical thing:

```ruby
class Railtie < ::Rails::Railtie
  config.app_generators.orm :thecore, migration: true, timestamps: true
end
```

This is registered **at the class body level**, not inside an `initializer` block — deliberately
mirroring `active_record/railtie.rb`'s own placement. `config.app_generators` is a process-wide
singleton (`Rails::Railtie::Configuration#app_generators`) copied into `Rails::Generators.options`
early during boot; only running this at *require* time reliably wins by require order the same
way ActiveRecord's own registration does. Plain `rails generate model`/`rails generate migration`
therefore resolve to `Thecore::Generators::ModelGenerator`/`MigrationGenerator` (namespaces
`thecore:model`/`thecore:migration`, derived from module nesting the same way
`ActiveRecord::Generators::ModelGenerator` resolves to `active_record:model`) — **no new command
vocabulary** for developers to learn. `rails generate active_record:model`/`active_record:migration`
remain directly callable as an escape hatch; Rails only hides the overridden generator from
`--help`, it never blocks direct namespace invocation.

Both generator classes **wrap, not reimplement**, ActiveRecord's own: they inherit from
`ActiveRecord::Generators::ModelGenerator`/`MigrationGenerator`, so all attribute parsing,
migration-content templates, and model/module templates are inherited as-is. Everything below is
additive behavior layered with `super` calls, not a fork.

## Architecture

### `Thecore::Generators::WorkspaceContext` (`lib/generators/thecore/workspace_context.rb`)

A Ruby port of `thecore_code_extension`'s `libs/workspaceContext.js` — specifically its
`atomRootOf`/`hasGemspec` gemspec-presence-under-`vendor/submodules/` detection. The extension
resolved workspace context from a right-clicked VS Code folder; a terminal invocation has no
such folder, so this module resolves it from the invoking process's `Dir.pwd` instead.

- **`atom_root_of(dir)`** — walks up from `dir` until the immediate parent directory is
  `vendor/submodules`; that child is the ATOM root. Returns `nil` if `dir` isn't inside a
  `vendor/submodules/<atom>/` tree at all.
- **`gemspec_path_for(atom_dir)`/`valid_atom_dir?`** — an ATOM directory is valid only if it
  contains `<dirname>.gemspec` or the dash-to-underscore variant (gem names can't contain
  dashes) — ported from `hasGemspec`.
- **`atom_dir_for(cwd:, app_root:, atom_name: nil)`** — the single entry point generators call.
  When `atom_name` (a `--atom=NAME` option) is present, it resolves
  `<app_root>/vendor/submodules/<atom_name>` directly, **skipping `cwd`-based detection
  entirely** — this is what lets `--atom=NAME` work "from anywhere", independent of `cwd`.
  Otherwise it falls back to `cwd`-based `atom_root_of` detection. Raises `Thor::Error` (not a
  silent nil) when an explicit `--atom=NAME` doesn't resolve to a valid ATOM, or when `cwd`
  lands inside `vendor/submodules/` but the directory has no gemspec.
- **`model_root_for(class_name:, app_root:)`** — a different lookup, used only by
  `AssociationWiring` (below): given a model's class name, finds which app/ATOM its
  `app/models/<name>.rb` file actually lives under (host app's own `app/models` first, then each
  valid ATOM under `vendor/submodules/`, alphabetically). Returns the absolute app/ATOM root, or
  `nil` if the model doesn't exist anywhere yet — callers treat "not found" as "assume same
  app/ATOM" (best-effort, not a hard requirement).

**The `Dir.pwd`-reset gotcha** (why `--atom=NAME` exists at all, not just cwd-detection): a
generator process's own `Dir.pwd` is **not** reliable to lean on when the invoker is anything
other than a real interactive terminal already `cd`'d into the right place. Plain `rails` (as
opposed to a host app's `bin/rails` invoked by an explicit path) is `railties`' `exe/rails`,
which — via `Rails::AppLoader.exec_app` — walks *up* the directory tree from `Dir.pwd` looking
for `bin/rails`, `Dir.chdir("..")`-ing at every step, and only then `exec`s it. By the time the
actual generator code runs, `Dir.pwd` has already been reset to the host app root, not wherever
the calling process (e.g. a VS Code extension spawning a child process with an explicit `cwd`)
originally set it. `--atom=NAME` exists precisely so a caller that already knows which ATOM it
means (the VS Code extension always does — it resolved the target folder itself) can bypass
`Dir.pwd`-based detection entirely rather than fighting this reset. See
`thecore_code_extension`'s own `CLAUDE.md` (`addModel`/`addMigration` section) for the concrete
consumer-side walkthrough of this exact failure mode.

### `Thecore::Generators::AtomAware` (`lib/generators/thecore/atom_aware.rb`)

Shared by both `ModelGenerator` and `MigrationGenerator` (`include`d into each). Adds the
`--atom=NAME` class option and redirects file placement into the detected/named ATOM, or leaves
Rails' own default placement (relative to `destination_root`, already the host app root for a
real `rails generate` invocation) untouched when no ATOM applies.

Two distinct placement mechanisms need separate handling, since ActiveRecord's own generators
don't derive both from `destination_root`:

- **Model/module/test files** are `template`d at paths relative to `destination_root` —
  overriding `destination_root` itself, in `initialize`, redirects all of these (including the
  file `hook_for :test_framework` generates, since Thor's `_shared_configuration` passes the
  already-overridden `destination_root` on to hooked generators automatically).
- **The migration file's directory** instead comes from
  `ActiveRecord::Generators::Migration#db_migrate_path`, computed from
  `Rails.application.config.paths["db/migrate"]` — always the real app root, regardless of
  `destination_root`. `AtomAware` overrides `db_migrate_path` separately to redirect it too.

`host_app_root` is captured *before* `destination_root` is (possibly) overridden — it's the
stable anchor `WorkspaceContext.model_root_for` searches from, and the correct app-root anchor
for resolving an explicit `--atom=NAME` in the first place (which must be resolved against the
*pre-override* root, not the ATOM dir currently being computed).

### `Thecore::Generators::ModelGenerator`/`MigrationGenerator`

Resolved automatically once the Railtie registers the `:thecore` ORM (see above). Both:

- `include Thecore::Generators::AtomAware` and `Thecore::Generators::AssociationWiring`.
- Override `create_model_file`/`create_migration_file` respectively, always calling `super`
  first, then their own additive behavior — the same "wrap, don't reimplement" contract as
  the rest of the gem.
- Set `source_root`/`source_paths` explicitly to `ActiveRecord::Generators::ModelGenerator`'s/
  `MigrationGenerator`'s own template directory: `Rails::Generators::Base`'s auto-computed
  `default_source_root` derives its path from *this* class's own `base_name`/`generator_name`
  (`"thecore"`/`"model"` or `"migration"`), which doesn't exist on disk, so it would silently
  resolve to `nil` without this override. `ModelGenerator` additionally unshifts its own
  `templates/` directory (holding `api_concern.rb.tt`/`rails_admin_concern.rb.tt`) onto
  `source_paths` (plural — `source_root` only holds one path).
- `MigrationGenerator` needs `AssociationWiring` too, not just `ModelGenerator` — because
  `rails generate model Foo x:references` creates its migration via
  `ActiveRecord::Generators::ModelGenerator#create_migration_file`, a *different* method than
  `MigrationGenerator`'s own `create_migration_file`, so both host classes need their own hook
  into it (both wire it the same override-then-super-then-call pattern).

### Concern elimination + opt-in flags (ADR 0001)

Per [ADR 0001](https://github.com/gabrieletassoni/thecore/blob/release/3/docs/adr/0001-application-record-defaults-over-generated-concerns.md),
`Api::ModelName`/`RailsAdmin::ModelName` concern files are **no longer generated by default** —
the no-customization case now relies entirely on the default `json_attrs`/`navigation_label`/
`navigation_icon` behavior that `model_driven_api` and `thecore_ui_rails_admin` `include` into
every `ApplicationRecord` subclass automatically via
`ThecoreBackendCommons::DefaultModuleRegistry` (see those gems' own `CLAUDE.md`s). `Endpoints::ModelName`
was never generated by default in the first place and stays that way — add one by hand, following
the `after_initialize` + `class_eval` pattern, only when a real custom action is needed.

`ModelGenerator` adds two `class_option`s, both `false` by default:

```bash
rails generate model Foo name:string --with-api-concern --with-admin-concern
```

- `--with-api-concern` — scaffolds `app/models/concerns/api/foo.rb` (from
  `templates/api_concern.rb.tt`) and inserts `include Api::Foo` into the model's class body via
  `insert_into_file` (matched against `after: /class Foo < .*\n/`).
- `--with-admin-concern` — same for `app/models/concerns/rails_admin/foo.rb`/`RailsAdmin::Foo`.

These templates are a **faithful Ruby port** of `addModel.js`'s previous `api_concern.rb`/
`rails_admin_concern.rb` templates and model-file-rewrite behavior — down to the exact generated
content — kept available for the case where customization is already known to be needed *at
generation time*. The more common case — realizing customization is needed *after* the model
already exists — is to add the concern file by hand directly; see the README's "Adding a concern
by hand" section for the exact snippet (it composes correctly with the default module via
`ModelDrivenApi.smart_merge`/RailsAdmin's last-write-wins setters, since the default always
applies first via `ApplicationRecord.inherited` and the class body's own `include` always runs
after).

Test file generation is **never suppressed** — no `--skip-test-framework` equivalent exists;
`hook_for :test_framework` runs exactly as it does for `active_record:model`.

### `Thecore::Generators::AssociationWiring` (`lib/generators/thecore/association_wiring.rb`, ADR 0003)

Rails' own migration generator only ever wires the *owning* (`belongs_to`) side of a
`references`/`add_reference` column — the inverse `has_many`/`has_one` side has always been
manual. This module detects `references` attributes on the migration being generated and writes
the missing inverse side into the *target* model's canonical per-model concern, following the
cross-ATOM extension pattern GUIDE.md §4.5 already documents
(`config/initializers/concern_<model>.rb` + a `TargetModel.send(:include, ...)` line registered
in `config/initializers/after_initialize.rb`).

`include`d by both `MigrationGenerator` (standalone `rails generate migration ... x:references`)
and `ModelGenerator` (`rails generate model Foo x:references`) — see above for why both need
their own hook into it. Entry point: `wire_inverse_associations_from_references`, called after
`super` from each host's `create_migration_file` override. No-ops early when `--no-migration` was
passed (`ModelGenerator`'s own option), when there are no `attributes` at all, when `table_name`
is blank, or when none of the attributes are `reference?`.

For each `references` attribute found:

1. **Cardinality prompt** (`prompt_cardinality_for`) — with a real TTY (both `$stdin.tty?` and
   `$stdout.tty?`) and no `--non-interactive` flag, asks via Thor's own `ask`/`limited_to:`:
   `"Inverse association on <TargetModel> for this reference (has_many/has_one/skip)?"`,
   defaulting to `has_many`. **Non-interactively** — no real TTY (CI, the VS Code extension's
   shelled-out invocation, any scripted call) or `--non-interactive` explicitly passed —
   defaults straight to `has_many` with no prompt at all; a `skip` answer (interactive only)
   writes nothing.
2. **Association line** — `has_many :<owning_table_name>` or
   `has_one :<owning_table_name.singularize>`.
3. **Write the target concern** (`write_target_concern`) — `config/initializers/concern_<target_model>.rb`,
   module `Concern<TargetModel>`. If the file doesn't exist yet, it's created with a
   **generator-maintained header comment** (`HEADER_COMMENT`) explicitly warning "Do not
   hand-edit the generated section: a future generator run may append to it again, and hand
   edits are not accounted for" — plus an `extend ActiveSupport::Concern` / `included do ... end`
   skeleton. If it already exists, the association line is inserted right after
   `included do\n` via regex match, **idempotently**: `insert_association_into_existing_concern`
   first checks whether that exact line (anchored, whitespace-tolerant) is already present and
   `say_status :skip` instead of duplicating it. A second, later migration adding a *different*
   reference to the *same* target model appends into the same existing concern file rather than
   creating a second one.
4. **Register the `after_initialize` include** (`register_after_initialize`) —
   `config/initializers/after_initialize.rb` is created from a fixed
   `Rails.application.configure do config.after_initialize do end end` template if it doesn't
   exist yet, and `TargetModel.send(:include, ConcernTargetModel)` is inserted inside the
   `config.after_initialize do\n` block — again idempotently (skipped if that exact registration
   line is already present).
5. **Cross-boundary logging** (`log_cross_boundary_dependency`) — per ADR 0003, the generated
   concern **always** lives in the *invoking* app/ATOM (`destination_root`), never the target
   model's own, even when the target model actually lives elsewhere. This matters because the
   generated `TargetModel.send(:include, ...)` line then depends on that model's constant being
   loaded, which requires a real gem/path dependency a human has to add — this module never
   edits a gemspec/Gemfile itself, it only **logs** (`say_status :dependency`, yellow) a concrete
   hint: `spec.add_dependency "<gem>"` when both sides are ATOMs, a `path:` Gemfile line when the
   invoking side is the host app and the target is an ATOM, or a "confirm this is intentional"
   note when the target lives in the host app but the invoker is an ATOM (no manifest line
   applies there). Resolved via `WorkspaceContext.model_root_for` — compared against
   `destination_root`/`host_app_root` to decide which of the two "sides" is host-app vs. ATOM.

`--non-interactive` (`class_option`, default `false`) is declared once, in `AssociationWiring.included`,
so it's available on both host generator classes automatically.

## Key invariants and gotchas

- **Never reimplement ActiveRecord's own generator logic.** Every override in this gem calls
  `super` first (or last, for placement-only overrides like `db_migrate_path`) and adds behavior
  on top — attribute parsing, template rendering, and migration-content generation are 100%
  inherited. If a change here requires touching attribute-parsing logic, that's a signal the
  design has drifted from the "hook, don't fork" principle in ADR 0002.
- **`Dir.pwd` cannot be trusted for ATOM detection from a spawned child process** — see
  `WorkspaceContext`'s section above. Any new caller that shells out to `rails generate` from
  another process (CI, an editor extension, a rake task) must pass `--atom=NAME` explicitly
  rather than relying on cwd-based detection.
- **`AssociationWiring`'s prompt must never run without a real TTY behind it** — a caller with
  no TTY (CI, a shelled-out extension command) that forgets `--non-interactive` doesn't hang
  forever thanks to the `$stdin.tty? && $stdout.tty?` guard in `interactive_association_prompt?`,
  but relying on that guard instead of passing `--non-interactive` explicitly is fragile; always
  pass it from a non-interactive caller.
- **The generated per-model concern files are marked generator-maintained** (`HEADER_COMMENT`) —
  never hand-edit the section below that comment; a future generator run may append into it
  again and won't account for manual edits.
- **`--with-api-concern`/`--with-admin-concern` produce byte-identical output to the pre-ADR-0001
  `addModel.js` templates** — if the shape of a freshly-generated concern ever needs to change,
  update `lib/generators/thecore/model/templates/*.tt` here (the templates are now the single
  source of truth; `thecore_code_extension` no longer renders its own).
- **Test-only Gemfile entries are not wrapped in `group :test do end`** (see the Gemfile's own
  comment) — `test/dummy/config/application.rb` preloads a `User`/`Ability` needing Devise/CanCan
  at *require* time, and `rails/tasks/engine.rake` (loaded by this gem's own Rakefile) requires
  `test/dummy/config/application.rb` without `RAILS_ENV=test` set, so `Bundler.require(*Rails.groups)`
  would resolve to `"development"` at that point and skip anything scoped to `:test` — breaking
  `rake` itself before any test file runs.

## Test infrastructure

Tests use a `Rails::Generators::TestCase`-based harness against the `test/dummy` Rails app
included in this repo (needed to exercise generators the way a real host app would — file
placement, migration paths, etc.).

```bash
bundle install
env -u DATABASE_URL bundle exec rake test   # unset DATABASE_URL if it points at Postgres
bundle exec ruby -Itest test/generators/thecore/model_generator_test.rb   # single file
```

Key test files:

- `test/generators/thecore/workspace_context_test.rb` — ATOM detection edge cases.
- `test/generators/thecore/model_generator_test.rb` / `migration_generator_test.rb` — placement,
  ATOM redirection, `--atom=NAME` override.
- `test/generators/thecore/model_generator_default_concern_behavior_test.rb` — proves,
  integration-level (not just "no file was written"), that a model generated with **no**
  `Api::`/`RailsAdmin::` concern still gets a working default `json_attrs`/`navigation_label`
  at runtime. This is why `test/dummy` boots real `model_driven_api` (`~> 3.9`) and
  `thecore_ui_rails_admin` (`~> 3.8`) in the Gemfile — both resolved normally from RubyGems (no
  pin needed; both gems, and their own `thecore_backend_commons` dependency, are published with
  the `DefaultModuleRegistry` code this test exercises). None of this reaches
  `thecore_generators.gemspec`'s actual runtime dependency (`railties` only) — a host app
  installing this gem for real picks up none of it.
- `test/generators/thecore/association_wiring_test.rb` — interactive/non-interactive cardinality
  prompt, idempotent re-runs, cross-boundary logging, header-comment presence. Builds generator
  instances directly (`Thecore::Generators::MigrationGenerator.new`/`ModelGenerator.new`) rather
  than using `run_generator`, since it exercises both host classes' independent
  `create_migration_file` overrides in the same file.
- Pin note: `minitest` is pinned to `~> 5.25` — Rails 7.2's `rails/test_unit/line_filtering.rb`
  overrides `Minitest::Test.run` with a 2-arg signature that Minitest 6.x's 3-arg arity breaks;
  an unconstrained `minitest` resolves to 6.x on a fresh `bundle install` (no committed
  `Gemfile.lock`) and fails every test run before a single test executes. Safe to drop once this
  gem moves to a Rails version with Minitest 6 support (tracked for release/4).

## Releasing

Version lives in `lib/thecore_generators/version.rb` (currently `3.2.0`). Pushing a commit that
bumps it triggers `.github/workflows/gempush.yml`, which tags the commit with that version and
publishes to RubyGems (skipped if the tag already exists) — same pattern as the other gems in
this ecosystem.

## Who consumes this gem

- **This backend app's own `Gemfile`** — `gem 'thecore_generators', '~> 3.2'` in the
  `:development` group, so `rails generate model`/`migration` inside this app (and its ATOMs)
  are Thecore-aware without any extra setup.
- **The Thecore VS Code extension** (`thecore_code_extension`) — `addModel.js`/`addMigration.js`
  are now thin wrappers that shell out to `bundle install && rails g model|migration ... [--atom=NAME]
  --non-interactive` and trust this gem's generator hook for all placement/content decisions
  (ATOM-vs-host-app placement, no more always-generated concern trio, real test file generation,
  inverse-association wiring) instead of doing any of that themselves — no template rendering,
  no stdout-scraping, no `fs.renameSync` relocation, no patching `include Api::X` lines into the
  model file on the extension side anymore. See that repo's `CLAUDE.md`
  ("`addModel` / `addMigration` — thin wrappers over `thecore_generators`") for the extension-side
  detail, including exactly why it always passes `--non-interactive` (no real TTY behind a
  shelled-out child process) and `--atom=<name>` explicitly (the `Dir.pwd`-reset gotcha
  documented above) rather than relying on this gem's own cwd-based detection.

  Because both commands now trust `rails generate` completely, a host app whose `Gemfile` simply
  doesn't depend on this gem gets a **silent** regression from the extension's point of view:
  plain `rails g model`/`migration` still runs and exits `0`, but with none of the behavior this
  document describes, and no error surfaces anywhere. The extension guards against exactly that
  before collecting any model/migration input — `libs/thecoreGeneratorsGuard.js`'s
  `confirmAndAddThecoreGenerators` checks the host app's `Gemfile` for a `thecore_generators` gem
  line (tolerant of quoting/version-constraint/`group`-nesting), and on a miss prompts the
  developer to have it add `gem "thecore_generators", "~> 3.2"` to a `group :development do` block
  and run `bundle install` before proceeding (declining aborts the command instead of silently
  degrading). This lives entirely on the extension side — this gem has no awareness of it.
