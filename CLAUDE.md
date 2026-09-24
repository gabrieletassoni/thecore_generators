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
  A cwd-detected ATOM is only honored when it is `app_root` itself or lives inside it — an
  ATOM that merely *encloses* `app_root` (an ATOM's own `test/dummy`, or this gem's own test
  suite run from a checkout at `<host>/vendor/submodules/thecore_generators` with a tmp
  `destination_root` nested inside it) is ignored, otherwise every generated file would be
  redirected out of `destination_root` into that enclosing directory. For a real `rails
  generate` the app root is always an ancestor of cwd, so the normal outcome is unchanged.
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

### `Thecore::Generators::CompanionFiles` (`lib/generators/thecore/companion_files.rb`)

Shared by Thecore's own custom-action generators — introduced by `RootActionGenerator`
(thecore_generators#11), reused as-is by the upcoming `MemberActionGenerator`
(thecore_generators#12) and, later, by `check_practices --fix`. Faithful Ruby port of the
after_initialize.rb/assets.rb ensure-and-append logic and the locale-entry merge behavior
`addRootAction.js`/`addMemberAction.js` share in `thecore_code_extension`:

- `render_view_js_scss_companions!` — templates `action.html.erb.tt`/`action.js.tt`/
  `action.scss.tt` (must be present in the including generator's own `source_paths`) into the
  fixed `app/views/rails_admin/main`, `app/assets/javascripts/rails_admin/actions`,
  `app/assets/stylesheets/rails_admin/actions` paths — the same relative paths regardless of
  ATOM vs host-app context (only the action's own controller-config file is placed differently
  between root and member actions). Takes no argument: the template bodies read the including
  generator's own `file_name` (NamedBase) directly through the ERB binding `template`
  evaluates them in, so an `action_name` parameter here would only rename the destination files
  while the content kept using `file_name` — a silent name/content mismatch avoided by not
  offering the parameter at all.
- `ensure_after_initialize_require!(require_line)` / `ensure_assets_precompile_line!(precompile_line)` —
  create `config/initializers/after_initialize.rb`/`assets.rb` from a fixed skeleton if absent,
  then idempotently insert/append the given line (`say_status :skip` instead of duplicating on
  a re-run). Deliberately duplicates (does not share) `AssociationWiring::AFTER_INITIALIZE_TEMPLATE`
  below — same structure/anchor, so the two compose fine regardless of which one creates the
  file first, but kept independent to avoid touching already-shipped Phase 1 code for this
  ticket.
- `write_action_locale_entries!(key, title)` — writes an `admin.actions.<key>` entry
  (`menu`/`title`/`breadcrumb`, all set to `title`) into **every** `*.yml` file already present
  under `config/locales` (`en.yml`/`it.yml` are created first, and only then, when the directory
  has no locale file yet) — broader than `addRootAction.js`'s original behavior, which only ever
  touched `en.yml`/`it.yml`.

### `Thecore::Generators::ActionCompanion` (`lib/generators/thecore/action_companion.rb`)

Shared skeleton for `RootActionGenerator`, `MemberActionGenerator`, and
`CollectionActionGenerator` (below), holding
everything about them that is not the action file's own RailsAdmin action type/template
content: name validation (`/\A[a-z_][a-z0-9_]*\z/` — stricter than `addRootAction.js`'s/
`addMemberAction.js`'s own `/^[a-z0-9_]+$/`, since a leading digit would render as an invalid
Ruby symbol literal, `topic: :1action`, in the generated action file — raises `Thor::Error`),
`action_file_path`/`require_line` (the ATOM-vs-host-app placement split:
`lib/<kind>s/`/`config/<kind>s/`), `assets_precompile_line`, `action_name_camel_case`,
`title_case_name`.

`ActionCompanion.require_line_for(kind:, in_atom:, name:)` is a plain module method (not routed
through `ClassMethods`/`extend` the way `action_kind` is), so it's callable directly without an
including generator instance — `require_line` (the instance method above) delegates to it using
the generator's own `atom_dir`/`file_name`, and `Thecore::CheckPractices`' Actions check
(`check_action_require_line`) calls it directly with `kind`/`base_dir`/`action_name` derived
from whichever action file it's auditing. The two used to duplicate this string format
independently (one copy per module) until thecore_generators#14's own review caught it — a
single source of truth means the audit's expectation of what a require line looks like can
never drift out of sync with what `RootActionGenerator`/`MemberActionGenerator`/
`CollectionActionGenerator` actually write.

**Why the actual Thor task methods (`create_action_file`, `create_view_js_scss_companions`,
etc.) still live on each generator class directly, not in this module**: `Thor::Group` (which
`Rails::Generators::Base`/`NamedBase` extends) discovers its task list via a `method_added`
hook that fires only for methods defined *directly* in the class's own body — never for
methods a class merely picks up through `include`. Moving the task methods themselves into
`ActionCompanion` was tried and broke both generators silently (nothing got created, no error)
before this was understood — every task method must stay a thin, identically-worded one-liner
on each generator class, delegating into this module's private logic; only that private logic
(and the `action_kind "root_action"`/`"member_action"` class-body declaration each generator
makes, which derives the directory name and validation wording) is actually shared.

### `Thecore::Generators::RootActionGenerator` (`lib/generators/thecore/root_action/root_action_generator.rb`, ADR 0002 Phase 2)

`rails generate thecore:root_action NAME` — a Ruby port of `thecore_code_extension`'s
`addRootAction.js` (thecore_generators#11). Unlike `ModelGenerator`/`MigrationGenerator` there
is no built-in Rails generator being overridden, so it needs no `Railtie` registration — Rails'
own namespace-by-path convention (`generators/thecore/root_action/root_action_generator.rb` →
`thecore:root_action`) discovers it automatically the moment a command references that
namespace.

`include`s `AtomAware` (for `atom_dir`/`host_app_root`/`--atom=NAME` — but *not* for placement
of the action file itself: unlike Model/Migration's templates, the action file lives at a
*different* relative path per context, `lib/root_actions/` in an ATOM vs `config/root_actions/`
in the host app, mirroring `docs/adr/0001-main-app-actions-live-in-config.md` in
`thecore_code_extension` — Zeitwerk would eager-load a constant-less action file under `lib/`
in the host app), `CompanionFiles` (for everything placed at a fixed relative path regardless
of context), and `ActionCompanion` (everything else — see above). The action file's own
template (`templates/action.rb.tt`) is a byte-for-byte port of `addRootAction.js`'s
`action.rb` template — same `RailsAdmin::Config::Actions.add_action` body, fetch/JSON,
`ActionCable.server.broadcast` example. `templates/action.html.erb.tt` uses Rails' own
`<%%= %>`-escaping convention (a literal `<%%` in the `.tt` source renders as a literal `<%` in
the generated `.html.erb`) so the *generated file's own* ERB (`stylesheet_link_tag`,
`rails_admin.<name>_path`) survives generation-time rendering untouched.

### `Thecore::Generators::MemberActionGenerator` (`lib/generators/thecore/member_action/member_action_generator.rb`, ADR 0002 Phase 2)

`rails generate thecore:member_action NAME` — a Ruby port of `thecore_code_extension`'s
`addMemberAction.js` (thecore_generators#12). Structurally identical to `RootActionGenerator`
(same three `include`s, `action_kind "member_action"` instead of `"root_action"`, same thin
task methods verbatim) — only its own `templates/action.rb.tt`/`action.html.erb.tt`/
`action.js.tt` differ, a byte-for-byte port of `addMemberAction.js`'s own templates.
**`action.rb.tt`** is the real behavioral difference: RailsAdmin `:member` action type,
`http_methods [:get, :patch]`, controller branches on XHR GET (`request.xhr? &&
request.get?` → JSON) vs. form PATCH (`request.patch?` → redirect), instead of Root's single
`:root` action with a fetch/JSON + `ActionCable.server.broadcast` example. **`action.js.tt`**/
**`action.html.erb.tt`** still set up the same `ActivityLogChannel` ActionCable subscription
Root's do — only the test button's click handler (a plain XHR `GET` here vs. `fetch` there)
and the added `form_with(..., method: :patch)` in the view differ; don't read "not unified
with Root's" (CHANGELOG/README) as meaning the JS/view are wholesale different. The view also
needs a bare (no `=`) escaped ERB tag — `<%% end %>`, closing the escaped `<%%= form_with(...)
do |f| %>` block — proving the `<%%`-escaping convention (see Root Action above) isn't limited
to output (`<%%=`) tags.

### `Thecore::Generators::AtomGenerator` (`lib/generators/thecore/atom/atom_generator.rb`, thecore_generators#20, ADR 0006)

`rails generate thecore:atom NAME` — a Ruby port of `thecore_code_extension`'s `createATOM.js`.
Structurally unlike every other generator in this gem: it does **not** `include
Thecore::Generators::AtomAware` and declares no `--atom=NAME` option, since creating a *new* ATOM
only ever makes sense from a host app's own root — `destination_root` stays fixed at that root
for the entire generator run, and every path this class writes is expressed relative to it via
the private `atom_root` method (`"vendor/submodules/#{file_name}"`), rather than via
`AtomAware`'s `destination_root=` redirection trick.

**Two Gemfiles, one `#gem` action** — the host app's own (`destination_root/Gemfile`) and the
freshly-scaffolded ATOM's own (`vendor/submodules/<name>/Gemfile`) are both mutated, but only
the first can go through `Rails::Generators::Actions#gem` (used once, in
`add_gem_to_host_gemfile`): that method's own implementation always writes via `in_root { ... }`,
and `Thor::Actions#in_root` is hardcoded to `inside(@destination_stack.first) { yield }` — the
*original* destination_root, not whatever `inside` might currently have pushed onto the stack.
So `#gem` can never be redirected into a nested path no matter how it's wrapped. The ATOM's own
Gemfile is instead mutated via plain `append_to_file` calls against an explicit relative path
(`File.join(atom_root, "Gemfile")`) — no `inside` needed there at all, since `create_file`/
`template`/`append_to_file`/`gsub_file`/`empty_directory` all resolve their given path against
the *current* `destination_root` (`@destination_stack.last`, via the public `destination_root`
reader), which never moves in this generator.

**`inside("vendor/submodules") { run(...) }` is reserved for the two places that need a real,
OS-level `Dir.chdir`** — `create_rails_engine`'s `bundle exec rails plugin new` shell-out, and
`git_init_and_commit`'s `git init`/`git add`/`git commit` — since `Thor::Actions#run` shells out
via bare `system`/`Open3`, which only respects the process's actual cwd, not Thor's own
path-prefixing logic. `inside` does both: it pushes onto `@destination_stack` (redirecting
`destination_root` for the duration, irrelevant here since these blocks don't create files
directly) **and** does a real `FileUtils.cd`, which is the part that matters for `run`.

**Why `bundle exec rails plugin new`, not `createATOM.js`'s bare `rails plugin new`**: a
deliberate addition over the JS original, which shells a bare `rails` relying entirely on
whatever's globally on `PATH`. In the real host-app case this costs nothing — cwd already sits
under that app's own Gemfile either way (`vendor/submodules` is a subdirectory of the app;
`bundle exec`'s own upward Gemfile search, or the plain `rails` walk-up to `bin/rails`, both
land on the same place) — but it makes gem resolution explicit rather than incidental, and it's
what makes the generator's own test suite tractable at all (see below).

**Gemspec rewriting reads once, applies one in-memory pass of targeted substitutions, writes
once** — not `createATOM.js`'s own blind "rewrite every line, branch on substring" approach
(verified directly against a real `rails plugin new --full` gemspec, Rails 7.2.3.2, rather than
assumed from the JS original, which predates several Rails releases — the template has moved on
meaningfully: new `homepage_uri` line, different summary/description wording, a real `license`
line; a full-file line-by-line port would silently stop matching several fields), and not one
`gsub_file` call per field either (an early draft did this — 8 separate full read-modify-write
cycles against the same small gemspec file, caught in review as wasted I/O for no benefit; the
one-read/one-write shape now matches `setup_gemfile`'s own single-append design just below it).
One deliberate correctness fix along the way: the JS's `.add_dependency` branch *replaces* the
whole matched line, which happens to be `spec.add_dependency "rails", ...` in current Rails —
silently dropping the gem's own Rails dependency entirely whenever the two Thecore dependencies
are added. `setup_gemspec` appends its two lines right after that one instead of replacing it.

**Three guards catch real, observed collision hazards, all added during review after being
reproduced directly against this very host app's own `vendor/submodules/mytask`**:
- `validate_atom_name!` (the very first task method) restricts `NAME` to
  `/\A[a-z][a-z0-9_-]*\z/` — lowercase, starting with a letter, digits/underscore/hyphen only
  (matching real examples in this ecosystem, including the hyphenated
  `thecore-spot-overrides`). Without it, a space in `NAME` (the exact example text both
  `createATOM.js`'s and this generator's own prompts suggest, "TCP Debugger") word-splits the
  unescaped shell-out in `create_rails_engine` into two arguments, silently creating an engine
  named only the first word while every later step keeps operating on a path nothing actually
  created; a shell metacharacter (`; touch /tmp/pwned`) executes arbitrary commands; and a
  namespaced name (`acme/widget`) desyncs `atom_root` (which uses only `file_name`, `"widget"`)
  from `class_name` (`"Acme::Widget"`, used in the `abilities.rb` template), producing a
  `NameError: uninitialized constant Abilities::Acme` the moment the generated ATOM boots.
  `create_rails_engine` also `Shellwords.escape`s `file_name` regardless, as defense in depth.
- `ensure_atom_does_not_already_exist!` refuses a `NAME` whose `vendor/submodules/<name>`
  directory already exists. Without it, `rails plugin new`'s own `-f` (force) flag suppresses
  Thor's normal file-collision prompt entirely, so `rails generate thecore:atom mytask` in this
  very host app would silently overwrite the real, populated `mytask` submodule's Gemfile,
  gemspec, and `lib/mytask/engine.rb` with freshly-generated plugin-skeleton content.
- `add_gem_to_host_gemfile` checks the host Gemfile for an existing `gem "<name>"` line before
  appending a second one — the identical collision, one layer up: `mytask` is already declared
  there (`gem 'mytask', '~> 3.20'`, resolved from a gem server), and a blind append would leave
  two conflicting entries for the same gem name, which `bundle install`/`bundle exec` then
  refuses outright ("You cannot specify the same gem twice"). Kept as its own explicit check
  rather than relying solely on the `vendor/submodules` guard above, since a Gemfile entry and a
  `vendor/submodules` directory are two independent pieces of state that could in principle
  drift apart (e.g. a submodule removed by hand without touching the Gemfile).

**No `.gitignore` is written** (verified directly, not assumed: a fresh `rails plugin new --full`
output has no log/tmp/sqlite artifacts anywhere in the tree yet — nothing has been bundled or
run against the dummy app at the point the initial commit happens, so it's clean regardless).
`createATOM.js`'s own custom gitignore-fetch step is out of this ticket's scope entirely (and
was never revisited to reflect the mattpocock-skills-era `.claude`/`.bundle`/`.gem` mount
patterns the App template's own `samples/` assets now carry) — a candidate for a future ticket
if the growing dummy-app tree ever makes an unignored initial commit less clean than verified
here.

**`fetch_claude_md`** (thecore_generators#22) — completes this generator's scope by fetching
`thecore`'s own `samples/ATOM_CLAUDE.md` and writing it as the new ATOM's `CLAUDE.md`, via
`Thecore::Generators::SampleFetcher.fetch_thecore_sample` (`lib/generators/thecore/sample_fetcher.rb`)
— a shared module (same env var, `THECORE_SAMPLES_SOURCE`; same http(s)-vs-local-directory
branching via `get`/`File.read`, now trailing-slash-tolerant on the http(s) branch; same
`nil?`/`empty?` blank-safety, not bare `||`; same `force: true`; same fail-fast `abort` naming
the file/source/underlying error, plus a hint to remove a partially-generated ATOM directory
before retrying).

This module is **not** shared with `lib/templates/app_template.rb`'s own, separately-maintained
`fetch_thecore_sample` for the App template, even though the two were byte-for-byte identical
before this extraction. An earlier version of this section claimed the reason was
instance_eval/mixin incompatibility — review correctly identified that as wrong: `get`/
`create_file` are public Thor::Actions instance methods, so a module function taking the caller
as an explicit argument works identically from a class instance method and from an
`instance_eval`'d script, exactly like `TtyDetection.real_tty?` already proves. The real reason
is deployment, not syntax, and it's specific to the App template: its primary real-world
invocation is `rails new myapp -m https://raw.githubusercontent.com/.../app_template.rb`, and
Thor's `apply`/`instance_eval` fetches and evaluates *only that one URL's content* — there is no
mechanism for it to also pull in a sibling file from this gem's own repo, and at the moment that
command runs there is no app yet, so nothing has installed `thecore_generators` as a dependency
either. A `require "generators/thecore/sample_fetcher"` inside the template would only work by
accident (a global gem install happening to already be on the load path), not by design — so
the App template keeps its own independent copy. `AtomGenerator`, by contrast, is a normal class
file loaded the ordinary way inside an already-bundled gem, so it has no such constraint and now
calls the shared module directly, `require`d like any other file here.

**`git_init_and_commit`** — `-fG` (`rails plugin new`'s own force+skip-git flags) means no git
repo exists yet at this point. This generator narrows that gap, per ADR 0006, without fully
closing it: a local `git init -b master` + one commit (authored as the `--author`/`--email` the
generator just collected, via `-c user.name=.../-c user.email=...` rather than relying on
whatever global git config happens to be present), then `say_status`-logs the exact
`git remote add`/`git submodule add` follow-up commands — worded generically, no GitHub/GitLab
assumption — rather than creating a remote repository or running `git submodule add` itself
(deliberately out of scope, ADR 0006: an irreversible, credential-dependent, cross-boundary
action a human should confirm, matching how `AssociationWiring`'s own cross-boundary dependency
wiring already only *logs* what a human needs to add, never edits a gemspec/Gemfile for them).
The `git commit` call itself is deliberately not `abort_on_failure: true` (unlike `git init`/
`git add` just before it) — a freshly-generated tree always has something to commit in normal
use, but `git commit` failing for any reason at that point shouldn't kill the whole process via
a raw, unexplained `Kernel#abort` when every file this generator actually promises has already
been written successfully. Its result (`run`'s own return value, propagated back out through
`inside`'s block) still gates *which* message gets logged, though — caught in review: an earlier
version dropped `abort_on_failure` but kept logging the "here are your next-steps commands"
message unconditionally, which would misinform a developer about a commit that actually failed
for a real reason (not just "nothing to commit"). A failed commit now logs a distinct warning
instead of the next-steps message.

**Prompts fall back to non-interactive behavior on more than just an explicit `--non-interactive`
flag** — `effectively_non_interactive?` (used by `validate_non_interactive_options!`,
`required_field`, and `collect_api_admin_deps_choice` alike) also treats "no real TTY behind
stdin/stdout" as non-interactive, via the shared `Thecore::Generators::TtyDetection.real_tty?`
(`lib/generators/thecore/tty_detection.rb`) — a small module extracted during this ticket's own
review after it turned out `AssociationWiring`'s existing `interactive_association_prompt?` (a
named invariant in this gem's own CLAUDE.md, below) had already implemented the identical
condition independently; both now share one implementation rather than two that could silently
drift apart. Without this fallback, a caller with no real TTY (CI, a shelled-out child process)
that simply forgot `--non-interactive` would hit `required_field`'s `ask`-in-a-loop, which spins
forever re-prompting a stream that can never supply input — Thor's `ask` returns `nil`
immediately on a closed/EOF stdin, so the validator never passes and the loop never exits.
Unlike `AssociationWiring`'s equivalent fallback (a sensible default, `has_many`, with no data
lost), there's no sensible default for `thecore:atom`'s free-text fields, so the TTY-detected
case routes through the same "missing flags" abort path `--non-interactive` explicitly triggers,
rather than silently inventing placeholder text.

**Testing** (`test/generators/thecore/atom_generator_test.rb`) is `Rails::Generators::TestCase`
like every other generator here — but its `destination` is deliberately **not** under this gem's
own `tmp/` (unlike every sibling test file): `create_rails_engine`'s nested `bundle exec rails
plugin new` shell-out hits the exact same "`Rails::AppLoader.exec_app` walks *up* the directory
tree from cwd looking for a `bin/rails` to delegate to" trap `test/templates/app_template_test.rb`
already documents and hit directly while writing thecore_generators#17 — this gem lives nested
under the host backend repo, which has its own `bin/rails` a few directories up, and a
`destination_root` under this gem's own `tmp/` would silently delegate into the *host app's*
`bin/rails` instead of running `plugin new` generically (reproduced directly while writing this
generator: the exact same `bootsnap/setup` `LoadError` symptom). The fix is the same one that
ticket already established: `destination` under the system tmp dir (`Dir.tmpdir`, outside any
Rails app's ancestry, so the walk-up finds nothing to delegate to) rather than a manually-set
`BUNDLE_GEMFILE` — the test process's own `BUNDLE_GEMFILE` (set by the outer `bundle exec rake
test` invocation) is already inherited by the shelled child process without any extra test-side
plumbing, since `Thor::Actions#run`'s `system` call inherits the parent process's environment by
default. `setup` also writes a minimal stub `Gemfile` at `destination_root` (a real host app
always has one; `Rails::Generators::Actions#gem`'s own `append_file_with_newline` call in
`add_gem_to_host_gemfile` errors on a missing file otherwise) and pre-creates `vendor/submodules`
(the generator's own first guard check requires it). Only 3 of the file's 8 tests actually reach
`create_rails_engine`'s real `rails plugin new` subprocess (the guard-check tests fail before
ever reaching it; the `CLAUDE.md`-fetch-failure test builds an `AtomGenerator` instance directly
and calls `fetch_claude_md` on it, the same "construct the generator, call the one method under
test" pattern `AssociationWiring`'s own test file already established, skipping the subprocess
entirely) — no `bundle install`/test-run ever happens against the freshly generated dummy app,
only file generation, so the whole file still runs in a couple of seconds.

### `Thecore::Generators::CollectionActionGenerator` (`lib/generators/thecore/collection_action/collection_action_generator.rb`, thecore_generators#21, ADR 0006)

`rails generate thecore:collection_action NAME` — the third sibling to `RootActionGenerator`/
`MemberActionGenerator`, structurally identical (same three `include`s, `action_kind
"collection_action"`, same thin task methods verbatim) — needing **zero** changes to
`AtomAware`, `CompanionFiles`, or `ActionCompanion`; `action_kind "collection_action"` alone is
enough for placement (`lib/collection_actions/`/`config/collection_actions/`), pluralization,
and name-validation wording to fall out correctly, the same way the other two kinds already do.

Unlike Root/Member Action, there is **no** prior `thecore_code_extension` JS command this
ports — `addCollectionAction.js` never existed; `checkPractices.js`/this gem's own Actions
check have audited `collection_actions` since the Actions check shipped
(thecore_generators#14), but nothing ever generated them until now. Its own
`templates/action.rb.tt` therefore deliberately mirrors `RootActionGenerator`'s simplicity
(`add_action "<name>", :base, :collection do ... end`, a minimal GET/JSON example with an
`ActionCable.server.broadcast`) rather than the real, more complex, hand-written
`save_filters.rb`/`load_filters.rb` pattern already living in `thecore_ui_rails_admin` (see
that gem's own `lib/collection_actions/`) — a generator's starter template exists to be
customized from a simple base, not to demonstrate every RailsAdmin `:collection` feature (ADR
0006's own rationale). Notably, unlike Root's template, it does **not** call `member false`/
`collection false` — RailsAdmin's real-world usage (`save_filters.rb`/`load_filters.rb`) never
sets those booleans for a `:collection`-type action either; the third positional `:collection`
argument to `add_action` already communicates the action's scope.

`templates/action.html.erb.tt`/`action.js.tt`/`action.scss.tt` are otherwise byte-for-byte
copies of Root Action's own — these three companion templates were never actually
Root-specific content (they only ever referenced the generic `file_name`/
`action_name_camel_case` ERB locals every kind shares), so there was nothing to adapt beyond
copying them into this generator's own `templates/` directory (`render_view_js_scss_companions!`
templates from the *including* generator's own `source_paths`, so each kind needs its own copy
regardless of whether the content differs).

`check_practices`'s `ACTION_GENERATOR_CLASSES` now includes this class (see below) — a missing
Collection Action companion view/JS/SCSS is `fixable: true` the same way Root/Member's already
were, closing the gap ADR 0004 originally tracked as deliberate.

### `Thecore::CheckPractices` (`lib/thecore_generators/check_practices.rb`, `lib/tasks/thecore_generators_tasks.rake`, ADR 0004 Phase 2)

`rails thecore:check_practices` — a Ruby port of `thecore_code_extension`'s
`checkPractices.js`: the **Scaffold Files** and **Models** checks (thecore_generators#13),
plus the **Actions** check and `--fix` (thecore_generators#14).

Deliberately namespaced at the top level (`Thecore::CheckPractices`, not
`Thecore::Generators::CheckPractices`) since it is a plain audit service, not a
`Rails::Generators` subclass — the rake task is its only entry point, wired up via
`ThecoreGenerators::Railtie`'s `rake_tasks do load ... end` block (the same `Rails::Railtie`
mechanism every engine uses to expose its own rake tasks to a host app; this is separate from
and in addition to the Railtie's `config.app_generators.orm :thecore` registration). The file
`require`s `rails/generators` (the umbrella file, *before* `rails/generators/named_base`) —
without it, `Rails::Generators::Actions` (an `autoload` registered only by that umbrella file)
is undefined when this file loads during `Rails.application.load_tasks`, much earlier in boot
than a real `rails generate` invocation would trigger it (verified: omitting this `require`
raises `NameError: uninitialized constant Rails::Generators::Actions` the moment
`rails/generators/base.rb` runs).

- **`Thecore::CheckPractices::Runner`** — `#run` scans one or more context roots: the host app
  plus every ATOM under `vendor/submodules/` by default (via
  `Thecore::Generators::WorkspaceContext.all_atom_dirs` — an empty array, so just the host app,
  on a host app with no `vendor/submodules/` directory at all, or none checked out yet — nothing
  here requires ATOMs to be present), or a single named one when `atom_name:` is given, resolved
  by delegating straight to `WorkspaceContext.atom_dir_for` (the same call `AtomAware`'s
  `--atom=NAME` makes) rather than re-deriving that resolution/error-message logic here — it
  raises `Thor::Error` on an unknown name, which the rake task rescues directly. For each root,
  in order: Scaffold Files, Models (see ADR 0001/0004 above the Model section of this file; the
  `include` match uses a negative lookahead, not a plain substring check, so `include
  Api::FooBar` is never mistaken for `include Api::Foo`), then Actions. Deliberately does
  **not** port `checkPractices.js`'s `hasUnreplacedTokens` (leftover-`{{`) check anywhere: that
  was a symptom specific to the old JS string-templating system, meaningless for this gem's
  ERB-rendered output.
- **Actions check** — `root_actions`/`member_actions`/`collection_actions`, under `lib/` in an
  ATOM or `config/` in the host app (same split `ActionCompanion` uses), with identical rules
  for all three (`ACTION_KINDS`): the action file's own markers
  (`RailsAdmin::Config::Actions.add_action`, `http_methods`), each companion (view/JS/SCSS) for
  existence + its own markers, the `after_initialize.rb` require line, and a locale entry per
  existing `*.yml`. All three kinds now have an entry in `ACTION_GENERATOR_CLASSES`
  (`RootActionGenerator`/`MemberActionGenerator`/`CollectionActionGenerator`,
  thecore_generators#21 — ADR 0004 originally tracked `collection_action`'s always-`fixable:
  false` companions as a deliberate, temporary gap, closed by ADR 0006 once the third generator
  shipped), so a missing companion is fixable for all three; the other two checks (require
  line, locale entry) already worked identically for all three kinds, since they never needed
  kind-specific template content.
- **`--fix`** (`Thecore::CheckPractices.run(..., fix: true)`) applies every violation whose
  `fixable` is true by calling its `Violation#fix` Proc, then **re-scans and returns whatever
  is left** — mirroring ADR 0004's "exits non-zero whenever violations remain unresolved after
  any `--fix` pass" wording literally, rather than trusting the fix to have succeeded. A
  companion-file fix calls `generator.send(:template, template_name, rel_path)` directly on a
  freshly-built `RootActionGenerator`/`MemberActionGenerator`/`CollectionActionGenerator`
  instance — deliberately **not**
  the bundled `create_view_js_scss_companions` task method, which would try to (re)write all
  three companions together and could hit a non-interactive file-collision hang/prompt if a
  *sibling* companion already exists with different (hand-customized) content, even though only
  one companion was actually missing. The fix Proc re-checks `File.exist?` immediately before
  calling `template`, not just at scan time — the companion `rel_path` is kind-agnostic
  (`app/views/rails_admin/main/<name>.html.erb` etc.), so a `root_action` and a `member_action`
  sharing the same action name produce two independent violations against the identical file;
  without the re-check, the second violation's fix would hit the exact same interactive
  file-collision prompt against the file the first violation's fix had just created (caught
  during review, thecore_generators#14). The generator instance is built via
  `build_action_generator` — `RootActionGenerator.new([action_name], { atom: atom_name_or_nil },
  destination_root: @app_root)`, then its `destination_root=` is **force-set to the exact `root`
  the violation was found under** as a second step. The explicit `atom:` option alone is not
  enough: `AtomAware#atom_dir` treats a *blank* `--atom` (the host-app case, `atom_name_or_nil`
  is `nil`) as "no override, fall back to cwd-based `WorkspaceContext.atom_dir_for` detection",
  not as "force host-app placement" — so without the explicit `destination_root=` override
  afterward, a host-app fix could be silently misrouted into an unrelated ATOM whenever the
  check_practices process's own `Dir.pwd` happened to sit inside a `vendor/submodules/<atom>/`
  tree at fix time (the same `Dir.pwd`-reset gotcha `WorkspaceContext` documents above — caught
  during review, thecore_generators#14, and covered by a regression test that `Dir.chdir`s into
  a fixture ATOM before invoking `--fix`). Require-line and locale-entry fixes go through
  `Thecore::CheckPractices::GenericFixTarget` (a bare `Rails::Generators::NamedBase` with
  `AtomAware`+`CompanionFiles`, not discovered as a `rails generate` namespace since it isn't
  under `lib/generators/`) instead, since those two are kind-agnostic and don't need a
  kind-specific template — the require-line's own text format is `ActionCompanion.
  require_line_for(kind:, in_atom:, name:)`, a plain module method also used by
  `ActionCompanion#require_line` (the real generators' own step), so the check's expectation of
  what a require line looks like can never drift out of sync with what a real Root/Member/
  Collection Action generator actually writes.
- **`Thecore::CheckPractices::Violation`** — a `Struct` (`file`, `line`, `message`,
  `severity`, `fixable`, `code`, `fix`); `#to_h` matches the ticket's JSON schema exactly, in
  that key order, and deliberately excludes `fix` (a zero-arg Proc or nil) — it exists purely
  for `--fix` to invoke internally, mirroring `checkPractices.js`'s own `violation.fix.apply(ctx)`
  pattern, and was never part of the JSON contract.
- **`Thecore::CheckPractices::Reporter`** — `.text(violations)` (default, grouped by file) and
  `.json(violations)` (`{ "violations" => [...] }`).

**CLI flags require a literal `--` separator** (`rails thecore:check_practices -- --json
--atom=NAME --fix`) — Rake's own `Rake::Application#standard_rake_options` uses a strict
`OptionParser` on the raw command line and raises `invalid option: --json` for anything it
doesn't recognize itself, *before* the task body ever runs (verified directly against this
gem's own `test/dummy`). Everything from a literal `--` onward is left untouched at the front
of `ARGV` for the task body to parse with its own `OptionParser` — the standard, documented
Rake idiom for passing CLI-style flags through to a task
(https://ruby.github.io/rake/doc/rakefile_rdoc.html#label-Task+Arguments). A bare
`rails thecore:check_practices` (no `--`) is unaffected — `ARGV.drop_while { |a| a != "--" }`
simply yields an empty array when no separator is present.

The task calls `exit(1)` when any violation is found (never `exit(0)` on success — a rake task
that completes without calling `exit` already yields process exit code 0). **Any test that
invokes the task in-process must rescue `SystemExit`** (see
`test/support/check_practices_fixtures.rb`'s `invoke_task` helper, shared by
`test/tasks/check_practices_task_test.rb` and `check_practices_actions_test.rb`) — Minitest
deliberately treats `SystemExit` as a pass-through exception it does not catch, so an
unrescued `exit(1)` inside a test method kills the entire test process silently instead of
just failing that one test (this was hit and fixed during thecore_generators#13's own
implementation).

**Testing `--fix` against `test/dummy` fixtures**: `--fix` applies *every* fixable violation
in one pass, not just the one a given test is focused on — a fixture action file with
incomplete companions has those fixed as a side effect of *any* `--fix` call in that test, not
only the ones the test explicitly names. `check_practices_actions_test.rb` calls
`register_action_fix_cleanup!` (in the shared fixtures support file) up front in every test
that writes an action file and later calls `--fix`, to track every possible side-effect path
(all three companion-asset directories, plus a snapshot of `config/locales/en.yml`, which
`write_action_locale_entries!` rewrites in place rather than creating fresh) regardless of
which specific violation that test's own fixture triggers. Forgetting this was hit directly
during thecore_generators#14's own implementation — an incompletely-cleaned `--fix` side
effect (an unaccounted-for companion directory, or a rewritten `config/locales/en.yml`) leaks
into the next test's fixture state and produces flaky, order-dependent failures.

### The App Application Template (`lib/templates/app_template.rb`, ADR 0005 Phase 3, thecore_generators#17/#18)

A Ruby port of `thecore_code_extension`'s `createApp.js` (thecore_generators#16's spec) — but
a genuine **Rails application template**, not a `Thor::Group` generator like everything above.
Its entry point is `rails new -m`, evaluated by `Rails::Generators::AppGenerator#apply_rails_template`
directly against the file (a plain Ruby script executed with `self` bound to the `AppGenerator`
instance, giving it access to `Rails::Generators::Actions`' template DSL: `gem`, `append_to_file`,
`empty_directory`, `create_file`, `yes?`, `after_bundle`, `generate`, `rails_command`,
`bundle_command`) — there is no `Railtie`/namespace-discovery mechanism involved the way
`thecore:root_action`/`thecore:member_action` have, since `rails new -m <path-or-url>` is how
every Rails application template is invoked, full stop.

This ticket (#17) is deliberately **core only** — Gemfile content and the two developer-
convenience vendor directories — with no dependency on anything outside this gem. Devcontainer/
CI/CLAUDE.md generation, fetched from the `thecore` repo's own `samples/` at generation time, is
a separate follow-up (thecore_generators#18); see
[ADR 0005](https://github.com/gabrieletassoni/thecore/blob/release/3/docs/adr/0005-app-template-scoped-to-rails-new-m-assets-sourced-from-thecore-samples.md)
in the thecore repo for why the two are split and why those assets live in `thecore`, not
duplicated here.

**Why `gem`/`append_to_file`, not `createApp.js`'s `fs.readFileSync`/`writeFileSync` approach**:
`createApp.js` hand-reads and hand-writes the whole `Gemfile` as a string (see its own
`insertGemIntoDevelopmentGroup` regex-based insertion in `thecore_code_extension`) because JS has
no equivalent to Rails' own template DSL. This template uses the real thing instead —
`Rails::Generators::Actions#gem` appends a correctly-formatted `gem "name", "version", group:
:development` line itself; `thecore_generators`'s own dev-only dependency is a single-line
`group:` option rather than createApp.js's manual `group :development do ... end` block-nesting
logic, since Bundler treats the two forms identically. The commented-out ecosystem block (below)
can't use `gem` at all — that method only ever writes an *active* line — so it's a plain
`append_to_file` with hand-written `# gem "..." # comment` text instead.

**Why the installer chain is wrapped in `after_bundle`, not called directly at the top level**:
`AppGenerator`'s own build sequence runs `apply_rails_template` (this file, in full) *before*
`run_bundle` (its own automatic `bundle install` of everything the skeleton + this template's own
`gem` calls just added to the Gemfile) — see `public_task` ordering in `railties`'
`rails/generators/rails/app/app_generator.rb`. Any `generate "devise:install"`-style call made at
the template's own top level would therefore run against a Gemfile that hasn't been bundled yet,
failing outright (the `devise` gem isn't installed/loadable). `after_bundle do ... end` is Rails'
own mechanism for exactly this ordering problem: `run_after_bundle_callbacks` (a separate
`public_task`, after `run_bundle`) invokes every registered block only once bundling has actually
happened.

**The installer chain is genuinely optional, not a test-only escape hatch** — gated behind a real
interactive `yes?` prompt ("Run `bundle install` and the standard installer generators ... now?"),
matching this ticket's "uses Thor's `ask`/`yes?` DSL for any genuine choice point" acceptance
criterion honestly: a developer bootstrapping without network access can decline and run
`bundle install && rails generate devise:install && ...` by hand once they have connectivity, and
the Gemfile/vendor-directory content is written either way, regardless of the answer.

**Non-interactive mode (thecore_generators#23)**: `ENV["THECORE_APP_TEMPLATE_NON_INTERACTIVE"]`
(any non-blank value — same `nil?`/`empty?` blank-safety idiom as `THECORE_SAMPLES_SOURCE` above,
not a bare truthiness check) bypasses the `yes?` prompt entirely. When set, a second var,
`ENV["THECORE_APP_TEMPLATE_RUN_INSTALLERS"]`, is **required** — must be exactly `"true"` or
`"false"` (case-insensitive) — and the template `abort`s with a message naming the missing/invalid
var if it's absent or unrecognized, rather than silently defaulting either way. Mirrors
`thecore:atom`'s own `validate_non_interactive_options!` fail-fast philosophy (ADR 0006): never
guess at a required decision.

**Deliberately NOT auto-triggered by tty absence**, unlike `thecore:atom`'s `TtyDetection`-based
`effectively_non_interactive?` (which this gem's own generators use when run in-process). This
template always runs as a genuine separate `rails new` subprocess — its own test seam
(`spawn_rails_new` in `test/templates/app_template_test.rb`) spawns it via `Open3`, whose stdin is
a pipe, never a real tty, even on a run that's legitimately simulating interactive use by feeding
an answer through `stdin_data:`. Auto-triggering on tty absence would misfire on every such
simulated-interactive test invocation; the explicit env var opt-in avoids that with no loss of
real-world safety — an unattended run with neither var set still fails loudly, just from a missing
env var rather than an auto-detected absent tty.
`run_after_bundle_callbacks` calls every registered `after_bundle` block **unconditionally** —
even when `--skip-bundle` was passed to `rails new` itself (it is not gated by `bundle_install?`
the way `run_bundle` is) — so the `yes?` answer captured at top level (before the `after_bundle`
block is even defined, closed over by it) is what actually prevents `bundle_command`/`generate`
from running when the caller doesn't want them to, not `--skip-bundle` alone.

**The installer chain fails fast, mirroring `createApp.js`'s own atomic `&&`-chained shell
command**: neither `bundle_command` (a bare `system` call, no result check at all) nor
`rails_command` (only aborts when `abort_on_failure: true` is passed explicitly — `generate`
already sets that internally, confirmed against `railties`' own `actions.rb`) abort on failure by
default, so both `bundle_command` calls check their own return value and `abort` explicitly, and
every plain `rails_command` call (`active_storage:install`/`action_text:install`/
`action_mailbox:install`) passes `abort_on_failure: true`. Only two `bundle_command("install")`
calls remain, not three: `devise:install`/`rails_admin:install` add nothing new to bundle beyond
what the first call already covers (`rails_admin:install --asset=sprockets`'s own
`configure_for_sprockets` only re-adds `sassc-rails`, already declared active above — a harmless,
empirically-verified duplicate Gemfile line, not a new dependency), so the second call sits after
`action_text:install`, which can add its own `image_processing` dependency.

**The RailsAdmin route is never written, not written-then-stripped**: `rails_admin:install`'s own
`_namespace` positional argument (passed as `"app"` here — RailsAdmin's own mount-path argument,
not a placeholder) exists purely to skip its interactive mount-path prompt, since nothing in this
non-interactive chain could ever answer it. `thecore_ui_rails_admin` already mounts
`RailsAdmin::Engine` itself, in its own engine routes — so a `route(...)` call *before* invoking
the installer writes a commented placeholder line containing the exact substring
(`"mount RailsAdmin::Engine"`) `RailsAdmin::InstallGenerator#install` checks for
(`routes.rb.include?('mount RailsAdmin::Engine')`) to decide whether to insert its own mount line
at all — so it never adds one, no fragile after-the-fact `gsub_file` removal needed.

**Testing** (`test/templates/app_template_test.rb`) is the one seam this whole feature is tested
through, per the spec (thecore_generators#16) — a **real subprocess** (`Open3.capture3("bundle",
"exec", "rails", "new", ...)`), not an in-process `Rails::Generators::AppGenerator.start` call:
this test suite already boots a full `Rails::Application` (`test/dummy`) in-process for every
other test file in this gem, and running a second, unrelated `rails new` inside that same process
is an unnecessary risk to court for no benefit. Two things make it offline and deterministic
(this ticket's own acceptance criteria, and independently necessary — see above):
`--skip-bundle` stops Rails' own automatic bundle of the newly-added gems; the test feeds `"no\n"`
via `stdin_data:` to the template's own `yes?` prompt, so the installer chain's `bundle_command`/
`generate` calls are never reached either.

**The subprocess's `chdir` must not be this gem's own root** (or anywhere under this host backend
repo) — plain `rails` (`railties`' `exe/rails`, via `Rails::AppLoader.exec_app`) walks *up* the
directory tree from `cwd` looking for a `bin/rails` to delegate to, `Dir.chdir("..")`-ing at every
step, *before* it ever runs as the `rails new` generator (the exact same gotcha the "Dir.pwd
cannot be trusted..." invariant below already documents, biting a different caller here). This
gem is nested inside this host backend repo (`.scratch/thecore_generators` during development),
which has its own `bin/rails` a few directories up — `chdir`'d there, that walk-up silently execs
the *host app's* `bin/rails` instead of generating a new app (hit directly while writing this
test — the failure surfaced as a `bootsnap/setup` `LoadError` from the host app's own
`config/boot.rb`, not an obviously-relevant message). The fix: `chdir` into the scratch tmp
directory itself (which has no `bin/rails` anywhere in its ancestry) and set `BUNDLE_GEMFILE`
explicitly to this gem's own `Gemfile` — `BUNDLE_GEMFILE`, not `cwd`-based Gemfile discovery, is
what tells Bundler which bundle's `rails` to resolve.

**Devcontainer/CI/CLAUDE.md assets are fetched from `thecore`'s own `samples/`, not shipped here**
(thecore_generators#18, extended by #25): `.devcontainer/*` (`devcontainer.json`,
`docker-compose.yml`, `Dockerfile`, `create-db-user.sql`, `link-host-home.sh`,
`check-plugins.sh`), **both** `.gitlab-ci.yml` and `.github/workflows/ci.yml` (ADR 0007 —
same git-hosting-agnostic reasoning ADR 0006 already established for `thecore:atom`'s own dual-CI
generation, no hosting-profile prompt), and `CLAUDE.md` are all fetched via a
`fetch_thecore_sample(relative_path, destination)` helper
defined inline in the template (a `def` inside a `rails new -m` template's `instance_eval`d
content becomes a singleton method on the `AppGenerator` instance being evaluated against — safe
and ordinary for a Rails application template, not a global `Object` pollution risk; verified
against `Thor::Actions#apply`'s own `instance_eval(contents, path)`). The base location is
resolved fresh on every call from `ENV["THECORE_SAMPLES_SOURCE"]`, defaulting to
`https://raw.githubusercontent.com/gabrieletassoni/thecore/master/samples` — **`master`, not
`release/3`**: `thecore_generators#18`'s own ticket text said `release/3`, copying this gem's own
branch convention, but `thecore` only has a `master` branch (double-checked directly against that
repo before implementing, rather than trusting the ticket literally). An `http(s)` value is
fetched over the network via Thor's `get`; anything else is treated as a local directory and read
directly with `File.read` — `get`'s own "local" branch resolves through `source_paths`
(`find_in_source_paths`), which this template deliberately doesn't touch just for this, so the
non-HTTP case is handled by hand instead of trying to bend `get` to do it.

**`ENV["THECORE_SAMPLES_SOURCE"]` falls back to the default on blank, not just unset** —
`source.nil? || source.empty?`, not a bare `||` — because `ENV["X"] || default` treats
`THECORE_SAMPLES_SOURCE=""` (a realistic shape for an optional env var left unset in a compose
file) as a real override, silently reading a same-named file relative to whatever the current
directory happens to be instead of falling back.

**The default URL only serves real content once `thecore`'s `master` actually carries the commit
that added the asset being fetched.** `samples/CLAUDE.md`/`samples/.gitlab-ci.yml`/
`samples/devcontainer/*` (thecore#14/#15) were pushed as part of the general Phase 4
push/release pass and are live on `origin/master` today. `samples/.github/workflows/ci.yml`
(thecore#20, ADR 0007) is the current exception, as of this gem's 3.13.0 release: committed
locally in `thecore` but not yet pushed, so the default URL still 404s for that one file
specifically until it is. This is the same operational sequencing issue thecore_generators#18
first ran into, recurring per-asset rather than a defect in this code — `THECORE_SAMPLES_SOURCE`
pointed at a local `thecore` clone is the reliable way to exercise not-yet-pushed default content.

Every fetch passes `force: true` — unconditional overwrite, no interactive Thor conflict prompt.
Of the six `.devcontainer/*` files, four (`devcontainer.json`, `docker-compose.yml`, `Dockerfile`,
`create-db-user.sql`) are *expected* to already exist, written by the separate, prior "Setup
Devcontainer" VS Code command this template runs inside the bootstrap container of (verified
directly against that command's own source, `setupDevContainer.js`, not assumed) — replacing them
is the entire point of this ticket, not a conflict to ask about. The other two
(`link-host-home.sh`/`check-plugins.sh`) are **not** written by that command at all — genuinely
new files here, not overwrites — but `force: true` is harmless for a new file and keeps the whole
block uniform; an earlier draft of this comment claimed all six pre-existed, which was wrong for
these two (caught in review). `.gitlab-ci.yml`/`CLAUDE.md` don't exist yet in the documented flow
either, but stay `force: true` too so a later re-application of this same template (`bin/rails
app:template`) is a clean overwrite rather than a prompt neither a CI pipeline nor a non-interactive
caller could answer.

`get`/`create_file` only ever write file *content* — the executable bit `link-host-home.sh`/
`check-plugins.sh` need is lost the moment their bytes cross an HTTP fetch or a plain `File.read`,
so the template `chmod`s both explicitly (`0o755`) right after fetching them.

**A fetch failure aborts with a clear message, not a raw stack trace** — `fetch_thecore_sample`
rescues `StandardError` around the `get`/`create_file` call and `abort`s naming the file, the
source, and the underlying error, mirroring the fail-fast philosophy thecore_generators#17 already
applies to `bundle_command`/`rails_command` failures in the installer chain below, rather than
letting a bare `OpenURI::HTTPError` propagate and leave the app half-scaffolded (some
`.devcontainer/*` files present, others not) with no clear signal pointing back to the cause.

**Testing** (`test/templates/app_template_test.rb`) extends the exact same test method
thecore_generators#17 added, per this ticket's own acceptance criteria ("extended, not
duplicated") — no second test file, no second `rails new` subprocess spawn. The asset-source
override point is pointed at `test/fixtures/thecore_samples/` (checked into this gem's own test
folder) via `THECORE_SAMPLES_SOURCE` in `spawn_rails_new`'s env hash, so the whole suite stays
offline — these fixtures are deliberately **minimal, hand-written stand-ins**, not a live copy of
`thecore`'s real `samples/` content: this gem doesn't own that content and a synced copy would be
one more place for the two to drift apart, when the fixture's only job is proving the *fetch
mechanism* works, not re-verifying `thecore`'s own sample content (that's `thecore`'s own
responsibility, and it has no test suite by design — see its own CLAUDE.md).

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

**Postgres-only.** PostgreSQL is the only DB target of every Thecore gem and host app, so
`test/dummy` runs on it too — never SQLite (no `sqlite3` gem; the Gemfile carries `pg`).
`test/dummy/config/database.yml` is `adapter: postgresql` (host/port/user/password from
`PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD`, defaulting to `db`/`5432`/`postgres`/`postgres`), with
databases `thecore_generators_{development,test,production}`. Because `DATABASE_URL` overrides
`database.yml` and the devcontainer points it at the host app's **dev** DB, `test/dummy/config/boot.rb`
rewrites `DATABASE_URL`'s database name to `thecore_generators_<RAILS_ENV>` (keeping its
server/credentials) whenever it is a `postgres*` URL — done in `boot.rb`, not `test_helper.rb`,
so every entry point (`bin/rails db:*`, the `db:test:prepare` subprocess) is covered and a test
run can never touch the host app's database. Same pattern as `mytask`/`model_driven_api`. No need
to unset `DATABASE_URL` any more.

One-time setup (creates `thecore_generators_test` on the configured server):

```bash
bundle install
(cd test/dummy && RAILS_ENV=test bin/rails db:create)
```

```bash
bundle exec rake test
bundle exec ruby -Itest test/generators/thecore/model_generator_test.rb   # single file
```

Key test files:

- `test/generators/thecore/workspace_context_test.rb` — ATOM detection edge cases.
- `test/generators/thecore/model_generator_test.rb` / `migration_generator_test.rb` — placement,
  ATOM redirection, `--atom=NAME` override.
- `test/generators/thecore/root_action_generator_test.rb` /
  `member_action_generator_test.rb` / `collection_action_generator_test.rb` — same
  placement/ATOM/`--atom=NAME` pattern for `thecore:root_action`/`thecore:member_action`/
  `thecore:collection_action`, plus name validation and the idempotent-rerun/broadened
  locale-file cases specific to `CompanionFiles`.
- `test/generators/thecore/atom_generator_test.rb` — `thecore:atom`'s own guard checks (missing
  `vendor/submodules`, an invalid/shell-unsafe name, an already-existing `vendor/submodules/
  <name>`, missing `--non-interactive` flags — none of these reach the real `rails plugin new`
  subprocess), one full end-to-end generation each for the default (API/Admin deps included) and
  `--skip-api-admin-deps` paths (the only two tests that do reach it — the former's own
  assertions include the `CLAUDE.md` fetch, byte-for-byte against the fixture, same fixture
  directory `test/templates/app_template_test.rb` already uses via `THECORE_SAMPLES_SOURCE`), a
  Gemfile-collision case (an existing `gem "tcp_debugger", ...` line in the host Gemfile is never
  duplicated — also a full run), and the `CLAUDE.md` fetch's own failure/abort message, tested by
  building an `AtomGenerator` instance directly and calling `fetch_claude_md` on it rather than
  `run_generator`ing the whole pipeline — the same "construct the generator, call the one method
  under test" pattern `AssociationWiring`'s own test file already established, skipping the
  subprocess for a case that doesn't need it. See `AtomGenerator`'s own CLAUDE.md section above
  for why its `destination` isn't under this gem's own `tmp/` the way every other generator
  test's is.
- `test/support/check_practices_fixtures.rb` — shared fixture-writing/cleanup/task-invocation
  helpers (`write_fixture`, `register_cleanup_for`, `snapshot_existing_file!`,
  `register_action_fix_cleanup!`, `invoke_task`/`invoke_with_argv`) for both
  `check_practices_task_test.rb` and `check_practices_actions_test.rb` — the only test files in
  this gem that mutate `test/dummy` directly rather than a `Rails::Generators::TestCase` tmp
  `destination_root`.
- `test/tasks/check_practices_task_test.rb` — invokes `Rake::Task["thecore:check_practices"]`
  in-process, covering Scaffold Files + Models: both context types, `--atom=NAME` scoping and
  its unknown-atom error, the ADR 0001/0004 model-check rescoping (zero violations for a
  concern-less model, orphan include, missing marker), text vs. `--json` output shape, and the
  exit-code contract.
- `test/tasks/check_practices_actions_test.rb` — same in-process pattern, covering the Actions
  check + `--fix`: action-file markers (never fixable), missing companion view/JS/SCSS fixed
  via the real Root/Member/Collection generator's own template. Root vs. Member is proven by
  distinct rendered *content* (`fetch(url` vs. XHR); Collection's own companions are
  deliberately byte-identical to Root's by design (see `CollectionActionGenerator`'s own
  section above — content can't distinguish them), so that fix is instead proven by asserting
  `ACTION_GENERATOR_CLASSES["collection_action"]` resolves to `CollectionActionGenerator`
  directly (`collection_action`'s companions became fixable at all in thecore_generators#21,
  closing the gap this test file covered as "never fixable" before that), an existing companion
  with a missing marker left untouched by `--fix`, the require-line and locale-entry fixes
  (generic across all three kinds), `--atom=NAME` scoping a fix to inside that ATOM, and two
  regression tests added during thecore_generators#14's own review: a
  host-app fix staying in the host app even when the process's own `Dir.pwd` is `Dir.chdir`'d
  into an unrelated fixture ATOM first, and a companion shared by two action kinds with the
  same action name being fixed once without tripping Thor's file-collision prompt.
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

Version lives in `lib/thecore_generators/version.rb` (currently `3.11.0`). Pushing a commit that
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
