require "rails/generators/active_record/migration/migration_generator"
require "generators/thecore/atom_aware"
require "generators/thecore/association_wiring"

module Thecore
  module Generators
    # Resolved automatically by plain `rails generate migration` once
    # ThecoreGenerators::Railtie registers `config.app_generators.orm
    # :thecore, ...` (namespace "thecore:migration" — see
    # Thecore::Generators::ModelGenerator for the namespace-resolution
    # mechanism, identical here).
    #
    # 100% of ActiveRecord::Generators::MigrationGenerator's migration-content
    # logic (add/remove/create-table detection, attribute parsing, templates)
    # is inherited untouched. On top of that:
    #   - Thecore::Generators::AtomAware redirects the migration file into an
    #     ATOM's db/migrate when one is detected from `Dir.pwd`/`--atom=NAME`,
    #     so `rails generate migration AddBarToFoo bar:string` gets the same
    #     context-aware placement standalone, not just via `rails generate
    #     model`.
    #   - Thecore::Generators::AssociationWiring detects `references`
    #     attributes and writes the missing inverse `has_many`/`has_one` side
    #     into the target model's concern (ADR 0003 in the thecore repo).
    class MigrationGenerator < ActiveRecord::Generators::MigrationGenerator
      include Thecore::Generators::AtomAware
      include Thecore::Generators::AssociationWiring

      source_root ActiveRecord::Generators::MigrationGenerator.source_root

      def create_migration_file
        super
        wire_inverse_associations_from_references
      end
    end
  end
end
