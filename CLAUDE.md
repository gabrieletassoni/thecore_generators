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

Shared skeleton for `RootActionGenerator` and `MemberActionGenerator` (below), holding
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
never drift out of sync with what `RootActionGenerator`/`MemberActionGenerator` actually write.

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
  existing `*.yml`. `collection_action` has no entry in `ACTION_GENERATOR_CLASSES` (no
  generator exists for it — ADR 0004 tracks this as a deliberate gap), so its missing-companion
  violations always carry `fixable: false`; the other two checks (require line, locale entry)
  work identically for all three kinds since they don't need kind-specific template content.
- **`--fix`** (`Thecore::CheckPractices.run(..., fix: true)`) applies every violation whose
  `fixable` is true by calling its `Violation#fix` Proc, then **re-scans and returns whatever
  is left** — mirroring ADR 0004's "exits non-zero whenever violations remain unresolved after
  any `--fix` pass" wording literally, rather than trusting the fix to have succeeded. A
  companion-file fix calls `generator.send(:template, template_name, rel_path)` directly on a
  freshly-built `RootActionGenerator`/`MemberActionGenerator` instance — deliberately **not**
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
  Root/Member-specific template — the require-line's own text format is `ActionCompanion.
  require_line_for(kind:, in_atom:, name:)`, a plain module method also used by
  `ActionCompanion#require_line` (the real generators' own step), so the check's expectation of
  what a require line looks like can never drift out of sync with what a real Root/Member
  Action generator actually writes.
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

### The App Application Template (`lib/templates/app_template.rb`, ADR 0005 Phase 3 — core, thecore_generators#17)

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
- `test/generators/thecore/root_action_generator_test.rb` /
  `member_action_generator_test.rb` — same placement/ATOM/`--atom=NAME` pattern for
  `thecore:root_action`/`thecore:member_action`, plus name validation and the
  idempotent-rerun/broadened locale-file cases specific to `CompanionFiles`.
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
  via the real Root/Member generator's own template (proving each produces its own distinct
  content, not a shared one), an existing companion with a missing marker left untouched by
  `--fix`, the require-line and locale-entry fixes (generic across all three kinds),
  `collection_action`'s companions never being fixable, `--atom=NAME` scoping a fix to inside
  that ATOM, and two regression tests added during thecore_generators#14's own review: a
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

Version lives in `lib/thecore_generators/version.rb` (currently `3.7.0`). Pushing a commit that
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
