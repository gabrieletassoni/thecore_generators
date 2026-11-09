# frozen_string_literal: true

# Thecore 3 Application Template — porting createApp.js's Gemfile/vendor-directory
# behavior (thecore_generators#17) plus devcontainer/CI/CLAUDE.md assets fetched from
# thecore's own samples/ (thecore_generators#18). See ADR 0005 in the thecore repo for
# the full design rationale behind both.
#
# Invoke via:
#
#   rails new myapp --database=postgresql --asset-pipeline=sprockets \
#     -m https://raw.githubusercontent.com/gabrieletassoni/thecore_generators/release/3/lib/templates/app_template.rb
#
# (or a local path to this file, e.g. while developing thecore_generators itself)

# --- Core Gemfile stack ------------------------------------------------------
# Always added, uncommented — every Thecore host app needs these (see thecore's own
# CLAUDE.md/GUIDE.md, "Standard Gem Stack").
gem "devise"
gem "cancancan"
gem "rails_admin"
# `rails_admin:install --asset=sprockets` (below) also unconditionally appends its own
# `gem 'sassc-rails'` line via its `configure_for_sprockets` step -- verified against
# the installed rails_admin 3.3.0 source, that step does nothing else. The resulting
# duplicate is harmless (empirically confirmed: `bundle lock` against two identical,
# unconstrained `gem` lines warns "lists the gem more than once" but resolves and
# exits 0) -- not worth a fragile post-install dedupe for a cosmetic Gemfile wart, and
# this declaration must stay regardless, since sassc-rails needs to be active even
# when the installer chain below is declined.
gem "sassc-rails"

# --- Floors and pins ----------------------------------------------------------
# Each floor is the first release carrying a fix the pilot (mytask-imas) depends on, so
# a `bundle update --conservative` from an old lock can't stay below it. ADR 0001
# (thecore repo) only needed model_driven_api >= 3.9.0 / thecore_ui_rails_admin >= 3.8.0
# (DefaultModuleRegistry); the floors below are higher.
#   - model_driven_api 3.13.1: the generic API no longer instantiates the class named by
#     the request path (any JWT could run `Tempfile.new` through `GET /api/v2/tempfiles`).
#   - thecore_ui_rails_admin 3.8.7: RailsAdmin's User create form answered 500 under
#     Devise 5, which thecore_auth_commons 3.6.3 requires.
gem "model_driven_api", "~> 3.13", ">= 3.13.1"
gem "thecore_ui_rails_admin", "~> 3.8", ">= 3.8.7"
# Both already arrive as dependencies of the two gems above; listed only for their floors.
#   - thecore_backend_commons 3.9.1: ActionCable verifies the JWT's signature and expiry
#     (3.9.0 moved to roo 3, so rubyzip >= 3.4, CVE-2026-85396). Goes to ">= 3.10" once
#     3.10.0 (no job retries by default, thecore_devcontainer#16) is on RubyGems.
#   - thecore_auth_commons 3.6.3: OAuth login takes the identity only from OmniAuth's
#     verified data, never from request params (3.6.2: no fixed initial admin password).
gem "thecore_backend_commons", "~> 3.9", ">= 3.9.1"
gem "thecore_auth_commons", "~> 3.6", ">= 3.6.3"
# `rails new` already declares rails and puma: their lines are rewritten, since a second
# `gem` line with a different requirement is a Bundler error.
#   - rails 7.2.4: carries the 7.2.3.1/7.2.3.2 security fixes.
#   - puma 7.2.1: fixes the PROXY protocol v1 CVE-2026-47736/47737.
gsub_file "Gemfile", /^gem ["']rails["'].*$/, 'gem "rails", "~> 7.2", ">= 7.2.4"'
gsub_file "Gemfile", /^gem ["']puma["'].*$/, 'gem "puma", ">= 7.2.1"'
# Pins still needed (checked against rubygems.org on 2026-11-09):
#   - redis < 6: Action Cable 7.2's Redis adapter (production's cable.yml) requires
#     `redis >= 4, < 6` when it loads. redis-namespace (via thecore_background_jobs) only
#     asks for `>= 4`, so a fresh resolve takes redis 6.0.0 and production crashes at boot
#     with a Gem::LoadError.
#   - connection_pool ~> 2.4: connection_pool 3 changed TimedStack#pop and breaks Sidekiq
#     7's scheduler thread. Sidekiq 7.3.10 caps it below 3 itself, but 7.3.9 and earlier
#     don't, and Bundler can still pick that pair: a fresh resolve of this gem's own dev
#     bundle took sidekiq 7.3.9 with connection_pool 3.0.2 (a fresh app took 7.3.10).
#     thecore_background_jobs keeps `sidekiq ~> 7.0`, so drop this pin once it moves to
#     Sidekiq 8 (which requires connection_pool >= 3).
gem "redis", "< 6"
gem "connection_pool", "~> 2.4"
gem "rails-erd", group: :development

# thecore_generators itself is dev-tooling only (it hooks `rails g model`/`migration`,
# see ADR 0002 in the thecore repo) — never a runtime dependency, so it goes in the
# :development group. A single-line `group:` option is equivalent to (and simpler
# than) createApp.js's manual `group :development do ... end` block insertion.
gem "thecore_generators", "~> 3.13", group: :development

# --- Optional ecosystem gems, discoverable but off by default ---------------
# Same "commented but documented" philosophy as the devcontainer's gh/glab CLI
# mounts (ADR 0005): each of these publishes to RubyGems.org (see thecore's own
# CLAUDE.md) but isn't needed by every app, so it starts commented out with a
# one-line description — uncomment only the ones this project actually needs.
# The ones already in the bundle as dependencies are named, not offered.
append_to_file "Gemfile", <<~RUBY

  # Already in the bundle as dependencies of the gems above, so don't add them:
  #   thecore_settings (via thecore_auth_commons)
  #   thecore_background_jobs (via thecore_backend_commons)
  #   thecore_ui_commons (via thecore_ui_rails_admin)

  # The rest of the generic Thecore ecosystem — uncomment only what you need.
  # gem "thecore_print_commons", "~> 3.0" # Shared PDF/print generation helpers
  # gem "thecore_tcp_debug", "~> 3.0" # TCP-level debugging/diagnostics support
  # gem "thecore_download_documents", "~> 3.0" # Document download support
  # gem "thecore_dataentry_commons", "~> 3.0" # Shared data-entry UI helpers
RUBY

# --- Developer-convenience placeholder directories --------------------------
# NOT template content (ADR 0005) — just known, git-trackable locations to clone
# auxiliary repos into during local development. Created empty; nothing is
# pre-wired, no submodule declarations, no Gemfile `path:` entries.
empty_directory "vendor/submodules"
create_file "vendor/submodules/.keep", <<~TEXT
  Clone auxiliary Thecore ecosystem repos here during local development (e.g. an
  ATOM you're developing against this app). Not consumed by any Gemfile entry
  automatically — add a `path:` gem yourself if you want one of these clones
  bundled from source instead of from RubyGems.org.
TEXT

empty_directory "vendor/external"
create_file "vendor/external/.keep", <<~TEXT
  Clone read-only reference repos here during local development (framework docs,
  sibling tooling repos you want open alongside this app). Not consumed by
  anything automatically.
TEXT

# --- No root Dockerfile ------------------------------------------------------
# `rails new` (7.2) writes a Kamal-style root `Dockerfile` plus the
# `bin/docker-entrypoint` it runs. The Thecore build script (`app-compile.sh` in
# thecore_devcontainer) prefers a root `Dockerfile` whenever one exists, so keeping
# Rails' one would make CI build the app with it instead of the Thecore Dockerfile
# (`/etc/thecore/docker/Dockerfile`), which is what the pilot (mytask-imas) uses.
# Removed here, not in the extension, so both "Create an App" and a bare
# `rails new -m` get it. `.dockerignore` is left alone: the Thecore Dockerfile's
# `ADD .` honours it.
remove_file "Dockerfile"
remove_file "bin/docker-entrypoint"

# --- Devcontainer / CI / CLAUDE.md assets, from thecore's own samples -------
# Single source of truth (ADR 0005) — not duplicated inside this gem. The base
# location is resolved fresh inside `fetch_thecore_sample` on every call, through
# one overridable point: `ENV["THECORE_SAMPLES_SOURCE"]`, defaulting to the real
# raw GitHub URL for thecore's `samples/` directory on `master` (thecore's own
# default branch — double-checked directly against that repo, not assumed from
# this gem's own `release/3` naming convention, which doesn't apply there). An
# unset *or blank* env var falls back to the default (an explicit emptiness
# check, not `||` alone — `ENV["X"] || default` would treat `THECORE_SAMPLES_SOURCE=""`,
# a realistic shape for an optional env var in a compose file with no value set,
# as a real override and try to read a same-named file relative to whatever the
# current directory happens to be, instead of falling back). An http(s) value is
# fetched over the network via `get`; anything else is treated as a local
# directory and read directly — this gem's own offline test points it at a
# fixture instead.
#
# Every write below is unconditional (`force: true`, no interactive prompt).
# Inside the documented flow, the separate, prior "Setup Devcontainer" step
# (`thecore_code_extension/commands/setupDevContainer.js`) has already written the
# eight `.devcontainer/*` files; replacing them with the samples is the point, not a
# conflict to ask about. With a bare `rails new -m` (or an older extension release)
# some or all of them are new files instead, and `force: true` is harmless there.
# `.gitlab-ci.yml`/`CLAUDE.md` and the agent docs stay unconditional too, so
# re-running this template later (`bin/rails app:template`) is a clean overwrite,
# not a prompt.
#
# A fetch failure (a network blip, or `thecore` reorganizing `samples/`) aborts
# the whole template with a clear, specific message instead of continuing into a silently half-scaffolded app
# (some `.devcontainer/*` files present, others not, no clear signal pointing
# back to the real cause) -- the same fail-fast philosophy thecore_generators#17
# already applies to `bundle_command`/`rails_command` failures in the installer
# chain below.
def fetch_thecore_sample(relative_path, destination)
  source = ENV["THECORE_SAMPLES_SOURCE"]
  source = "https://raw.githubusercontent.com/gabrieletassoni/thecore/master/samples" if source.nil? || source.empty?

  if source.start_with?("http://", "https://")
    get("#{source}/#{relative_path}", destination, force: true)
  else
    create_file(destination, File.read(File.join(source, relative_path)), force: true)
  end
rescue StandardError => e
  abort("Failed to fetch #{relative_path} from #{source} (#{e.class}: #{e.message}) " \
    "-- aborting the app template. Set THECORE_SAMPLES_SOURCE to override the source.")
end

%w[devcontainer.json docker-compose.yml Dockerfile create-db-user.sql link-host-home.sh check-plugins.sh
   heal-stale-containers.sh github-accounts.sh].each do |file|
  fetch_thecore_sample("devcontainer/#{file}", ".devcontainer/#{file}")
end
# `get`/`create_file` only write content, never permissions — the executable bit
# has to be restored explicitly for the four scripts (`thecore/samples/devcontainer/`
# stores them executable, but that's lost the moment their bytes cross an HTTP
# fetch or a plain `File.read`).
chmod ".devcontainer/link-host-home.sh", 0o755
chmod ".devcontainer/check-plugins.sh", 0o755
chmod ".devcontainer/heal-stale-containers.sh", 0o755
chmod ".devcontainer/github-accounts.sh", 0o755

fetch_thecore_sample(".gitlab-ci.yml", ".gitlab-ci.yml")
# thecore_generators#25 (ADR 0007): fetched unconditionally, alongside .gitlab-ci.yml above --
# no hosting-profile prompt, same reasoning ADR 0006 already established for thecore:atom's own
# dual-CI generation (git hosting is a generic, per-developer choice, not something to ask about).
fetch_thecore_sample(".github/workflows/ci.yml", ".github/workflows/ci.yml")
# thecore_devcontainer#9: the pilot's security CI. GitHub's scans (brakeman, bundler-audit, nightly
# too) are a workflow of their own, so the schedule never builds or deploys; the GitLab ones live in
# .gitlab-ci.yml above. The GitLab security-summary job runs script/security_summary.rb, fetched
# with its plain-Minitest test (run by `bin/rails test` with the rest).
fetch_thecore_sample(".github/workflows/security.yml", ".github/workflows/security.yml")
fetch_thecore_sample("script/security_summary.rb", "script/security_summary.rb")
fetch_thecore_sample("test/script/security_summary_test.rb", "test/script/security_summary_test.rb")
fetch_thecore_sample("CLAUDE.md", "CLAUDE.md")
# thecore_devcontainer#13: the agent docs CLAUDE.md points to (issue tracker picked from the git
# remote's host, triage labels, domain docs) and an AGENTS.md that only points to CLAUDE.md, so
# agents other than Claude Code read the same single source.
fetch_thecore_sample("AGENTS.md", "AGENTS.md")
%w[issue-tracker.md triage-labels.md domain.md].each do |doc|
  fetch_thecore_sample("docs/agents/#{doc}", "docs/agents/#{doc}")
end

# --- Test database rule (the pilot's, mytask-imas test/test_helper.rb) --------
# The devcontainer sets one global DATABASE_URL pointing at the development
# database, and a URL wins over database.yml's per-environment names -- so
# without this, `rails test` would run (and wipe fixtures' tables) against
# development. Swapping whatever database the URL names for `<app>_test`, before
# the app boots, gives tests their own database on the same server. The pilot's
# version is a regex on the path, which mangles a URL naming only the server (the
# form the CI samples use, so `db:test:prepare` takes database.yml's test name);
# URI handles both.
# Skipped when `rails new --skip-test` generated no test helper.
if File.exist?(File.join(destination_root, "test/test_helper.rb"))
  insert_into_file "test/test_helper.rb", after: /^ENV\[["']RAILS_ENV["']\] \|\|= ["']test["']\n/ do
    <<~RUBY

      # DATABASE_URL (set by the devcontainer) names the development database and wins
      # over config/database.yml: replace whatever database it names (or add one, when it
      # names only the server) with the test one, so running tests never touches
      # development data.
      if ENV["DATABASE_URL"]
        require "uri"
        test_database_url = URI.parse(ENV["DATABASE_URL"])
        test_database_url.path = "/#{app_name}_test"
        ENV["DATABASE_URL"] = test_database_url.to_s
      end

    RUBY
  end
end

# --- Standard installer chain ------------------------------------------------
# Needs the gems added above actually bundled and installable, i.e. real network
# access — genuinely optional (not a test-only escape hatch): a developer
# bootstrapping offline can say no here and run these steps by hand once they
# have connectivity. Wrapped in `after_bundle` (Rails' own template mechanism
# for "run this once the gems this template just added are actually bundled")
# so it runs after — never before — the gems above are installed.
if options[:asset_pipeline].to_s != "sprockets"
  say_status :warning,
    "this template assumes --asset-pipeline=sprockets (got #{options[:asset_pipeline].inspect}) " \
    "-- rails_admin:install below is still configured for sprockets regardless, see the invocation " \
    "documented in this gem's README.",
    :yellow
end

# thecore_generators#23: non-interactive mode, triggered ONLY by the explicit env var
# below -- deliberately NOT auto-detected from tty absence the way `thecore:atom`'s
# `TtyDetection`-based `effectively_non_interactive?` is (ADR 0006). That precedent
# works because `AtomGenerator` runs in-process inside its own test, where stubbing
# `$stdin.tty?`/`$stdout.tty?` (see `association_wiring_test.rb`) is meaningful. This
# template instead always runs as a genuine separate `rails new` subprocess (its own
# test seam spawns it via Open3), whose stdin is a pipe -- never a real tty -- even
# when the test is legitimately simulating interactive use by feeding an answer via
# `stdin_data`. Auto-triggering on tty absence would misfire on every such simulated-
# interactive test run; the explicit, deliberate opt-in below avoids that with no loss
# of real-world safety (an unattended CI run with neither var set still fails loudly
# below, just one env var short of `thecore:atom`'s own auto-detected equivalent).
non_interactive = !ENV["THECORE_APP_TEMPLATE_NON_INTERACTIVE"].to_s.strip.empty?

run_setup_now =
  if non_interactive
    run_installers_raw = ENV["THECORE_APP_TEMPLATE_RUN_INSTALLERS"]
    if run_installers_raw.nil? || run_installers_raw.strip.empty?
      abort(
        "THECORE_APP_TEMPLATE_NON_INTERACTIVE is set but THECORE_APP_TEMPLATE_RUN_INSTALLERS " \
        "is not -- set it to \"true\" or \"false\" to say whether the installer chain " \
        "(devise/rails_admin/active_storage/action_text/action_mailbox/cancan/erd) should run."
      )
    end
    normalized = run_installers_raw.strip.downcase
    unless %w[true false].include?(normalized)
      abort(
        "THECORE_APP_TEMPLATE_RUN_INSTALLERS must be \"true\" or \"false\", got " \
        "#{run_installers_raw.inspect}."
      )
    end
    normalized == "true"
  else
    yes?(
      "Run `bundle install` and the standard installer generators (devise, rails_admin, " \
      "active_storage, action_text, action_mailbox, cancan, erd) now? (y/n)"
    )
  end

after_bundle do
  next unless run_setup_now

  # `bundle_command`/`rails_command` never abort on failure by themselves (verified
  # against railties' own source: `bundle_command` is a bare `system` call with no
  # result check at all; `rails_command` only aborts when `abort_on_failure: true` is
  # passed explicitly -- `generate` sets that internally, `rails_command` does not).
  # createApp.js's own equivalent was one `&&`-joined shell command that failed the
  # whole chain atomically on any step; matched here explicitly rather than silently
  # limping on into later steps against a broken bundle/app.
  abort("bundle install failed -- aborting the app template's installer chain") unless bundle_command("install")

  generate "devise:install"

  # The `_namespace` positional argument ("app") is RailsAdmin::InstallGenerator's own
  # mount-path argument (not a placeholder/app-name) -- passing a non-blank value here
  # is what makes it skip its interactive "Where do you want to mount rails_admin?"
  # prompt (verified against its source), which nothing in this non-interactive chain
  # could ever answer. The resulting namespace is irrelevant: `thecore_ui_rails_admin`
  # already mounts `RailsAdmin::Engine` itself, in its own engine routes (see that
  # gem's `config/routes.rb`) -- a second, active mount in *this* app's routes.rb would
  # be a genuine duplicate route, not just cosmetic. `route(...)` below writes a
  # commented placeholder line containing the exact substring
  # (`"mount RailsAdmin::Engine"`) the installer checks for
  # (`routes.rb.include?('mount RailsAdmin::Engine')`) *before* calling it, so it skips
  # inserting an active one at all -- more robust than adding one and regex-stripping
  # it back out afterward (a future RailsAdmin release reformatting its generated line
  # would silently break a regex-based removal with no error raised anywhere).
  route "# mount RailsAdmin::Engine -- already mounted by thecore_ui_rails_admin's own engine routes, see that gem's config/routes.rb"
  generate "rails_admin:install", "app", "--asset=sprockets"

  rails_command "active_storage:install", abort_on_failure: true
  rails_command "action_text:install", abort_on_failure: true
  # action_text:install (above) may add its own `image_processing` Gemfile dependency
  # (verified against its source) -- this bundle is the one that actually picks that
  # up; devise:install/rails_admin:install above added nothing new to bundle beyond
  # what the first `bundle_command("install")` already covered, so no bundle call sits
  # between them.
  abort("bundle install failed -- aborting the app template's installer chain") unless bundle_command("install")
  rails_command "action_mailbox:install", abort_on_failure: true
  generate "cancan:ability"
  generate "erd:install"
end
