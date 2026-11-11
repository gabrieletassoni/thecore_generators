# CLAUDE.md — thecore_generators

Rails-native generators for Thecore 3 apps and ATOMs. It hooks Rails' own `rails generate model`/`migration` (registered as the `:thecore` ORM by `ThecoreGenerators::Railtie`), adds `thecore:root_action`/`member_action`/`collection_action`/`atom` generators, the `rails thecore:check_practices` audit and the `rails new -m` App template, so the Thecore conventions are the same from a terminal or from the [Thecore VS Code extension](https://github.com/gabrieletassoni/thecore_code_extension). Design: ADR [0002](https://github.com/gabrieletassoni/thecore/blob/release/3/docs/adr/0002-thecore-generators-gem-and-generator-hook-mechanism.md), [0001](https://github.com/gabrieletassoni/thecore/blob/release/3/docs/adr/0001-application-record-defaults-over-generated-concerns.md) and [0003](https://github.com/gabrieletassoni/thecore/blob/release/3/docs/adr/0003-migration-driven-inverse-association-wiring.md) in the `thecore` repo.

## Where things are

```
lib/thecore_generators/       railtie.rb (ORM registration + rake tasks), check_practices.rb, version.rb
lib/generators/thecore/       workspace_context.rb, atom_aware.rb, association_wiring.rb, companion_files.rb,
                              action_companion.rb, sample_fetcher.rb, tty_detection.rb,
                              model/, migration/, root_action/, member_action/, collection_action/, atom/
lib/templates/app_template.rb the `rails new -m` App template
lib/tasks/                    thecore:check_practices rake task
test/                         dummy/ (PostgreSQL Rails app), generators/, tasks/, templates/, support/, fixtures/
```

## Read before working on…

| Topic | File |
| --- | --- |
| Model/migration hook, `WorkspaceContext`, `AtomAware`, concern flags, `AssociationWiring`, key invariants | `docs/agents/model-and-migration-generators.md` |
| `CompanionFiles`, `ActionCompanion`, Root/Member/Collection action generators | `docs/agents/action-generators.md` |
| `thecore:atom` (`AtomGenerator`) | `docs/agents/atom-generator.md` |
| `thecore:check_practices` (`Thecore::CheckPractices`, `--fix`) | `docs/agents/check-practices.md` |
| App template (`rails new -m`, samples fetch, real-samples test S1) | `docs/agents/app-template.md` |
| Test infrastructure, key test files, pins | `docs/agents/testing.md` |
| Who consumes this gem (backend Gemfile, VS Code extension) | `docs/agents/consumers.md` |
| Security scanning (CodeQL, secret scanning, Dependabot) | `docs/agents/security-scanning.md` |
| Issue tracker, triage labels, domain docs | `docs/agents/issue-tracker.md`, `triage-labels.md`, `domain.md` |

## Key invariants and gotchas

- **Never reimplement ActiveRecord's own generator logic.** Every override calls `super` first (or last, for placement-only overrides like `db_migrate_path`) and adds behavior on top ("hook, don't fork", ADR 0002).
- **`Dir.pwd` cannot be trusted for ATOM detection from a spawned child process**: any caller that shells out to `rails generate` (CI, an editor extension, a rake task) must pass `--atom=NAME` explicitly.
- **Always pass `--non-interactive` from a non-interactive caller**; the TTY guard in `AssociationWiring` is a fallback, not the contract.
- **Never hand-edit the generated section of a per-model concern** (below `HEADER_COMMENT`): a later generator run may append into it again.
- `--with-api-concern`/`--with-admin-concern` output is byte-identical to the old `addModel.js` templates; `lib/generators/thecore/model/templates/*.tt` is the single source of truth.
- Test-only Gemfile entries are **not** wrapped in `group :test do end` (see the Gemfile's comment).
- Thor task methods must be defined directly in each generator class body, never moved into an included module (Thor only discovers methods defined there).
- Any test that invokes a rake task in-process must rescue `SystemExit`.
- A generator test that shells out to `rails new`/`rails plugin new` must not run under this repo (or the host backend) tree: `exe/rails` walks up to the nearest `bin/rails`.
- Only raise a Gemfile floor in the App template to a version already published on RubyGems.
- Details and reasons for all of these: `docs/agents/model-and-migration-generators.md` and the topic files above.

## Tests

**Postgres-only**, never SQLite: `test/dummy` runs on PostgreSQL (`PG*` env vars, default `db`/`5432`/`postgres`/`postgres`), and `test/dummy/config/boot.rb` forces the database to `thecore_generators_<RAILS_ENV>`, so a run never touches the host app's DB. `minitest` stays pinned to `~> 5.25` (Rails 7.2).

```bash
bundle install
(cd test/dummy && RAILS_ENV=test bin/rails db:create)                      # one-time
bundle exec rake test
bundle exec ruby -Itest test/generators/thecore/model_generator_test.rb   # single file
THECORE_REAL_SAMPLES_DIR=<thecore checkout>/samples bundle exec rake test  # + real-samples S1/S2
```

Every change gets tests; keep `CLAUDE.md` or the `docs/agents/` file it points to accurate whenever the behaviour it describes changes. Details: `docs/agents/testing.md`.

## Releasing

Version lives in `lib/thecore_generators/version.rb` (currently `3.11.0`). Pushing a commit that
bumps it triggers `.github/workflows/gempush.yml`, which tags the commit with that version and
publishes to RubyGems (skipped if the tag already exists) — same pattern as the other gems in
this ecosystem.

Secret scanning with push protection is the only check that blocks a push: if it fires on a real secret, remove it from the commit and rotate the secret; never bypass it (`docs/agents/security-scanning.md`).

## Agent skills

### Issue tracker

Tasks, issues, bugs, tickets and specs for this repository live **only** in its GitHub Issues
(`gabrieletassoni/thecore_generators`), handled with the `gh` CLI. See `docs/agents/issue-tracker.md`.

**Mandatory rule.** Whenever a skill or development work creates, reads, updates, comments on,
assigns, blocks or closes a task, issue, bug, ticket or spec (for example /to-tickets, /to-spec,
/triage, /wayfinder, /implement, /diagnosing-bugs, /code-review, closing a piece of work, a bug found
during a session), do it in this repository's GitHub Issues following `docs/agents/issue-tracker.md`.
Never use Odoo, `.scratch/` or local Markdown files as a tracker: Odoo is only for the repositories
on Bancolini's GitLab. `#123` means a GitHub issue number of this repository. If `gh` doesn't work,
stop and say so instead of falling back to another tracker.

### Triage labels

The five canonical triage roles map to GitHub labels with the same name (`needs-triage`,
`needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root, created lazily when the first
term or decision is resolved. See `docs/agents/domain.md`.

### Skills

Matt Pocock's skills come from the `mattpocock-skills` Claude Code plugin installed on the
developer's **host** (`claude plugins install mattpocock-skills`, official marketplace), never
vendored here: no `.agents/skills/`, `.claude/commands/` or `skills-lock.json`. Its `ask-matt` skill
maps how the skills connect.
