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
[ADR 0002](https://github.com/gabrieletassoni/thecore/blob/release/3/docs/adr/0002-thecore-generators-gem-and-generator-hook-mechanism.md)),
plus default-concern removal ([ADR 0001](https://github.com/gabrieletassoni/thecore/blob/release/3/docs/adr/0001-application-record-defaults-over-generated-concerns.md))
and migration-driven inverse-association wiring
([ADR 0003](https://github.com/gabrieletassoni/thecore/blob/release/3/docs/adr/0003-migration-driven-inverse-association-wiring.md)).
`ThecoreGenerators::Railtie` registers `config.app_generators.orm :thecore, migration:
true, timestamps: true`, so plain `rails generate model`/`rails generate migration`
transparently apply thecore's scaffolding conventions — no new command vocabulary. **Phase 2
(check_practices + Root/Member Action generators) is complete** as of this release: `rails
generate thecore:root_action`, `rails generate thecore:member_action`, and `rails
thecore:check_practices` (Scaffold Files + Models + Actions, `--fix` included) all ship.
**Phase 3's App application template** (porting `createApp.js`) is complete as of this release —
both the core (`lib/templates/app_template.rb`: Rails app + Gemfile stack + vendor placeholders,
thecore_generators#17) and devcontainer/CI/CLAUDE.md asset fetching from the thecore repo's own
samples (thecore_generators#18) have shipped. See
[ADR 0005](https://github.com/gabrieletassoni/thecore/blob/release/3/docs/adr/0005-app-template-scoped-to-rails-new-m-assets-sourced-from-thecore-samples.md)
in the thecore repo for the full design. **The Collection Action generator** (`rails generate
thecore:collection_action`, thecore_generators#21) is also complete as of this release — see
[ADR 0006](https://github.com/gabrieletassoni/thecore/blob/master/docs/adr/0006-atom-generator-dual-ci-manual-submodule-wiring-collection-action-reuses-existing-infra.md)
in the thecore repo (`master`, thecore's actual default branch — unlike this gem's own
`release/3`; the ADR 0001-0005 links above predate that distinction being double-checked; note
that as of this gem's 3.11.0 release the ADR 0006 commit exists only in a local `thecore`
checkout, not yet pushed to `origin/master` — same class of operational sequencing issue
`CLAUDE.md` documents for the App template's samples fetch). **`thecore:atom`**
(`rails generate thecore:atom NAME`, thecore_generators#20/#22) is feature-complete as of this
release, including its `CLAUDE.md` fetch from thecore's own `samples/ATOM_CLAUDE.md` — but that
fetch shares the exact same not-yet-pushed caveat as ADR 0006/the App template's own samples
fetch above: it 404s against the real default GitHub URL until `thecore`'s `master` actually
carries the commit that added `samples/ATOM_CLAUDE.md`. Phase 4's one remaining piece is
documenting both new generators in the thecore repo's `GUIDE.md`/`WALKTHROUGH.md` (thecore#19).

### What `rails generate model`/`rails generate migration` do now

- **Context-aware placement.** `Thecore::Generators::WorkspaceContext` detects whether
  the invoking process's `Dir.pwd` is inside a host app or an ATOM (`vendor/submodules/<atom>/`,
  by gemspec presence — a Ruby port of `thecore_code_extension`'s `workspaceContext.js`).
  When an ATOM is detected, the model/migration/test files land inside that ATOM's own
  `app/models`/`db/migrate`/`test` instead of the host app's. Pass `--atom=NAME` to
  override detection explicitly (works independent of `cwd`, e.g. from CI or the host-app
  root).
- **No concern files by default.** `Api::ModelName`/`RailsAdmin::ModelName` concern files
  are **not** generated (per
  [ADR 0001](https://github.com/gabrieletassoni/thecore/blob/release/3/docs/adr/0001-application-record-defaults-over-generated-concerns.md)) —
  the no-customization case relies entirely on the default `json_attrs`/`navigation_label`/
  `navigation_icon` behavior that `model_driven_api` and `thecore_ui_rails_admin` `include`
  into every `ApplicationRecord` subclass automatically
  (`ThecoreBackendCommons::DefaultModuleRegistry`). Pass `--with-api-concern` and/or
  `--with-admin-concern` to scaffold a starter concern file — identical in shape to what
  this generator produced before this default changed — for the case where customization
  is already known to be needed at generation time:
  ```bash
  rails generate model Foo name:string --with-api-concern --with-admin-concern
  ```
  See "Adding a concern by hand" below for the (more common) case of realizing
  customization is needed *after* the model already exists.
- **No `Endpoints::ModelName` by default** (per ADR 0001) — add one by hand, following the
  `after_initialize` + `class_eval` pattern, only when a real custom action is needed.
- **Test file generation is never suppressed** — a real Minitest file is generated, same
  as Rails' own `active_record:model` default.
- **`rails generate active_record:model`/`active_record:migration` still work directly**
  as an escape hatch, entirely unaffected by the hook above.

Both `Thecore::Generators::ModelGenerator` and `MigrationGenerator` wrap (not reimplement)
`ActiveRecord::Generators::ModelGenerator`/`MigrationGenerator` — all attribute parsing and
template content is inherited as-is; only file placement and the two opt-in concerns are
added on top.

### Adding a concern by hand

The common case is not knowing at `rails generate model` time that a model will need
custom API serialization or RailsAdmin configuration — that need usually surfaces later.
Since neither concern is generated by default, add the missing one directly instead of
regenerating the model:

**`Api::ModelName`** (custom `json_attrs`) — create `app/models/concerns/api/model_name.rb`:
```ruby
module Api::ModelName
  extend ActiveSupport::Concern

  included do
    cattr_accessor :json_attrs
    self.json_attrs = ::ModelDrivenApi.smart_merge(json_attrs || {}), { only: [:id, :name] }
  end
end
```
then `include Api::ModelName` in the model. Because the default module (`model_driven_api`'s
`ModelDrivenApiDefaultJsonAttrs`) is already `include`d by the time the model class body
runs, `::ModelDrivenApi.smart_merge(json_attrs || {}, ...)` composes on top of it rather
than starting from nothing — the same pattern the opt-in `--with-api-concern` template
below uses.

**`RailsAdmin::ModelName`** (custom admin config) — create
`app/models/concerns/rails_admin/model_name.rb`:
```ruby
module RailsAdmin::ModelName
  extend ActiveSupport::Concern

  included do
    rails_admin do
      navigation_label I18n.t('admin.registries.label')
      navigation_icon 'fa fa-file' # see https://fontawesome.com/v5/search
      configure :some_field do
        hide
      end
    end
  end
end
```
then `include RailsAdmin::ModelName` in the model. RailsAdmin evaluates same-origin
`rails_admin do ... end` blocks in registration order and later calls win on settings they
touch (`navigation_label`/`navigation_icon` are last-write-wins setters) — so this explicit
block, `include`d after the default from the class body, overrides the default's
`navigation_label`/`navigation_icon` while the default itself keeps applying to every other
model that has no concern of its own.

Either concern can be added independently — a model doesn't need both just because it
needs one.

### Inverse association wiring for `references` columns

Rails' own generators only ever wire the owning (`belongs_to`) side of a `references`/
`add_reference` column — the inverse `has_many`/`has_one` side has always been a manual
follow-up. `rails generate model`/`migration` now write that missing inverse side
automatically into the *target* model's own canonical concern
(`config/initializers/concern_<target_model>.rb`, wired up via
`config/initializers/after_initialize.rb`):

```bash
rails generate migration AddPostRefToComments post:references
# → prompts: "Inverse association on Post for this reference (has_many/has_one/skip)?"
# → writes `has_many :comments` into config/initializers/concern_post.rb
```

With a real terminal attached you're prompted for cardinality (`has_many` default, `has_one`,
or `skip`); pass `--non-interactive` (always used by `addModel`/`addMigration` in the VS Code
extension, and recommended for any other scripted/CI invocation) to skip the prompt and default
straight to `has_many`. Re-running the generator against the same target model never duplicates
an already-written association line, and a later, different reference onto the same target
appends into the same existing concern file. When the target model lives in a different ATOM
than the one being generated into, the concern is still written into the *invoking* app/ATOM
(never the target's own) and the generator logs — but never edits — the gemspec/Gemfile
dependency line a human needs to add so that include actually resolves. Full mechanics in
`CLAUDE.md`.

### `rails generate thecore:root_action NAME`

A Ruby port of `thecore_code_extension`'s `addRootAction.js` — produces the same end result
from a terminal, with the same ATOM-aware placement `rails generate model`/`migration` use:

```bash
rails generate thecore:root_action my_action
```

This creates:

- The RailsAdmin action config file — `lib/root_actions/my_action.rb` in ATOM context,
  `config/root_actions/my_action.rb` in host-app context (main-app actions never live under
  `lib/`, for Zeitwerk autoload safety).
- Its view/JS/SCSS companions: `app/views/rails_admin/main/my_action.html.erb`,
  `app/assets/javascripts/rails_admin/actions/my_action.js`,
  `app/assets/stylesheets/rails_admin/actions/my_action.scss`.
- A `require` line inserted into `config/initializers/after_initialize.rb` (created from a
  skeleton if absent) — `require 'root_actions/my_action'` in ATOM context, a full
  `Rails.root.join(...)` require in host-app context (`config/` isn't on the load path).
- A precompile line inserted into `config/initializers/assets.rb` (created from a skeleton if
  absent).
- An `admin.actions.my_action` locale entry (`menu`/`title`/`breadcrumb`, all set to the
  title-cased action name) written into **every** `*.yml` file already present under
  `config/locales` — `en.yml`/`it.yml` are created first only when the directory has none yet.

`NAME` must be snake_case (lowercase letters, digits, underscores). `--atom=NAME` overrides
placement the same way it does for `rails generate model`/`migration`. Re-running the
generator against the same action name never duplicates the require line, the precompile
line, or a locale entry.

The reusable pieces behind this (`Thecore::Generators::CompanionFiles`,
`Thecore::Generators::ActionCompanion`) are shared with `thecore:member_action` (below), and
`check_practices --fix` (further below) delegates straight to both generators' own template
rendering rather than reimplementing it.

### `rails generate thecore:member_action NAME`

The Member Action counterpart to `thecore:root_action` above — a Ruby port of
`thecore_code_extension`'s `addMemberAction.js`, sharing everything about placement, the
after_initialize.rb/assets.rb/locale mechanics, and even the generator implementation itself
(`Thecore::Generators::ActionCompanion`) with Root Action:

```bash
rails generate thecore:member_action my_action
```

Same file layout as Root Action (`lib/member_actions/`/`config/member_actions/`,
`app/views/rails_admin/main/my_action.html.erb`, `.../actions/my_action.js`/`.scss`,
after_initialize.rb require line, assets.rb precompile line, every-locale-file entry,
`--atom=NAME`, idempotent re-run). What differs is each action's own template content — not
unified between the two, matching `addRootAction.js`/`addMemberAction.js`'s own separate
templates exactly:

- **`action.rb`** (server-side, the real behavioral difference) — a RailsAdmin `:member`
  action (`http_methods [:get, :patch]`) whose controller branches on `request.xhr? &&
  request.get?` (returns JSON) vs. `request.patch?` (a form submission, redirects back to the
  record), instead of Root's single `:root` action with a fetch/JSON + `ActionCable.server.broadcast`
  example.
- **`action.js`/`action.html.erb`** — both still set up the same `ActivityLogChannel`
  ActionCable subscription Root's do; only the test button's click handler differs (a plain
  XHR `GET` here vs. `fetch` there), and the view adds a `form_with(..., method: :patch)` for
  the PATCH half of the example.

### `rails generate thecore:atom NAME`

A Ruby port of `thecore_code_extension`'s `createATOM.js` — produces a complete, working ATOM
(a Rails engine, the Thecore unit of modular functionality) from a terminal, no VS Code
required:

```bash
rails generate thecore:atom tcp_debugger
```

Unlike every other generator in this gem, `thecore:atom` takes **no `--atom=NAME` option** —
creating a *new* ATOM only ever makes sense from a host app's own root, so it doesn't include
`Thecore::Generators::AtomAware` at all. It fails fast with a clear error if `vendor/submodules/`
doesn't exist yet in the current app, if `NAME` isn't a valid gem name (lowercase letters,
digits, underscores, hyphens, starting with a letter), or if `vendor/submodules/<NAME>` already
exists — the last one matters because `rails plugin new`'s own `-f` (force) flag would otherwise
silently overwrite an existing ATOM with the same name.

It prompts (interactively, or via `--summary=`/`--description=`/`--author=`/`--email=`/`--url=`
with `--non-interactive`) for the same five fields `createATOM.js` always has, then:

- Shells to `rails plugin new <path> -fG --skip-gemfile-entry --skip-hotwire --full` (via
  `bundle exec`, for robust gem resolution regardless of environment), producing the standard
  Rails engine skeleton.
- Asks (`yes?`-style, default yes; `--skip-api-admin-deps` in non-interactive mode) whether to
  add `model_driven_api`/`thecore_ui_rails_admin` as dependencies — at this gem's own ADR 0001
  floor (`~> 3.9`/`~> 3.8`), not `createATOM.js`'s stale `~> 3.1`/`~> 3.2`. Declining adds
  neither; the Scaffold Files/directories below are created either way.
- Creates the same Scaffold Files/directories `createATOM.js` always has: `db/migrate`, the
  API/RailsAdmin concern directories, `config/initializers`, `config/locales`,
  `lib/root_actions`/`member_actions`/`collection_actions`, JS/CSS asset directories, the
  RailsAdmin main view directory, `.github/workflows` — plus `after_initialize.rb`/`assets.rb`/
  `abilities.rb`, `db/seeds.rb`, and `en.yml`/`it.yml` locale files, all with the same skeleton
  content `createATOM.js` already produces.
- Generates **both** `.github/workflows/gempush.yml` and `.gitlab-ci.yml` unconditionally — no
  hosting-profile prompt (see ADR 0006 for why: which git host a developer pushes to is a
  per-developer choice this ecosystem already treats as generic). `gempush.yml`'s two
  long-standing bugs are fixed here (a broken `awk` pipeline computing the version string; a
  `version_exists` check referenced in `if:` conditions but never actually set, so the
  tag/publish steps have never run for any ATOM generated this way). The gemspec's
  `allowed_push_host` stays hardcoded to `https://rubygems.org`.
- Rewrites the gemspec's authors/email/homepage/summary/description/metadata fields via targeted
  in-memory substitutions (not `createATOM.js`'s own blind full-file line rewrite, which —
  verified directly against a current `rails plugin new --full` gemspec — silently drops the
  gem's own `rails` dependency when adding the two Thecore ones; this appends instead of
  replacing).
- `git init`s the new ATOM directory with one initial commit, then **logs** (never runs) the
  exact follow-up commands to create a remote and `git submodule add` it into the host app —
  worded generically, no GitHub/GitLab assumption (ADR 0006: automating a remote-repo-creating,
  credential-dependent step isn't something this generator does on your behalf).
- Adds `gem "<name>", path: "vendor/submodules/<name>"` to the host app's own `Gemfile` (via
  Thor's own `gem` action) — skipped, with a warning, if the Gemfile already declares a gem with
  that name (the same real collision the `vendor/submodules/<NAME>` guard above protects against,
  one layer up: a duplicate entry for the same gem breaks the next `bundle install`). Does
  **not** run `bundle install` — same as every other generator in this gem that touches a
  Gemfile.
- Fetches a `CLAUDE.md` skeleton from `thecore`'s own `samples/ATOM_CLAUDE.md` and writes it as
  the new ATOM's `CLAUDE.md`, via `Thecore::Generators::SampleFetcher` — a shared module using
  the exact same `THECORE_SAMPLES_SOURCE` override mechanism the App template's own asset fetch
  already established (`ENV["THECORE_SAMPLES_SOURCE"]`, defaulting to `thecore`'s `master`
  branch; http(s) fetched over the network, anything else read as a local directory; fails fast
  with a clear message naming the file/source/error on failure). Like the App template's own
  `CLAUDE.md`/`.gitlab-ci.yml` fetches, this 404s against the real default URL until `thecore`'s
  `master` actually carries the commit that added `samples/ATOM_CLAUDE.md` — see the caveat
  above.

### `rails generate thecore:collection_action NAME`

The third sibling to `thecore:root_action`/`thecore:member_action` — structurally identical
(same shared `AtomAware`/`CompanionFiles`/`ActionCompanion` modules, same file layout, same
`--atom=NAME`/idempotent-re-run behavior). Unlike Root/Member, there's no
`addCollectionAction.js` this ports — `checkPractices.js` audited `collection_actions` but
nothing ever generated them, so this is new, not a port:

```bash
rails generate thecore:collection_action my_action
```

Its own `templates/action.rb.tt` mirrors Root Action's simplicity — `add_action "my_action",
:base, :collection do ... end`, a minimal GET/JSON example with an `ActivityLogChannel`
broadcast — rather than the more complex, hand-written `save_filters.rb`/`load_filters.rb`
pattern already living in `thecore_ui_rails_admin`: a generator's starter template exists to be
customized from a simple base, not to demonstrate every RailsAdmin `:collection` feature. A
collection action operates against a model's whole index (all records), as distinct from a
member action (one record) or a root action (global, no model scope at all).

### `rails thecore:check_practices`

A Ruby port of `thecore_code_extension`'s `checkPractices.js` — audits **Scaffold Files**
(thecore_generators#13), **Models** (thecore_generators#13), and **Actions**
(thecore_generators#14, `--fix` included).

```bash
rails thecore:check_practices                       # host app + every ATOM under vendor/submodules/
rails thecore:check_practices -- --atom=my_atom      # scope to a single ATOM
rails thecore:check_practices -- --json              # structured output for CI/the VS Code extension
rails thecore:check_practices -- --fix               # apply every fixable violation, no confirmation
```

The `--` before any flag is the standard Rake convention for passing arguments through to a
task instead of having Rake's own option parser reject them — see
[Rake's own docs](https://ruby.github.io/rake/doc/rakefile_rdoc.html#label-Task+Arguments).
Flags combine freely, e.g. `rails thecore:check_practices -- --atom=my_atom --fix --json`.

- **Scaffold Files** — `config/initializers/after_initialize.rb` and `assets.rb` must exist
  and carry their structural marker (`Rails.application.configure do` /
  `Rails.application.config.assets.precompile`). Checked in **both** ATOM and host-app
  context (`checkPractices.js` only ever checked ATOM context). Not fixable.
- **Models** — rescoped per [ADR 0001](https://github.com/gabrieletassoni/thecore/blob/release/3/docs/adr/0001-application-record-defaults-over-generated-concerns.md):
  a model with **no** `Api::`/`RailsAdmin::` concern is the correct, no-customization default
  and is never flagged. Only two states are violations: a model `include`-ing a concern module
  whose file doesn't exist (`orphan_api_include`/`orphan_rails_admin_include`), or a concern
  file present but missing one of its required markers (`extend ActiveSupport::Concern` plus
  `cattr_accessor :json_attrs` for `Api::`, `rails_admin do` for `RailsAdmin::`). Not fixable —
  regenerating over an existing, hand-edited concern could clobber real customization.
- **Actions** — scans `root_actions`, `member_actions`, and `collection_actions` (in `lib/` for
  an ATOM, `config/` for the host app), with the same rules for all three. Reports
  missing/broken action-file markers (`RailsAdmin::Config::Actions.add_action`, `http_methods`
  — never fixable), a missing companion view/JS/SCSS or one present but missing its own marker
  (a *missing* companion is fixable for all three kinds — `root_action`/`member_action`/
  `collection_action` — by delegating straight to that kind's own generator's template
  rendering; an *existing* companion missing a marker is never fixable, same reasoning as
  Models), a missing `after_initialize.rb` require line (fixable, all three kinds), and a
  missing locale entry checked against **every** `*.yml` already present in the locales
  directory, not just `en`/`it` (fixable, all three kinds).

Default output is human-readable text grouped by file; `--json` emits
`{ "violations": [{ "file", "line", "message", "severity", "fixable", "code" }] }` — `code` is
a stable identifier (e.g. `missing_after_initialize`, `orphan_api_include`,
`missing_companion_view`) a future consumer can filter on without depending on `message` text.
`--fix` applies every fixable violation in one pass with no confirmation of its own — whoever
passes it has already decided — then re-scans and reports/exits based on whatever violations
remain (so a violation this run can't fix, e.g. an action file's own broken
`RailsAdmin::Config::Actions.add_action` marker, still shows up after `--fix`). The task exits
non-zero whenever any violation remains, zero otherwise, so it's usable as a CI gate either
with or without `--fix`.

### Application Template (`rails new -m`) (thecore_generators#17/#18)

A Ruby port of `thecore_code_extension`'s `createApp.js`, as a genuine Rails application
template rather than a `thecore:*` generator — its entry point is `rails new -m`, not `rails
generate`:

```bash
rails new myapp --database=postgresql --asset-pipeline=sprockets \
  -m https://raw.githubusercontent.com/gabrieletassoni/thecore_generators/release/3/lib/templates/app_template.rb
```

Run inside a devcontainer already created by the "Setup Devcontainer" VS Code command — a
bootstrap step this template doesn't invoke or modify itself (that command's own code is
untouched), even though the template's own devcontainer-asset fetch below does overwrite the
files that bootstrap step created, by design. See
[ADR 0005](https://github.com/gabrieletassoni/thecore/blob/release/3/docs/adr/0005-app-template-scoped-to-rails-new-m-assets-sourced-from-thecore-samples.md)
for the full design and why the two stay separate).

- **Core Gemfile stack, active** — `devise`, `cancancan`, `rails_admin`, `sassc-rails`,
  `model_driven_api` (`~> 3.9`), `thecore_ui_rails_admin` (`~> 3.8` — both meeting ADR 0001's
  `DefaultModuleRegistry` floor), `rails-erd` (`:development`). `thecore_generators` itself is
  added too, `group: :development` — so the generated app can immediately use every
  generator/task documented above without a manual Gemfile edit first.
- **The rest of the generic Thecore ecosystem, commented out** — `thecore_auth_commons`,
  `thecore_settings`, `thecore_print_commons`, `thecore_background_jobs`, `thecore_ui_commons`,
  `thecore_tcp_debug`, `thecore_download_documents`, `thecore_dataentry_commons`,
  `thecore_connectors`, each with a one-line purpose comment — discoverable but off by default,
  the same "commented but documented" philosophy ADR 0005 applies to the devcontainer's `gh`/
  `glab` CLI mounts below.
- **`vendor/submodules/`/`vendor/external/`** — created empty (a `.keep` file each), not
  pre-wired with any submodule or gem. Per ADR 0005 these are developer-convenience clone
  locations, not template content.
- **Devcontainer/CI/CLAUDE.md**, fetched from the `thecore` repo's own `samples/` (single source
  of truth, not duplicated here) and written unconditionally, overwriting whatever the bootstrap
  "Setup Devcontainer" step created: `.devcontainer/*` (base image, plugin mounts, `gh`/`glab`
  CLI config mounts commented out by default), **both** `.gitlab-ci.yml` and
  `.github/workflows/ci.yml` (build/test/lint/deploy, no customer-specific paths — no hosting-
  profile prompt, same git-hosting-agnostic reasoning ADR 0006 established for `thecore:atom`'s
  own dual-CI generation, extended here by ADR 0007/thecore_generators#25), and `CLAUDE.md`
  (universal sections only, project-specific sections left as TODO placeholders). The fetch
  location is one overridable point,
  `ENV["THECORE_SAMPLES_SOURCE"]`, defaulting to the raw GitHub URL for `thecore`'s `samples/`
  on `master` (`thecore`'s actual default branch).
- **The standard installer chain** (`devise:install`, `rails_admin:install`, `active_storage:
  install`, `action_text:install`, `action_mailbox:install`, `cancan:ability`, `erd:install`,
  each preceded by the necessary `bundle install`) is genuinely optional, gated behind an
  interactive prompt (`yes?`, wrapped in `after_bundle` so it only ever runs once the gems
  above are actually bundled) — a developer bootstrapping without network access can decline
  and run these by hand later.
- **Non-interactive/unattended mode**: set `THECORE_APP_TEMPLATE_NON_INTERACTIVE` (any non-blank
  value) to bypass the installer-chain prompt above. When set, `THECORE_APP_TEMPLATE_RUN_INSTALLERS`
  (`"true"` or `"false"`) is required — the template aborts with a clear message if it's missing
  or unrecognized, rather than guessing. Example:
  ```bash
  THECORE_APP_TEMPLATE_NON_INTERACTIVE=1 THECORE_APP_TEMPLATE_RUN_INSTALLERS=true \
    rails new myapp --database=postgresql --asset-pipeline=sprockets \
    -m https://raw.githubusercontent.com/gabrieletassoni/thecore_generators/release/3/lib/templates/app_template.rb
  ```

## Installation

Add to your host app's or ATOM's `Gemfile`:

```ruby
gem "thecore_generators", "~> 3.0"
```

## Running tests locally

Tests use a `Rails::Generators::TestCase`-based harness against the `test/dummy` Rails
app included in this repo (needed to exercise generators the way a real host app would).
`test/dummy` also boots real `model_driven_api`/`thecore_ui_rails_admin` (and their own
transitive `thecore_backend_commons`/`thecore_auth_commons` dependencies) as temporary
git-based dependencies — see the Gemfile's comment — purely so
`test/generators/thecore/model_generator_default_concern_behavior_test.rb` can prove the
no-concern default actually works at runtime, not just that no file was written.

```bash
bundle install
bundle exec rake test
```

If your shell has `DATABASE_URL` set to a PostgreSQL URL (e.g. inside the Thecore
devcontainer), unset it first — it overrides `test/dummy`'s own SQLite3 test config:

```bash
env -u DATABASE_URL bundle exec rake test
```

`bundle exec rake` alone runs the same suite (`test` is the default Rake task).

To run a single test file:

```bash
bundle exec ruby -Itest test/generators/thecore/model_generator_test.rb
```

## Who depends on this

The host backend app's own `Gemfile` (`:development` group) and the
[Thecore VS Code extension](https://github.com/gabrieletassoni/thecore_code_extension)'s
`addModel`/`addMigration` commands both depend on this gem being present to get Thecore-aware
`rails generate` behavior — the extension actually checks for it and offers to add it
automatically if it's missing, since without it `rails generate model`/`migration` still "work"
but silently skip every convention described above. See `CLAUDE.md`'s "Who consumes this gem"
section for detail.

## Releasing

Version lives in `lib/thecore_generators/version.rb`. Pushing a commit that bumps it
triggers `.github/workflows/gempush.yml`, which tags the commit with that version and
publishes to RubyGems (skipped if the tag already exists) — the same pattern used by the
other gems in this ecosystem (`model_driven_api`, `thecore_backend_commons`, etc.).

## License

MIT — see [`MIT-LICENSE`](MIT-LICENSE).
