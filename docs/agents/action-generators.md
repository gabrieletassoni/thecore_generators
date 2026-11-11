# Action generators

> Moved verbatim from `CLAUDE.md` on 2026-11-11 (CompanionFiles, ActionCompanion, RootActionGenerator, MemberActionGenerator, CollectionActionGenerator). `CLAUDE.md` points here; keep this file accurate whenever the behaviour it describes changes.

## `Thecore::Generators::CompanionFiles` (`lib/generators/thecore/companion_files.rb`)

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
  (`docs/agents/model-and-migration-generators.md`) — same structure/anchor, so the two compose fine regardless of which one creates the
  file first, but kept independent to avoid touching already-shipped Phase 1 code for this
  ticket.
- `write_action_locale_entries!(key, title)` — writes an `admin.actions.<key>` entry
  (`menu`/`title`/`breadcrumb`, all set to `title`) into **every** `*.yml` file already present
  under `config/locales` (`en.yml`/`it.yml` are created first, and only then, when the directory
  has no locale file yet) — broader than `addRootAction.js`'s original behavior, which only ever
  touched `en.yml`/`it.yml`.

## `Thecore::Generators::ActionCompanion` (`lib/generators/thecore/action_companion.rb`)

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

## `Thecore::Generators::RootActionGenerator` (`lib/generators/thecore/root_action/root_action_generator.rb`, ADR 0002 Phase 2)

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

## `Thecore::Generators::MemberActionGenerator` (`lib/generators/thecore/member_action/member_action_generator.rb`, ADR 0002 Phase 2)

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


## `Thecore::Generators::CollectionActionGenerator` (`lib/generators/thecore/collection_action/collection_action_generator.rb`, thecore_generators#21, ADR 0006)

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

`check_practices`'s `ACTION_GENERATOR_CLASSES` now includes this class (see `docs/agents/check-practices.md`) — a missing
Collection Action companion view/JS/SCSS is `fixable: true` the same way Root/Member's already
were, closing the gap ADR 0004 originally tracked as deliberate.
