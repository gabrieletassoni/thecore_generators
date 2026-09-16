## 3.4.0

- Add `rails thecore:check_practices` (thecore_generators#13), a Ruby port of
  `thecore_code_extension`'s `checkPractices.js` scoped to the Scaffold Files and Models
  checks (the Actions check and `--fix` land in thecore_generators#14):
  - **Scaffold Files** — validates `config/initializers/after_initialize.rb`/`assets.rb`
    exist and carry their structural marker, in **both** ATOM and host-app context (the JS
    original only ever ran this check in ATOM context).
  - **Models** — rescoped per ADR 0001: a model with no `Api::`/`RailsAdmin::` concern is the
    correct default and is never flagged; only an orphan `include` (pointing at a missing
    concern file) or a concern file present but missing a required marker is a violation.
  - Default output is human-readable text grouped by file; `--json` emits
    `{ "violations": [{ "file", "line", "message", "severity", "fixable", "code" }] }`.
    Scans the host app plus every ATOM under `vendor/submodules/` by default;
    `-- --atom=NAME` scopes to one. Exits non-zero whenever a violation is found.
  - CLI flags are passed after a literal `--` (the standard Rake convention for passing
    arguments through to a task), e.g. `rails thecore:check_practices -- --json --atom=foo`.
  - `ThecoreGenerators::Railtie` now also registers a `rake_tasks` block so the task is
    available automatically to any app depending on this gem.
- Add `Thecore::Generators::WorkspaceContext.all_atom_dirs(app_root)`, enumerating every valid
  ATOM directory under `vendor/submodules/` — used by `check_practices`'s default (no
  `--atom`) scan.
- See [thecore_generators#13](https://github.com/gabrieletassoni/thecore_generators/issues/13).

## 3.3.0

- Add `rails generate thecore:root_action NAME` (`Thecore::Generators::RootActionGenerator`),
  a Ruby port of `thecore_code_extension`'s `addRootAction.js`: produces the RailsAdmin root
  action file, its view/JS/SCSS companions, the `config/initializers/after_initialize.rb`
  require line, the `config/initializers/assets.rb` precompile line, and locale entries — from
  a terminal, with the same ATOM-aware placement (`Thecore::Generators::AtomAware`,
  `--atom=NAME`) the Model/Migration generators already use. In ATOM context the action file
  lands in `lib/root_actions/`; in host-app context it lands in `config/root_actions/` with a
  full-path `require` (Zeitwerk autoload safety — main-app actions are never on the load path).
  Discovered automatically via Rails' own namespace-by-path convention, no Railtie registration
  needed.
- Add `Thecore::Generators::CompanionFiles`, a reusable module (ensuring
  `after_initialize.rb`/`assets.rb` exist and carry the right require/precompile line
  idempotently, rendering the shared view/JS/SCSS companion trio, and writing RailsAdmin action
  locale entries) that the upcoming Member Action generator and `check_practices --fix` will
  build on too.
- Broadens the original JS's locale-entry behavior: the action's `admin.actions.<name>`
  entry is written into **every** `*.yml` file already present under `config/locales`, not
  just `en.yml`/`it.yml` — those two are only created as a fallback when the directory has no
  locale file yet.
- See [thecore_generators#11](https://github.com/gabrieletassoni/thecore_generators/issues/11).

## 3.2.0

- Migration-driven inverse-association wiring (ADR 0003 in the thecore repo):
  `Thecore::Generators::MigrationGenerator` and `ModelGenerator` now detect
  `references`/`add_reference` attributes on the migration being generated and
  write the missing inverse `has_many`/`has_one` side into the *target*
  model's canonical per-model concern — `config/initializers/concern_<target_model>.rb`
  (module `Concern<TargetModel>`) plus a `TargetModel.send(:include,
  ConcernTargetModel)` line registered in `config/initializers/after_initialize.rb`,
  following the cross-ATOM extension pattern `GUIDE.md §4.5` already documents.
- Interactively (a real TTY), prompts for the inverse association's
  cardinality via Thor's own `ask`/`limited_to:` (`has_many` default,
  `has_one`, or `skip`). Non-interactively — no TTY, or the new
  `--non-interactive` class option, for CI/scripted/extension invocations —
  defaults straight to `has_many` with no prompt.
- Idempotent: re-running the generator against the same target model does not
  duplicate an already-present association line or `after_initialize`
  registration; a second, later migration adding a *different* reference to
  the same target model appends into the same existing concern file.
- Cross-boundary case: when the target model lives in a different ATOM/app
  than the invoking one (resolved via a new `WorkspaceContext.model_root_for`
  helper), the concern and `after_initialize` registration are still written
  automatically into the *invoking* app/ATOM (never the target's own, per
  ADR 0003) — only the required gemspec/Gemfile dependency line is logged to
  the generator's own output; no dependency manifest is ever edited
  automatically.
- The generated concern file always carries a header comment identifying it
  as generator-maintained.
- See [thecore_generators#5](https://github.com/gabrieletassoni/thecore_generators/issues/5).`rails generate model Foo name:string` no longer generates `Api::ModelName`/
  `RailsAdmin::ModelName` concern files by default (ADR 0001 in the thecore repo) — the
  no-customization case now relies entirely on the default `json_attrs`/`navigation_label`/
  `navigation_icon` behavior that `model_driven_api`/`thecore_ui_rails_admin` `include` into
  every `ApplicationRecord` subclass automatically
  (`ThecoreBackendCommons::DefaultModuleRegistry`, gabrieletassoni/model_driven_api#5,
  gabrieletassoni/thecore_ui_rails_admin#7).
- Add `--with-api-concern`/`--with-admin-concern` class options to scaffold a starter
  concern file — identical in shape to what the generator produced before this release —
  for the case where customization is already known to be needed at generation time.
- Document adding a concern by hand after the fact in the README (the common case).
- `test/dummy` now boots real `model_driven_api`/`thecore_ui_rails_admin` (temporary
  git-based test dependencies, see the Gemfile) so
  `test/generators/thecore/model_generator_default_concern_behavior_test.rb` can prove,
  at runtime, that a model generated with no concern file still works — not just that no
  file was written.
- See [thecore_generators#4](https://github.com/gabrieletassoni/thecore_generators/issues/4).

## 3.1.0

- Register `config.app_generators.orm :thecore, migration: true, timestamps: true` in
  `ThecoreGenerators::Railtie`, so plain `rails generate model`/`rails generate migration`
  now resolve to `Thecore::Generators::ModelGenerator`/`MigrationGenerator` (namespaces
  `thecore:model`/`thecore:migration`) instead of ActiveRecord's own generators, with no
  new command vocabulary. Both wrap (not reimplement) `ActiveRecord::Generators::ModelGenerator`/
  `MigrationGenerator` — `rails generate active_record:model`/`active_record:migration`
  remain available directly as an escape hatch.
- Add `Thecore::Generators::WorkspaceContext`, a Ruby port of
  `thecore_code_extension`'s `workspaceContext.js` gemspec-presence-under-`vendor/submodules/`
  detection, reading `Dir.pwd` instead of a right-clicked VS Code folder. Both generators use
  it (via the shared `Thecore::Generators::AtomAware` module) to redirect model/migration
  placement into an ATOM's `app/models`/`db/migrate` when one is detected, with an explicit
  `--atom=NAME` class option as an override that works independent of `cwd`.
- `Api::ModelName`/`RailsAdmin::ModelName` concern files are generated and `include`d into
  the model exactly as `thecore_code_extension`'s `addModel.js` templates do today
  (unchanged by this release — see thecore_generators#3 / ADR 0001 in the thecore repo).
  `Endpoints::ModelName` is no longer generated by default (ADR 0001: add it by hand,
  following the `after_initialize` + `class_eval` pattern, only when a real custom action
  is needed).
- Test file generation is no longer suppressed — no more `--skip-test-framework`
  equivalent: `rails generate model Foo` now generates a real Minitest file, matching
  Rails' own `active_record:model` default, placed alongside the model (inside the ATOM,
  when one is detected).
- See [thecore_generators#3](https://github.com/gabrieletassoni/thecore_generators/issues/3).

## 3.0.0

- Bootstrap the gem: gemspec, Gemfile, Rakefile, `ThecoreGenerators::Railtie` (no-op), a
  `Rails::Generators::TestCase`-based test harness exercised against a placeholder
  generator, CI, and a tag-triggered RubyGems publish workflow. No generator behaviour
  yet — see [thecore_generators#2](https://github.com/gabrieletassoni/thecore_generators/issues/2).
