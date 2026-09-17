## 3.10.0

- Add `rails generate thecore:atom NAME` (`Thecore::Generators::AtomGenerator`,
  thecore_generators#20, per ADR 0006 in the thecore repo) — a Ruby port of
  `thecore_code_extension`'s `createATOM.js`, producing a complete, working ATOM
  end-to-end from a terminal: no VS Code, no extension required. Wraps `rails plugin
  new --full` and layers on the same Scaffold Files/CI/Gemfile conventions
  `createATOM.js` already produces, with several deliberate corrections along the
  way: `model_driven_api`/`thecore_ui_rails_admin` (now an interactive `yes?`,
  default yes, not unconditional) are added at this gem's own ADR 0001 version floor
  (`~> 3.9`/`~> 3.8`), not the stale `~> 3.1`/`~> 3.2`; the generated `gempush.yml`'s
  two long-standing bugs are fixed (a broken `awk` pipeline; `version_exists`
  referenced in `if:` conditions but never actually set, meaning the tag/publish
  steps have never run); the gemspec's own `rails` dependency is no longer silently
  dropped when the two Thecore dependencies are added (the JS original's blind
  line-replacement did exactly that); and the new ATOM directory is `git init`'d
  with one local commit, with remote creation/`git submodule add` left as a logged,
  human-run follow-up rather than automated. Both GitHub Actions and GitLab CI files
  are always generated unconditionally — no hosting-profile prompt — since which git
  host a developer pushes to is a per-developer choice this ecosystem already treats
  as generic, not something worth gating behind interactivity. `CLAUDE.md` fetching
  from the thecore repo's own `samples/` is a separate follow-up
  (thecore_generators#22).
- Takes no `--atom=NAME` option, unlike every other generator in this gem — creating
  a *new* ATOM only ever makes sense from a host app's own root, so it doesn't
  include `Thecore::Generators::AtomAware` at all.
- `--non-interactive` plus matching `--summary=`/`--description=`/`--author=`/
  `--email=`/`--url=`/`--skip-api-admin-deps` flags, consistent with every other
  generator in this gem — aborts immediately, listing exactly which required flags
  are missing, rather than silently defaulting to placeholder text.
- See [thecore_generators#20](https://github.com/gabrieletassoni/thecore_generators/issues/20).

## 3.9.0

- Add `rails generate thecore:collection_action NAME` (`Thecore::Generators::CollectionActionGenerator`,
  thecore_generators#21, per ADR 0006 in the thecore repo) — the third sibling to
  `thecore:root_action`/`thecore:member_action`, structurally identical (same `AtomAware`/
  `CompanionFiles`/`ActionCompanion` includes, same thin task-method sequence, `action_kind
  "collection_action"`), needing no changes to any of the three shared modules. No prior
  `addCollectionAction.js` ever existed to port — its own `templates/action.rb.tt` mirrors
  `thecore:root_action`'s simplicity (`add_action "<name>", :base, :collection`, a minimal
  GET/JSON example with an `ActivityLogChannel` broadcast) rather than the more complex,
  hand-written `save_filters.rb`/`load_filters.rb` pattern already living in
  `thecore_ui_rails_admin`.
- `rails thecore:check_practices`'s `ACTION_GENERATOR_CLASSES` now includes
  `CollectionActionGenerator`, so a missing Collection Action companion (view/JS/SCSS) is
  `fixable: true` and `--fix` regenerates it via the new generator's own template rendering —
  closing the gap ADR 0004 tracked as deliberate ("no generator to have gotten it right").
- See [thecore_generators#21](https://github.com/gabrieletassoni/thecore_generators/issues/21).

## 3.8.0

- Extend the App application template (thecore_generators#18, ADR 0005 in the thecore
  repo) to fetch and write devcontainer/CI/CLAUDE.md assets from `thecore`'s own
  `samples/` directory — `.devcontainer/*` (overwriting whatever the "Setup
  Devcontainer" bootstrap step created), `.gitlab-ci.yml`, and `CLAUDE.md`. The base
  location is one overridable point (`ENV["THECORE_SAMPLES_SOURCE"]`), defaulting to
  the real raw GitHub URL for `thecore`'s `samples/` on `master` (its actual default
  branch, not `release/3` as originally written in the ticket). This is what completes
  the App template: a freshly generated app now matches the best-practice reference
  end-to-end, not just a working Rails/Gemfile base.

## 3.7.0

- Add the App application template core (`lib/templates/app_template.rb`,
  thecore_generators#17, ADR 0005 in the thecore repo) — a genuine Rails application
  template (`rails new -m`, not a `thecore:*` generator), porting `createApp.js`'s
  Gemfile/vendor-directory behavior. Adds the standard Gemfile stack (devise,
  cancancan, rails_admin, sassc-rails, `model_driven_api` ~> 3.9, `thecore_ui_rails_admin`
  ~> 3.8 — both bumped to match this gem's own ADR 0001 `DefaultModuleRegistry` floor —
  plus `thecore_generators` itself as a `:development` dependency), a commented,
  discoverable-but-optional block for the rest of the generic Thecore ecosystem gems, and
  empty `vendor/submodules/`/`vendor/external/` placeholder directories (developer
  convenience only, not template content — see ADR 0005). The standard installer chain
  (devise/rails_admin/active_storage/action_text/action_mailbox/cancan/erd) is gated
  behind a genuine interactive `yes?` prompt, wrapped in `after_bundle` so it only runs
  once the gems above are actually bundled, and fails fast (mirroring `createApp.js`'s
  own atomic `&&`-chained shell command) rather than silently limping on if a step fails.
  Devcontainer/CI/CLAUDE.md asset generation, fetched from the `thecore` repo's own
  `samples/`, is a separate follow-up (thecore_generators#18).

## 3.6.0

- Extend `rails thecore:check_practices` with the Actions check
  (thecore_generators#14, per ADR 0004): scans `root_actions`, `member_actions`, and
  `collection_actions` under both ATOM (`lib/`) and host-app (`config/`) context, with the
  same generic rules for all three — `collection_actions` is scanned even though no generator
  creates files there yet (a hand-written one could already exist and go unaudited otherwise).
  Reports: missing/broken action-file markers, missing companion view/JS/SCSS (or a companion
  present but missing its own marker), a missing `after_initialize.rb` require line, and a
  missing locale entry checked against **every** `*.yml` already present in the locales
  directory, not just `en`/`it`.
- Add `--fix` (`rails thecore:check_practices -- --fix`, combinable with `--json`/`--atom=NAME`):
  applies every fixable violation from this category in one pass, no confirmation of its own.
  Companion-file fixes regenerate only the *specific* missing file by delegating straight to
  `RootActionGenerator`'s/`MemberActionGenerator`'s own template rendering (never the bundled
  "render all three companions" step, which could otherwise hit a non-interactive file-collision
  hang/prompt against a hand-customized sibling file that already exists) — `collection_action`
  companions are never fixable, since no generator exists to delegate to. Require-line and
  locale-entry fixes are generic (work for all three kinds, via a small internal
  `GenericFixTarget` built on `CompanionFiles`). A file/marker that already exists but lost its
  marker is never fixable (regenerating over it could clobber real customization — same
  principle as the Model check). After a `--fix` pass, the task re-scans and reports/exits
  based on whatever violations remain, per ADR 0004.
- Exit code / `--json` schema / `--atom` scoping are unchanged and now cover this category too.
- Fix two `--fix` correctness issues found during review: a host-app violation's fix could be
  silently misrouted into an unrelated ATOM when the check_practices process's own `Dir.pwd`
  happened to sit inside `vendor/submodules/<atom>/` at fix time (`AtomAware#atom_dir` falls
  back to cwd-based detection for an unset `--atom`, not host-app placement — the freshly-built
  fix-target generator's `destination_root` is now force-set to the exact `root` the violation
  was found under); and a companion file shared by two action kinds with the same action name
  (the companion rel_path is kind-agnostic) could trip Thor's interactive file-collision prompt
  on the second fix, since the target file the first fix just created was no longer missing —
  the companion fix now re-checks `File.exist?` immediately before rendering. Also extracted the
  `after_initialize.rb` require-line format into `ActionCompanion.require_line_for`, reused by
  both the real generators and the Actions check, so the two can no longer drift apart.
- See [thecore_generators#14](https://github.com/gabrieletassoni/thecore_generators/issues/14).

## 3.5.0

- Add `rails generate thecore:member_action NAME` (`Thecore::Generators::MemberActionGenerator`,
  thecore_generators#12) — the Member Action counterpart to `thecore:root_action`, reusing
  `Thecore::Generators::CompanionFiles` exactly as Root Action does. Its own `action.rb.tt` is
  a faithful port of `addMemberAction.js`'s server-side template — RailsAdmin `:member` action
  type, `http_methods [:get, :patch]`, XHR GET (JSON) + form PATCH (redirect) instead of Root's
  single fetch/JSON + `ActionCable.server.broadcast` action — not unified with Root's. Its
  `action.js.tt`/`action.html.erb.tt` still set up the same `ActivityLogChannel` ActionCable
  subscription Root's do; only the test button's click handler (XHR vs. `fetch`) and the added
  `form_with(..., method: :patch)` differ. Placement: `lib/member_actions/` in ATOM context,
  `config/member_actions/` in host-app context (same `--atom=NAME` mechanism as every other
  generator in this gem).
- Extract `Thecore::Generators::ActionCompanion`, the shared skeleton
  `RootActionGenerator`/`MemberActionGenerator` both build on (name validation, placement,
  and the thin task-method sequence every Thor generator needs defined directly on the class
  itself — see its own comment for why methods can't just live in a mixed-in module here).
  `RootActionGenerator` is refactored onto it too, with no behavior change (its existing test
  suite is unchanged and still passes).
- See [thecore_generators#12](https://github.com/gabrieletassoni/thecore_generators/issues/12).

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
