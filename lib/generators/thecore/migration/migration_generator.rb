require "rails/generators/active_record/migration/migration_generator"
require "generators/thecore/atom_aware"

module Thecore
  module Generators
    # Resolved automatically by plain `rails generate migration` once
    # ThecoreGenerators::Railtie registers `config.app_generators.orm
    # :thecore, ...` (namespace "thecore:migration" — see
    # Thecore::Generators::ModelGenerator for the namespace-resolution
    # mechanism, identical here).
    #
    # A pure wrap: 100% of ActiveRecord::Generators::MigrationGenerator's
    # migration-content logic (add/remove/create-table detection, attribute
    # parsing, templates) is inherited untouched. The only addition is
    # Thecore::Generators::AtomAware, redirecting the migration file into an
    # ATOM's db/migrate when one is detected from `Dir.pwd`/`--atom=NAME`, so
    # `rails generate migration AddBarToFoo bar:string` gets the same
    # context-aware placement standalone, not just via `rails generate model`.
    class MigrationGenerator < ActiveRecord::Generators::MigrationGenerator
      include Thecore::Generators::AtomAware

      source_root ActiveRecord::Generators::MigrationGenerator.source_root
    end
  end
end
