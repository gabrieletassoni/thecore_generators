# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [File.expand_path("../test/dummy/db/migrate", __dir__)]
require "rails/test_help"
require "rails/generators/test_case"

# The real `rails generate`/`rails destroy` commands populate
# Rails::Generators.options/aliases from config.generators via
# Rails.application.load_generators (see
# rails/commands/generate/generate_command.rb, rails/command/actions.rb) —
# this is what lets a generator's `class_option :migration, type: :boolean`
# (declared with no explicit :default) resolve its default from
# `config.app_generators.orm :thecore, migration: true, timestamps: true`.
# Rails::Generators::TestCase never goes through that command layer, so
# without this, `options[:migration]`/`options[:timestamps]` would
# permanently bake in `nil` the moment a generator file is first required
# (class_option's default is computed once, at class-definition time) —
# silently skipping migration file creation in every test. Must run before
# any test file requires a generators/thecore/**/*_generator.rb file.
Rails.application.load_generators

# Mirrors the load_generators call above, for the same reason: a real `rails
# thecore:check_practices` invocation goes through Rails' command layer,
# which calls this itself before running any rake task (registering every
# Railtie's `rake_tasks` block, thecore_generators#13's `check_practices`
# task included) - Rails::Generators::TestCase-style in-process tests never
# go through that layer, so it must be triggered explicitly here, once, for
# every test file that invokes Rake::Task["thecore:check_practices"].
require "rake"
Rails.application.load_tasks
