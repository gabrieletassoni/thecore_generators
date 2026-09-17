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
# ADR 0001 (thecore repo) requires model_driven_api >= 3.9.0 / thecore_ui_rails_admin
# >= 3.8.0 for the DefaultModuleRegistry default-concern behavior this whole ecosystem
# now relies on -- matching the floor this gem's own Gemfile already pins to (see its
# comment), not an arbitrary choice.
gem "model_driven_api", "~> 3.9"
gem "thecore_ui_rails_admin", "~> 3.8"
gem "rails-erd", group: :development

# thecore_generators itself is dev-tooling only (it hooks `rails g model`/`migration`,
# see ADR 0002 in the thecore repo) — never a runtime dependency, so it goes in the
# :development group. A single-line `group:` option is equivalent to (and simpler
# than) createApp.js's manual `group :development do ... end` block insertion.
gem "thecore_generators", "~> 3.6", group: :development

# --- Optional ecosystem gems, discoverable but off by default ---------------
# Same "commented but documented" philosophy as the devcontainer's gh/glab CLI
# mounts (ADR 0005): each of these publishes to RubyGems.org (see thecore's own
# CLAUDE.md) but isn't needed by every app, so it starts commented out with a
# one-line description — uncomment only the ones this project actually needs.
append_to_file "Gemfile", <<~RUBY

  # The rest of the generic Thecore ecosystem — uncomment only what you need.
  # gem "thecore_auth_commons", "~> 3.0" # Role/permission/predicate models and authorization scaffolding
  # gem "thecore_settings", "~> 3.0" # ThecoreSettings key/value configuration store
  # gem "thecore_print_commons", "~> 3.0" # Shared PDF/print generation helpers
  # gem "thecore_background_jobs", "~> 3.0" # Shared background job scheduling helpers
  # gem "thecore_ui_commons", "~> 3.0" # Shared UI helpers/components for the admin frontend
  # gem "thecore_tcp_debug", "~> 3.0" # TCP-level debugging/diagnostics support
  # gem "thecore_download_documents", "~> 3.0" # Document download support
  # gem "thecore_dataentry_commons", "~> 3.0" # Shared data-entry UI helpers
  # gem "thecore_connectors" # Helpers for connecting to external systems/data sources
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
# NOTE: this default URL only serves real content once `thecore`'s `master`
# carries the commits that added `samples/CLAUDE.md`/`samples/.gitlab-ci.yml`
# and brought `samples/devcontainer/` up to date (thecore#14/#15) — as of this
# gem's own 3.8.0 release those commits exist only in a local checkout, not
# pushed to `origin/master` yet. Until they're pushed, the default URL 404s for
# `.gitlab-ci.yml`/`CLAUDE.md`/the two devcontainer scripts and serves stale
# content for `devcontainer.json`/`docker-compose.yml`. This is an operational
# sequencing issue (push `thecore` before relying on the default in production),
# not a defect in this code — but it means `THECORE_SAMPLES_SOURCE` pointed at a
# local clone of `thecore` is the only way to exercise the real default content
# today.
#
# Every write below is unconditional (`force: true`, no interactive prompt).
# Of the six `.devcontainer/*` files, four (`devcontainer.json`,
# `docker-compose.yml`, `Dockerfile`, `create-db-user.sql`) are expected to
# already exist, written by the separate, prior "Setup Devcontainer" bootstrap
# step this template runs inside of (verified directly against that command's
# source, `thecore_code_extension/commands/setupDevContainer.js`) — replacing
# them is the whole point, not a conflict to ask about. The other two
# (`link-host-home.sh`/`check-plugins.sh`) are *not* written by that step at
# all — genuinely new files here, not overwrites — but `force: true` is harmless
# for a new file and keeps every write in this block uniform.
# `.gitlab-ci.yml`/`CLAUDE.md` don't exist yet in the documented flow either,
# but stay unconditional too so re-running this template later
# (`bin/rails app:template`) is a clean overwrite, not a prompt.
#
# A fetch failure (today: the 404s above; going forward: any network blip, or
# `thecore` reorganizing `samples/`) aborts the whole template with a clear,
# specific message instead of continuing into a silently half-scaffolded app
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

%w[devcontainer.json docker-compose.yml Dockerfile create-db-user.sql link-host-home.sh check-plugins.sh].each do |file|
  fetch_thecore_sample("devcontainer/#{file}", ".devcontainer/#{file}")
end
# `get`/`create_file` only write content, never permissions — the executable bit
# has to be restored explicitly for the two scripts (`thecore/samples/devcontainer/`
# stores them executable, but that's lost the moment their bytes cross an HTTP
# fetch or a plain `File.read`).
chmod ".devcontainer/link-host-home.sh", 0o755
chmod ".devcontainer/check-plugins.sh", 0o755

fetch_thecore_sample(".gitlab-ci.yml", ".gitlab-ci.yml")
fetch_thecore_sample("CLAUDE.md", "CLAUDE.md")

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

run_setup_now = yes?(
  "Run `bundle install` and the standard installer generators (devise, rails_admin, " \
  "active_storage, action_text, action_mailbox, cancan, erd) now? (y/n)"
)

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
