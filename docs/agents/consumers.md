# Who consumes this gem

> Moved verbatim from `CLAUDE.md` on 2026-11-11 (the backend Gemfile and the Thecore VS Code extension). `CLAUDE.md` points here; keep this file accurate whenever the behaviour it describes changes.

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
  documented in `docs/agents/model-and-migration-generators.md`) rather than relying on this gem's own cwd-based detection.

  Because both commands now trust `rails generate` completely, a host app whose `Gemfile` simply
  doesn't depend on this gem gets a **silent** regression from the extension's point of view:
  plain `rails g model`/`migration` still runs and exits `0`, but with none of the behavior `CLAUDE.md`
  and `docs/agents/` describe, and no error surfaces anywhere. The extension guards against exactly that
  before collecting any model/migration input — `libs/thecoreGeneratorsGuard.js`'s
  `confirmAndAddThecoreGenerators` checks the host app's `Gemfile` for a `thecore_generators` gem
  line (tolerant of quoting/version-constraint/`group`-nesting), and on a miss prompts the
  developer to have it add `gem "thecore_generators", "~> 3.2"` to a `group :development do` block
  and run `bundle install` before proceeding (declining aborts the command instead of silently
  degrading). This lives entirely on the extension side — this gem has no awareness of it.
