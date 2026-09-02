require "rails/generators/active_record/model/model_generator"
require "generators/thecore/atom_aware"
require "generators/thecore/association_wiring"

module Thecore
  module Generators
    # Resolved automatically by plain `rails generate model` once
    # ThecoreGenerators::Railtie registers `config.app_generators.orm
    # :thecore, ...` (namespace "thecore:model", derived from this class's
    # own module nesting the same way ActiveRecord::Generators::ModelGenerator
    # resolves to "active_record:model" — see Rails::Generators::Base#namespace).
    #
    # Wraps (does not reimplement) ActiveRecord's own model generator: all
    # attribute parsing, the model/module templates, and migration-content
    # generation are inherited as-is. On top of that:
    #   - Thecore::Generators::AtomAware redirects placement into an ATOM's
    #     app/models + db/migrate when one is detected (see its own docs).
    #   - `Api::ModelName`/`RailsAdmin::ModelName` concern files are
    #     generated and `include`d into the model, replicating
    #     thecore_code_extension's addModel.js templates exactly (unchanged
    #     by this ticket — see thecore_generators#3 / ADR 0001 in the thecore
    #     repo).
    #   - `Endpoints::ModelName` is deliberately NOT generated (ADR 0001: it's
    #     never `include`d by default; add it by hand, following the
    #     after_initialize + class_eval pattern, only when a real custom
    #     action is needed).
    #   - Test file generation is never suppressed (no `--skip-test-framework`
    #     equivalent) — `hook_for :test_framework` runs exactly as it does for
    #     `active_record:model`.
    #   - Thecore::Generators::AssociationWiring detects `references`
    #     attributes and writes the missing inverse `has_many`/`has_one` side
    #     into the target model's concern (ADR 0003 in the thecore repo) —
    #     needed here too, not just in MigrationGenerator, because
    #     `rails generate model Foo x:references` creates its migration via
    #     ActiveRecord::Generators::ModelGenerator#create_migration_file, a
    #     different method than MigrationGenerator's own.
    class ModelGenerator < ActiveRecord::Generators::ModelGenerator
      include Thecore::Generators::AtomAware
      include Thecore::Generators::AssociationWiring

      # `source_root` (singular) must be set explicitly: Rails::Generators::Base's
      # auto-computed `default_source_root` derives its path from *this*
      # class's own base_name/generator_name ("thecore"/"model"), which
      # doesn't exist on disk — so it silently resolves to nil unless
      # pointed at ActiveRecord's own directory here. Our own
      # api_concern.rb.tt/rails_admin_concern.rb.tt templates live alongside
      # this file and are added to `source_paths` (plural) separately, since
      # `source_root` only holds one path.
      source_paths.unshift(File.expand_path("templates", __dir__))
      source_root ActiveRecord::Generators::ModelGenerator.source_root

      def create_model_file
        super
        add_default_concerns
      end

      def create_migration_file
        super
        wire_inverse_associations_from_references
      end

      private

      # Faithful Ruby port of addModel.js's api_concern.rb/rails_admin_concern.rb
      # templates and its `include Api::X` / `include RailsAdmin::X` model-file
      # rewrite — down to the exact generated content — per this ticket's
      # explicit "unchanged, still generated exactly as today" scope (that
      # removal is thecore_generators#6, gated on other work landing first).
      def add_default_concerns
        template "api_concern.rb", File.join("app/models/concerns/api", class_path, "#{file_name}.rb")
        template "rails_admin_concern.rb", File.join("app/models/concerns/rails_admin", class_path, "#{file_name}.rb")

        include_default_concerns_in_model
      end

      def include_default_concerns_in_model
        model_file = File.join("app/models", class_path, "#{file_name}.rb")
        simple_class_name = class_name.split("::").last

        insert_into_file(
          model_file,
          "  include Api::#{class_name}\n  include RailsAdmin::#{class_name}\n",
          after: /class #{Regexp.escape(simple_class_name)} < .*\n/
        )
      end
    end
  end
end
