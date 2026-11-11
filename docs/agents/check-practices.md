# Check practices

> Moved verbatim from `CLAUDE.md` on 2026-11-11 (`Thecore::CheckPractices`, `rails thecore:check_practices`). `CLAUDE.md` points here; keep this file accurate whenever the behaviour it describes changes.

## `Thecore::CheckPractices` (`lib/thecore_generators/check_practices.rb`, `lib/tasks/thecore_generators_tasks.rake`, ADR 0004 Phase 2)

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
  in order: Scaffold Files, Models (see ADR 0001/0004 in the concern-elimination section of `docs/agents/model-and-migration-generators.md`; the
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
  tree at fix time (the same `Dir.pwd`-reset gotcha `WorkspaceContext` documents in `docs/agents/model-and-migration-generators.md` — caught
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
