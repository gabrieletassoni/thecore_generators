# ATOM generator

> Moved verbatim from `CLAUDE.md` on 2026-11-11 (`Thecore::Generators::AtomGenerator`, `rails generate thecore:atom`). `CLAUDE.md` points here; keep this file accurate whenever the behaviour it describes changes.

## `Thecore::Generators::AtomGenerator` (`lib/generators/thecore/atom/atom_generator.rb`, thecore_generators#20, ADR 0006)

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

**The dummy app is on PostgreSQL, and only Thecore's CI exists** (thecore_devcontainer#15) —
`create_rails_engine` also passes `--database=postgresql` and `--skip-ci`. `--skip-ci` drops the
`.github/workflows/ci.yml` (SQLite, `main` branch) and `.github/dependabot.yml` Rails writes by
itself, so `gempush.yml`/`.gitlab-ci.yml` (`create_ci_files`) are the ATOM's only pipelines.
`configure_dummy_database` replaces Rails' postgresql `database.yml` (named `dummy_*`, no host)
with the pilot ATOM's (`mytask`) shape: server from `PG*` env vars defaulting to `db`, databases
`<name>_<env>`. `force_atom_database_under_database_url` appends the test-database rule to the
dummy's `config/boot.rb`: when `DATABASE_URL` is set it keeps only the server/credentials and
forces `<name>_<RAILS_ENV>`, with `URI` like the App template's test helper (the earlier regex
on the path turned a server-only URL such as `postgres://u:p@db:5432` into
`postgres://<name>_test`, dropping the host). It's in `boot.rb`, as in the pilot, not in `test/test_helper.rb`,
so every entry point is covered (the test helper, which sets `RAILS_ENV=test` before booting,
`bin/rails db:*`, the `db:test:prepare` subprocess). `setup_gemfile` no longer appends `pg` when
the Gemfile already declares it (Bundler rejects a gem declared twice). The test checks the rule
by loading the generated `boot.rb` in a clean `ruby` process with a development `DATABASE_URL`
and with a server-only one.
Verified by hand once: a generated ATOM's `bin/rails test` under
`DATABASE_URL=.../hostapp_development` ran on `<name>_test`.

**A freshly generated ATOM passes its own tests, untouched** (thecore_devcontainer#21). Its setup
is `bundle install`, `bin/rails db:create`, `bin/rails test`, with no edit in between. Three
things used to break that. With the API/Admin dependencies, the Thecore engines expect two
host-app pieces a plugin dummy lacks, so `configure_dummy_host_app` writes the pilot ATOM's
(`mytask`) `test/dummy/app/models/ability.rb` (empty CanCan `Ability`, as `cancan:ability` gives a
host app) and `test/dummy/config/initializers/devise.rb` (Devise's ORM hook, as `devise:install`
does). Without them boot fails with `uninitialized constant Ability`, then `undefined method
devise for User`. With `--skip-api-admin-deps` neither CanCan nor Devise is in the bundle, so
those two files and `config/initializers/abilities.rb` (which includes `CanCan::Ability`) are not
written. `setup_gemfile` always adds `gem 'minitest', '~> 5.25'`, the same pin as this gem's own
Gemfile (Rails 7.2's runner breaks on Minitest 6). The ATOM has no lockfile, so the
`--skip-api-admin-deps` variant used to resolve the newest Rails (8.1); `setup_gemspec` now writes
`spec.add_dependency "rails", "~> 7.2"` (`RAILS_VERSION`, the Rails of Thecore 3 hosts), and the
`--skip-api-admin-deps` test checks that the ATOM's `Gemfile.lock` resolves Rails 7.2.

**It publishes like the real ATOMs** (thecore_devcontainer#14). The repository starts on
`release/3` (`git init -b release/3`, and the next steps push to it), the only branch that
publishes. `gempush.yml` (GitHub, RubyGems) runs only on pushes to `release/3`, as in
`model_driven_api`. `.gitlab-ci.yml` (`create_ci_files`, built by the private `gitlab_ci`) follows
the pilot's spot ATOM (`mytask`): `build_gem` runs the image's `gem-compile.sh` only when
`lib/*/version.rb` changes and never on a tag; it includes GitLab's `Jobs/SAST` and
`Jobs/Secret-Detection` templates (`needs: []`), and `security-summary` (`allow_failure`, scanner
needs optional) runs `ruby script/security_summary.rb gl-sast-report.json
gl-secret-detection-report.json`. `fetch_security_summary` gets that script and its test
(`test/script/security_summary_test.rb`, plain Minitest, picked up by `bin/rails test`) from
`thecore`'s samples through `SampleFetcher`, like `ATOM_CLAUDE.md`. `--gem-host=HOST` (default
`rubygems.org`; a scheme and trailing slash are stripped, anything that isn't a host name or
`host:port` is refused by `validate_gem_host!` before `rails plugin new` runs) sets the gemspec's
`allowed_push_host` to `https://HOST` and, for a host other than RubyGems,
`GITLAB_GEM_REPO_TARGET: https://HOST/`. With RubyGems the variable is left out: `gem-compile.sh`
falls back to RubyGems only when it is unset, and the old `https://${GEM_HOST}/` was `https:///`
with an empty `GEM_HOST`. `gempush.yml` (`gempush_yml`) follows the same host: with RubyGems it
is unchanged (`RUBYGEMS_AUTH_TOKEN` secret, `gem push *.gem`); with another host it runs
`gem push --host https://HOST *.gem` with `GEM_HOST_API_KEY` from the `GEMS_REPO_CREDENTIALS`
repository secret (the GitLab variable's name), since RubyGems would refuse a gem whose
`allowed_push_host` names another server. The next steps then name the host's `source "https://HOST/" do` block,
and give the ATOM's test sequence (`bundle install && bin/rails db:create && bin/rails test`).

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
closing it: a local `git init -b release/3` + one commit (authored as the `--author`/`--email` the
generator just collected, via `-c user.name=.../-c user.email=...` rather than relying on
whatever global git config happens to be present), then `say_status`-logs the exact
`git remote add`/`git submodule add -b release/3` follow-up commands, then the rest of the
pilot's "Changing an ATOM" workflow (move the host `Gemfile` from the `path:` entry to the
published gem once it's out, `bundle update <name> --conservative`, commit `Gemfile.lock` with
the submodule pointer; thecore_devcontainer#15) — worded generically, no GitHub/GitLab
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
named invariant in this gem's own `docs/agents/model-and-migration-generators.md`) had already implemented the identical
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
(the generator's own first guard check requires it). Only 3 of the file's 10 tests (4 with `THECORE_REAL_SAMPLES_DIR` set) actually reach
`create_rails_engine`'s real `rails plugin new` subprocess (the guard-check and `--gem-host` tests fail
before ever reaching it; the `CLAUDE.md`-fetch-failure test builds an `AtomGenerator` instance directly
and calls `fetch_claude_md` on it, the same "construct the generator, call the one method under
test" pattern `AssociationWiring`'s own test file already established, skipping the subprocess
entirely). The two end-to-end tests (default and `--skip-api-admin-deps`) then run the generated
ATOM's own setup and suite (`assert_generated_atom_tests_pass`: `bundle install`,
`bin/rails db:create`, `bin/rails test` in the ATOM's own bundle, outside this gem's) and require
at least one run with no failure. So they need network for `bundle install` and the same
PostgreSQL as this gem's dummy app (`db`, or whatever `DATABASE_URL`/`PG*` name); with the gems
already installed the file runs in about 15 seconds. Running it in a container as a non-root user
whose `GEM_HOME` isn't writable, point `GEM_HOME` at a writable gem path too, or the ATOM's
`bundle install` fails writing the gems' executables.
