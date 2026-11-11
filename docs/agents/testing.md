# Test infrastructure

> Moved verbatim from `CLAUDE.md` on 2026-11-11 (test infrastructure, Postgres-only dummy app, key test files, pins). `CLAUDE.md` points here; keep this file accurate whenever the behaviour it describes changes.

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
  subprocess, nor does an invalid `--gem-host`), one full end-to-end generation each for the
  default (API/Admin deps included, RubyGems) and `--skip-api-admin-deps` (with a private
  `--gem-host`) paths (the only two tests that do reach it — the former's own
  assertions include the `CLAUDE.md` fetch, byte-for-byte against the fixture, same fixture
  directory `test/templates/app_template_test.rb` already uses via `THECORE_SAMPLES_SOURCE`), a
  Gemfile-collision case (an existing `gem "tcp_debugger", ...` line in the host Gemfile is never
  duplicated — also a full run), S2 on `thecore`'s real samples (skipped unless
  `THECORE_REAL_SAMPLES_DIR` names a `samples/` folder, as in the App template's S1: the ATOM's
  `CLAUDE.md` has the test sequence, "Publishing" and "Security scanning", and the security
  summary's test passes inside the ATOM via `bin/rails test`), and the `CLAUDE.md` fetch's own failure/abort message, tested by
  building an `AtomGenerator` instance directly and calling `fetch_claude_md` on it rather than
  `run_generator`ing the whole pipeline — the same "construct the generator, call the one method
  under test" pattern `AssociationWiring`'s own test file already established, skipping the
  subprocess for a case that doesn't need it. See `AtomGenerator`'s own section in `docs/agents/atom-generator.md`
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
  section in `docs/agents/action-generators.md` — content can't distinguish them), so that fix is instead proven by asserting
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
