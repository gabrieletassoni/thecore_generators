source "https://rubygems.org"
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

# Specify your gem's dependencies in thecore_generators.gemspec.
gemspec

# The gemspec only depends on railties (see thecore_generators.gemspec for
# why); the test/dummy app used by the Rails::Generators::TestCase harness
# needs the full framework and a database to boot.
gem "rails", "~> 7.2"
gem "sqlite3"

# Rails 7.2's rails/test_unit/line_filtering.rb overrides Minitest::Test.run
# with a 2-arg signature (reporter, options); Minitest 6.x changed that
# method's arity (3 args), so an unconstrained `minitest` resolves to 6.x on
# any fresh `bundle install` (no committed Gemfile.lock -- see .gitignore)
# and blows up every test run with "wrong number of arguments (given 3,
# expected 1..2)" before a single test executes. Pin to the 5.x line Rails
# 7.2 actually supports; safe to drop once this gem moves to a Rails version
# with Minitest 6 support (e.g. Rails 8+, tracked for release/4).
gem "minitest", "~> 5.25"

# TEMPORARY (thecore_generators#4): booted into the test/dummy app purely to
# prove -- integration-level, not just "no file was written" -- that a model
# generated with no Api::/RailsAdmin:: concern (this ticket's whole point,
# ADR 0001 in the thecore repo) still gets working `json_attrs` and
# RailsAdmin navigation via the default modules these two gems register into
# ThecoreBackendCommons::DefaultModuleRegistry
# (gabrieletassoni/model_driven_api#5, gabrieletassoni/thecore_ui_rails_admin#7).
# Both are merged into their own release/3 branches but NOT YET published to
# RubyGems with that code (rubygems.org still shows model_driven_api 3.8.0
# and thecore_ui_rails_admin 3.7.0, both pre-merge) -- pin to release/3 via
# git sources, same pattern those two gems' own Gemfiles already use for
# their shared thecore_backend_commons dependency. Test/dev-only: this repo's
# own thecore_generators.gemspec runtime dependency stays railties-only: none
# of this is a gemspec change, and no host app installing thecore_generators
# picks any of this up.
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
gem "model_driven_api", github: "gabrieletassoni/model_driven_api", branch: "release/3"
gem "thecore_ui_rails_admin", github: "gabrieletassoni/thecore_ui_rails_admin", branch: "release/3"
# TEMPORARY, same reason as above one level down the chain:
# ThecoreBackendCommons::DefaultModuleRegistry (needed by both gems above) is
# merged into thecore_backend_commons's release/3 but not yet published
# either -- without pinning it explicitly here too, Bundler would resolve it
# from each gem's own gemspec constraint (model_driven_api: "~> 3.0",
# thecore_ui_rails_admin: ">= 3.4") against the last *published* release,
# which predates the registry. Remove this pin once all three gems ship real
# releases containing this code.
gem "thecore_backend_commons", github: "gabrieletassoni/thecore_backend_commons", branch: "release/3"
