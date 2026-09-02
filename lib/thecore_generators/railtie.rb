require "rails/railtie"

module ThecoreGenerators
  # Hooks `rails generate model`/`rails generate migration` the same way
  # ActiveRecord's own Railtie does (`config.app_generators.orm :active_record,
  # migration: true, timestamps: true` in active_record/railtie.rb) and Mongoid
  # does for its own ORM. Registering this at the class body level — not inside
  # an `initializer` block — matters: `config.app_generators` is a process-wide
  # singleton (`Rails::Railtie::Configuration#app_generators`) copied into
  # `Rails::Generators.options` early during boot, so this must run at require
  # time, exactly mirroring ActiveRecord's own placement, to reliably win by
  # require order (see docs/adr/0002-thecore-generators-gem-and-generator-hook-mechanism.md
  # in the thecore repo).
  #
  # This makes plain `rails generate model`/`rails generate migration` resolve
  # to Thecore::Generators::ModelGenerator/MigrationGenerator (namespaces
  # "thecore:model"/"thecore:migration") instead of ActiveRecord's own
  # generators, with zero new command vocabulary for developers.
  # `rails generate active_record:model`/`active_record:migration` remain
  # available directly as an escape hatch — Rails only hides the override from
  # `--help`, it never blocks direct namespace invocation.
  class Railtie < ::Rails::Railtie
    config.app_generators.orm :thecore, migration: true, timestamps: true
  end
end
