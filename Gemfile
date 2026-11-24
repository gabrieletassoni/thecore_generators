source "https://rubygems.org"
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

# Specify your gem's dependencies in thecore_generators.gemspec.
gemspec

# The gemspec only depends on railties (see thecore_generators.gemspec for
# why); the test/dummy app used by the Rails::Generators::TestCase harness
# needs the full framework and a database to boot. PostgreSQL is the only DB
# target of every Thecore gem and host app, so the dummy app runs on it too
# (see test/dummy/config/database.yml and boot.rb) -- never SQLite.
#
# The Rails line this suite runs on (Odoo #6091, ADR 0033 in mytask-imas): Rails 8.1, the only
# one CI tests, so `rails plugin new` in the thecore:atom tests generates 8.1 ATOMs. Dual support
# is best effort: `RAILS_VERSION=7.2 bundle update rails && RAILS_VERSION=7.2 bundle exec rake test`
# runs the suite on 7.2.4 locally. Both lines are pinned because a fresh resolution otherwise
# drifts (no committed Gemfile.lock -- see .gitignore).
RAILS_LINE = ENV["RAILS_VERSION"] == "7.2" ? ["~> 7.2.4"] : ["~> 8.1", ">= 8.1.4.1"]
gem "rails", *RAILS_LINE
gem "pg"

# Rails 7.2's rails/test_unit/line_filtering.rb overrides Minitest::Test.run with a 2-arg
# signature (reporter, options); Minitest 6.x changed that method's arity (3 args), so on 7.2
# every test run blows up with "wrong number of arguments (given 3, expected 1..2)". Kept on 5.x
# on both lines, like the other ATOMs' suites.
gem "minitest", "~> 5.25"

# Booted into the test/dummy app purely to prove -- integration-level, not
# just "no file was written" -- that a model generated with no Api::/
# RailsAdmin:: concern (ADR 0001 in the thecore repo) still gets working
# `json_attrs` and RailsAdmin navigation via the default modules these two
# gems register into ThecoreBackendCommons::DefaultModuleRegistry
# (model_driven_api >= 3.9.0, thecore_ui_rails_admin >= 3.8.0; both published,
# resolved normally from RubyGems -- no pin needed). Test/dev-only: this
# repo's own thecore_generators.gemspec runtime dependency stays
# railties-only; no host app installing thecore_generators picks any of
# this up.
#
# Deliberately NOT wrapped in `group :test do ... end`: test/dummy/config/
# application.rb preloads a `User`/`Ability` that need Devise/CanCan (pulled
# in transitively below) at *require* time, and `rails/tasks/engine.rake`
# (loaded by this gem's own Rakefile for `rails` task delegation) requires
# test/dummy/config/application.rb without RAILS_ENV set to "test" -- so
# `Bundler.require(*Rails.groups)` would resolve to the "development" group
# at that point and skip anything scoped to `:test`, breaking `rake` itself
# before any test file even runs. Plain (default-group) entries are required
# unconditionally regardless of `Rails.env`, same as every other gem below.
gem "model_driven_api", "~> 3.13", ">= 3.13.2" # 3.13.2: JSON with include: on Rails 8.1
gem "thecore_ui_rails_admin", "~> 3.8"

# JUnit XML report in CI (test/support/junit_report.rb, only when JUNIT_REPORT_DIR is set).
gem "minitest-reporters", "~> 1.8"
