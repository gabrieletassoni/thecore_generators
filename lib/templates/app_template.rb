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
#   - model_driven_api 3.13.2: JSON with `include:` works on Rails 8.1 (older ones raise
#     FrozenError there). Since 3.13.1 the generic API no longer instantiates the class named
#     by the request path (any JWT could run `Tempfile.new` through `GET /api/v2/tempfiles`).
#   - thecore_ui_rails_admin 3.8.7: RailsAdmin's User create form answered 500 under
#     Devise 5, which thecore_auth_commons 3.6.3 requires.
gem "model_driven_api", "~> 3.13", ">= 3.13.2"
gem "thecore_ui_rails_admin", "~> 3.8", ">= 3.8.7"
# Both already arrive as dependencies of the two gems above; listed only for their floors.
#   - thecore_backend_commons 3.11.0: the first that resolves on Rails 8.1 (rails-i18n 8).
#     Since 3.10.0 no job is retried by default and only the latest
#     failed job is kept (sidekiq-failures set capped at 1), so failing jobs can't fill
#     Redis; THECORE_JOB_RETRIES / THECORE_FAILED_JOBS_KEPT change both per installation.
#     It also carries 3.9.1's ActionCable JWT verification and 3.9.0's roo 3 (rubyzip
#     >= 3.4, CVE-2026-85396).
#   - thecore_auth_commons 3.6.3: OAuth login takes the identity only from OmniAuth's
#     verified data, never from request params (3.6.2: no fixed initial admin password).
gem "thecore_backend_commons", "~> 3.11"
gem "thecore_auth_commons", "~> 3.6", ">= 3.6.3"
# `rails new` already declares rails and puma: their lines are rewritten, since a second
# `gem` line with a different requirement is a Bundler error.
#   - rails 8.1.4.1: new apps start on Rails 8.1 (ADR 0033 in mytask-imas, Odoo #6091), the
#     first release with the 2026-11-04 security fixes. `~> 8.1.4` keeps it below 8.2,
#     which the 3.x ATOMs don't support.
#   - puma 7.2.1: fixes the PROXY protocol v1 CVE-2026-47736/47737.
gsub_file "Gemfile", /^gem ["']rails["'].*$/, 'gem "rails", "~> 8.1.4", ">= 8.1.4.1"'
gsub_file "Gemfile", /^gem ["']puma["'].*$/, 'gem "puma", ">= 7.2.1"'
# Pins still needed (checked against rubygems.org on 2026-11-09):
#   - redis < 6: the line the pilot runs. Action Cable 7.2's Redis adapter (production's
#     cable.yml) refused redis 6 at load; 8.1's accepts `< 7`, but redis 6 is untried with
#     redis-namespace and Sidekiq 7 (via thecore_background_jobs), which only ask for
#     `>= 4`. Lift it once the pilot runs on redis 6.
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
# `rails new` writes a Kamal-style root `Dockerfile` plus the
# `bin/docker-entrypoint` it runs. The Thecore build script (`app-compile.sh` in
# thecore_devcontainer) prefers a root `Dockerfile` whenever one exists, so keeping
# Rails' one would make CI build the app with it instead of the Thecore Dockerfile
# (`/etc/thecore/docker/Dockerfile`), which is what the pilot (mytask-imas) uses.
# Removed here, not in the extension, so both "Create an App" and a bare
# `rails new -m` get it. `.dockerignore` is left alone: the Thecore Dockerfile's
# `ADD .` honours it.
remove_file "Dockerfile"
remove_file "bin/docker-entrypoint"

# The files below repeat what `thecore:atom` writes into an ATOM's dummy app (atom_generator.rb):
# this template runs standalone through `rails new -m <URL>` and can't require this gem's code.

# --- Devise's ORM hook, before anything boots the app ------------------------
# thecore_backend_commons and thecore_auth_commons load `User` while the app boots, and `User`
# calls `devise`, which only exists once "devise/orm/active_record" is required. Devise's own
# initializer requires it, but `devise:install` (below) has to boot the app to write it, and so
# do Rails' own `importmap:install` and any later `bin/rails` command: without this file every
# one of them fails with "undefined method `devise' for class User". Kept after the install
# too; requiring the hook a second time from config/initializers/devise.rb is a no-op.
create_file "config/initializers/00_devise_orm.rb", <<~RUBY, skip: true
  # Loads Devise's ActiveRecord hook before the Thecore engines load `User` at boot.
  require "devise/orm/active_record"
RUBY

# --- The app's Ability, before anything boots the app -------------------------
# thecore_auth_commons references `Ability` while the app boots, so `cancan:ability` (which
# boots it to run) could never write it. The pilot's (mytask-imas) Ability, written directly:
# permissions come from thecore_auth_commons' Role/Permission system, never from rules here.
create_file "app/models/ability.rb", <<~RUBY, skip: true
  # frozen_string_literal: true

  # CanCanCan ability class. Permissions in this application are managed through
  # the Role / Permission / Predicate system provided by thecore_auth_commons,
  # which populates abilities at runtime via its own hooks. This class is
  # intentionally left empty — adding rules here would bypass that system.
  class Ability
    include CanCan::Ability

    def initialize(user); end
  end
RUBY

# --- The Thecore 3 runtime, not Rails 8's defaults (#27, stage 1) -------------
# release/3 apps run like the pilot (mytask-imas): jobs on Sidekiq (thecore_backend_commons
# sets the production adapter), Action Cable on Redis, one production database (a Thecore
# deploy has one), built with the Thecore Dockerfile. Rails 8's Solid Queue/Cache/Cable, Kamal
# and Thruster come with release/4 (ADR 0035 in mytask-imas). The result is what `rails new
# --skip-solid --skip-kamal --skip-thruster` writes, except SSL: `--skip-kamal` would also turn
# on `force_ssl`/`assume_ssl`, while a Thecore installation terminates SSL at its proxy, so they
# stay commented out. Done here, not left to the caller, so "Create App" and a bare
# `rails new -m` give the same app; Rails 7.2's `rails new` writes none of it.
#
# The skeleton is already written when the template runs, but Rails' own `run_kamal` (`kamal
# init`, config/deploy.yml, .kamal/) and `run_solid` (the solid_*:install commands, which write
# config/{queue,cache,recurring}.yml, db/*_schema.rb, bin/jobs, the Solid lines of
# production.rb and cable.yml) run after it: the same switches skip them, as Rails' own
# implied options do.
self.options = options.merge(skip_solid: true, skip_kamal: true, skip_thruster: true).freeze
gsub_file "Gemfile", /^# Use the database-backed adapters for Rails\.cache.*\n/, ""
gsub_file "Gemfile", /^# Deploy this application anywhere as a Docker container.*\n/, ""
gsub_file "Gemfile", /^# Add HTTP asset caching\/compression and X-Sendfile.*\n/, ""
gsub_file "Gemfile", /^gem ["'](solid_cache|solid_queue|solid_cable|kamal|thruster)["'].*\n\n?/, ""
if File.exist?(File.join(destination_root, "config/database.yml"))
  # Rails 8's production section (primary + cache/queue/cable databases, with a comment on
  # their *_DATABASE_URL variables) becomes the single database `--skip-solid` writes.
  gsub_file "config/database.yml",
    /^# Connection URLs for non-primary databases.*?_DATABASE_URL=.*?\n#\n/m, ""
  gsub_file "config/database.yml",
    /^production:\n  primary: &primary_production\n(?:    .*\n)+(?:  (?:cache|queue|cable):\n(?:    .*\n)+)+/ do |section|
    primary = section[/  primary: &primary_production\n((?:    .*\n)+)/, 1]
    "production:\n" + primary.gsub(/^    /, "  ")
  end
end
gsub_file "config/puma.rb", /^# Run the Solid Queue supervisor inside of Puma.*\nplugin :solid_queue.*\n\n?/, "" if File.exist?(File.join(destination_root, "config/puma.rb"))
gsub_file ".dockerignore", /^# Ignore Kamal files\.\n(?:\/.*\n)+\n?/, "" if File.exist?(File.join(destination_root, ".dockerignore"))
remove_file "bin/thrust"

# --- Action Cable base classes ----------------------------------------------
# Rails 8 no longer generates app/channels/application_cable (7.2 did), but
# thecore_backend_commons includes its JWT cable authentication into
# ApplicationCable::Connection at boot and its channels subclass
# ApplicationCable::Channel: without them the app raises NameError when it starts.
# `skip: true` keeps the ones an older `rails new` already wrote.
create_file "app/channels/application_cable/connection.rb", <<~RUBY, skip: true
  module ApplicationCable
    class Connection < ActionCable::Connection::Base
    end
  end
RUBY
create_file "app/channels/application_cable/channel.rb", <<~RUBY, skip: true
  module ApplicationCable
    class Channel < ActionCable::Channel::Base
    end
  end
RUBY

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
# eight `.devcontainer/*` files (ten from the extension release after 3.11.0, eleven after 3.12.0);
# replacing them with the samples is the point, not a
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

# `docker-socket-gid.sh` (initializeCommand, on the host) writes the host's
# docker.sock gid to `.devcontainer/.env` for docker-compose.yml's `group_add`;
# `.gitignore` keeps that per-host `.env` out of git, since Rails' own
# `.gitignore` only covers `/.env*` at the root (ADR 0006 in thecore_devcontainer).
# `ldap-users.ldif` is the test user of the compose file's `ldap` service, which the
# system tests below sign in with (thecore_generators#28, ADR 0010 in thecore).
%w[devcontainer.json docker-compose.yml Dockerfile create-db-user.sql link-host-home.sh check-plugins.sh
   heal-stale-containers.sh github-accounts.sh docker-socket-gid.sh .gitignore ldap-users.ldif].each do |file|
  fetch_thecore_sample("devcontainer/#{file}", ".devcontainer/#{file}")
end
# `get`/`create_file` only write content, never permissions — the executable bit
# has to be restored explicitly for the five scripts (`thecore/samples/devcontainer/`
# stores them executable, but that's lost the moment their bytes cross an HTTP
# fetch or a plain `File.read`).
chmod ".devcontainer/link-host-home.sh", 0o755
chmod ".devcontainer/check-plugins.sh", 0o755
chmod ".devcontainer/heal-stale-containers.sh", 0o755
chmod ".devcontainer/github-accounts.sh", 0o755
chmod ".devcontainer/docker-socket-gid.sh", 0o755

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
# thecore_generators#28 (ADR 0010 in thecore): on-demand system tests against the devcontainer's
# `selenium` browser (SELENIUM_URL) and `ldap` service, with a smoke test. Rails 8.1 writes no
# application_system_test_case.rb without `--devcontainer`, so this is a create, not an overwrite;
# CI runs `bin/rails test`, which skips test/system.
fetch_thecore_sample("test/application_system_test_case.rb", "test/application_system_test_case.rb")
fetch_thecore_sample("test/system/sign_in_test.rb", "test/system/sign_in_test.rb")
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
# Rails 8's `rails new` only generates Propshaft (`--asset-pipeline=sprockets` is gone), but
# RailsAdmin 3 and the Thecore UI ATOMs run on Sprockets, as the pilot does: swap the gem and
# write the manifest Sprockets requires at boot (the one `rails new` 7.2 generated). The
# layout's `stylesheet_link_tag :app` is Propshaft's "every stylesheet" name: Sprockets looks
# for an app.css that doesn't exist, so every page with the layout raised AssetNotFound.
if File.read(File.join(destination_root, "Gemfile")).match?(/^gem ["']propshaft["']/)
  gsub_file "Gemfile", /^gem ["']propshaft["'].*$/, 'gem "sprockets-rails"'
  layout = "app/views/layouts/application.html.erb"
  if File.exist?(File.join(destination_root, layout))
    gsub_file layout, /stylesheet_link_tag :app\b/, 'stylesheet_link_tag "application"'
  end
  create_file "app/assets/config/manifest.js", <<~JS, skip: true
    //= link_tree ../images
    //= link_directory ../stylesheets .css
    //= link_tree ../../javascript .js
    //= link_tree ../../../vendor/javascript .js
  JS
elsif options[:asset_pipeline].to_s != "sprockets"
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

  # `--orm=active_record`: this gem registers itself as the app's generator ORM (`:thecore`,
  # ADR 0002), and devise:install writes `require "devise/orm/<that ORM>"`, which doesn't exist.
  generate "devise:install", "--orm=active_record"

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
  # No `cancan:ability`: app/models/ability.rb is written above, before anything boots.
  generate "erd:install"
end
