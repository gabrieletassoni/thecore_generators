# App application template

> Moved verbatim from `CLAUDE.md` on 2026-11-11 (`lib/templates/app_template.rb`, `rails new -m`). `CLAUDE.md` points here; keep this file accurate whenever the behaviour it describes changes.

## The App Application Template (`lib/templates/app_template.rb`, ADR 0005 Phase 3, thecore_generators#17/#18)

A Ruby port of `thecore_code_extension`'s `createApp.js` (thecore_generators#16's spec) — but
a genuine **Rails application template**, not a `Thor::Group` generator like the ones in `docs/agents/model-and-migration-generators.md`, `action-generators.md` and `atom-generator.md`.
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

**Gemfile floors and pins (thecore_devcontainer#17)**: each floor is the first release carrying a
fix the pilot (mytask-imas) depends on, so `bundle update --conservative` from an old lock can't
stay below it: `model_driven_api >= 3.13.1`, `thecore_ui_rails_admin >= 3.8.7`,
`thecore_backend_commons >= 3.10`, `thecore_auth_commons >= 3.6.3` (the last two are transitive
and get their own line only for the floor), and `rails >= 7.2.4`/`puma >= 7.2.1`, whose lines
`rails new` already writes, so they're rewritten with `gsub_file` (a second `gem` line with a
different requirement is a Bundler error). Two pins stay, each with its reason in the template:
`redis < 6` (Action Cable 7.2's Redis adapter refuses redis 6 at load, and a fresh resolve takes
6.0.0) and `connection_pool ~> 2.4` (Sidekiq <= 7.3.9 breaks on connection_pool 3 without capping
it; drop the pin once `thecore_background_jobs` moves to Sidekiq 8). **Only raise a floor to a
version published on RubyGems**: S1 runs a real `bundle lock`. `thecore_backend_commons`' floor is
3.10.0 (thecore_devcontainer#23): no job retries by default, failures set capped at 1,
`THECORE_JOB_RETRIES`/`THECORE_FAILED_JOBS_KEPT` (thecore_devcontainer#16, #22).
The "optional" commented block lists only gems not already in the bundle; `thecore_settings`,
`thecore_background_jobs` and `thecore_ui_commons` are named as dependencies instead. S1 asserts
the floors on the Gemfile's requirements and on the resolved lock (`assert_gem_floor_practices`).

**No root `Dockerfile` (thecore_devcontainer#7)**: `rails new` 7.2 writes a Kamal-style root
`Dockerfile` and the `bin/docker-entrypoint` it runs. The Thecore build script
(`scripts/app-compile.sh` in `thecore_devcontainer`) builds with a root `Dockerfile` whenever one
exists, and only falls back to the Thecore one (`/etc/thecore/docker/Dockerfile`) otherwise — so
the template `remove_file`s both, and the app is built like the pilot (mytask-imas), which has no
root `Dockerfile`. Done here rather than in the extension, so "Create an App" (which delegates to
this template) and a bare `rails new -m` behave the same. `.dockerignore` is kept: the Thecore
Dockerfile's `ADD .` honours it (the extension's "Create an App" still deletes it on its own).
The real-samples test (S1, below) asserts both files are gone (`assert_docker_build_practices`).

**The installer chain is genuinely optional, not a test-only escape hatch** — gated behind a real
interactive `yes?` prompt ("Run `bundle install` and the standard installer generators ... now?"),
matching this ticket's "uses Thor's `ask`/`yes?` DSL for any genuine choice point" acceptance
criterion honestly: a developer bootstrapping without network access can decline and run
`bundle install && rails generate devise:install && ...` by hand once they have connectivity, and
the Gemfile/vendor-directory content is written either way, regardless of the answer.

**Test-database rule (thecore_devcontainer#8)**: after the samples fetch, the template inserts a
block into the generated `test/test_helper.rb`, right after `ENV["RAILS_ENV"] ||= "test"`. When
`DATABASE_URL` is set, the block replaces the database it names with `<app>_test` (`app_name` is
interpolated at generation time), parsing the URL with `URI` so a URL naming only the server gets
a database too. This is the pilot's rule (mytask-imas `test/test_helper.rb`), except the pilot uses
a regex on the path, which mangles a server-only URL. The CI samples use that form so that
`db:test:prepare` takes `database.yml`'s test name. The insert is skipped when `rails new
--skip-test` produced no helper. The real-samples test (S1) checks the behaviour, not the text: it
loads the generated helper with `require_relative` stubbed and reads `DATABASE_URL` at the point
where `config/environment` would load. `require "uri"` is preloaded there, because `uri` itself
calls `require_relative`.

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
cannot be trusted..." invariant in `docs/agents/model-and-migration-generators.md` already documents, biting a different caller here). This
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
`check-plugins.sh`, `heal-stale-containers.sh`), **both** `.gitlab-ci.yml` and `.github/workflows/ci.yml` (ADR 0007 —
same git-hosting-agnostic reasoning ADR 0006 already established for `thecore:atom`'s own dual-CI
generation, no hosting-profile prompt), `CLAUDE.md`, `AGENTS.md` and `docs/agents/`
(`issue-tracker.md`, `triage-labels.md`, `domain.md`; thecore_devcontainer#13) are all fetched via a
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

**The default URL serves whatever `thecore`'s `master` carries.** A new sample (or a change to
one) reaches apps generated from the default URL only once it's pushed there, so a `thecore`
samples change is pushed before the template change that fetches it (spec thecore_devcontainer#5).
`THECORE_SAMPLES_SOURCE` pointed at a local `thecore` clone exercises unpushed content.

Every fetch passes `force: true` — unconditional overwrite, no interactive Thor conflict prompt.
In the documented flow the separate, prior "Setup Devcontainer" VS Code command
(`setupDevContainer.js`) has already written all eight `.devcontainer/*` files (the extension's
templates carry the same content as the samples, thecore_devcontainer#11) — replacing them is the
point, not a conflict to ask about. With a bare `rails new -m`, or an older extension release, some
or all of them are new files instead, and `force: true` is harmless there. `.gitlab-ci.yml`,
`CLAUDE.md` and the agent docs stay `force: true` too, so a later re-application of this same
template (`bin/rails app:template`) is a clean overwrite rather than a prompt neither a CI
pipeline nor a non-interactive caller could answer.

`get`/`create_file` only ever write file *content* — the executable bit `link-host-home.sh`/
`check-plugins.sh` need is lost the moment their bytes cross an HTTP fetch or a plain `File.read`,
so the template `chmod`s them (and `heal-stale-containers.sh`) explicitly (`0o755`) right after fetching them.

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

**The real-samples run (seam S1, thecore_devcontainer#5/#6)** —
`test_app_generated_from_real_thecore_samples_carries_pilot_practices` generates a second app,
this time from a local checkout of `thecore`'s **real** `samples/`, and asserts on that app the
practices a developer gets from the pilot (mytask-imas): today the heal, host-home and
plugin-check scripts in `.devcontainer/`, executable, and `initializeCommand` running the heal
script on `${localWorkspaceFolder}` (`devcontainer.json` is parsed as JSONC); no root `Dockerfile`
and no `bin/docker-entrypoint`; the agent docs (`assert_agent_docs_practices`: `docs/agents/` with
the tracker picked from the git remote and the five triage labels, an `AGENTS.md` that only points
to `CLAUDE.md`, and `CLAUDE.md`'s required sections, checked section by section with
`markdown_section`, and no customer-specific content); the security CI
(`assert_security_ci_practices`, thecore_devcontainer#9: the GitLab SAST/Secret Detection
includes, `workflow: rules` disabling them on schedules, brakeman/bundler-audit/security-summary
with `needs: []` and their `allow_failure`s, `extends` resolved by `gitlab_job`, `except:
schedules` on build/test/lint/to-dev/to-prod, the GitHub `security.yml` on push and schedule,
`CLAUDE.md`'s "Security scanning", and the fetched `test/script/security_summary_test.rb` run
with plain `ruby` inside the generated app). The fixture run
above keeps proving the fetch mechanism; this one catches drift between samples and template.
Each area has its own `assert_*_practices(app_path)` helper called from that one method, so a
later ticket adds a helper and a call there, and `rails new` still runs once.

It reads the samples directory from `THECORE_REAL_SAMPLES_DIR` (the `samples/` folder itself, e.g.
`<thecore checkout>/samples`, any worktree included). Unset or blank, the test **skips**, so the
default suite stays offline; set to a path without `devcontainer/devcontainer.json`, it fails
rather than skipping. Ruby isn't on the developer host, so in the dev image mount the checkout and
pass the path:

```bash
docker run --rm ... -e THECORE_REAL_SAMPLES_DIR=/thecore/samples \
  -v <thecore checkout>:/thecore:ro -v "$PWD":/w -w /w gabrieletassoni/vscode-devcontainers-thecore:3 \
  bash -c 'bundle exec ruby -Itest test/templates/app_template_test.rb'
```

Inside the devcontainer, `THECORE_REAL_SAMPLES_DIR=<thecore checkout>/samples bundle exec rake test`.
To test a `thecore` samples change, point it at the checkout that carries the change.
