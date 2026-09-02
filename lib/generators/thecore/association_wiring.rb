require "generators/thecore/workspace_context"

module Thecore
  module Generators
    # Implements ADR 0003 in the thecore repo
    # (docs/adr/0003-migration-driven-inverse-association-wiring.md):
    # Rails' own migration generator only ever wires the owning (`belongs_to`)
    # side of a `references`/`add_reference` column — the inverse
    # (`has_many`/`has_one`) has always been manual. This module detects
    # `references` attributes on the migration being generated and writes the
    # missing inverse side into the *target* model's canonical per-model
    # concern, following the cross-ATOM extension pattern GUIDE.md §4.5
    # already documents (`config/initializers/concern_<model>.rb` plus a
    # `TargetModel.send(:include, ...)` registered in
    # `config/initializers/after_initialize.rb`).
    #
    # Included by both Thecore::Generators::MigrationGenerator (standalone
    # `rails generate migration ... x:references`) and
    # Thecore::Generators::ModelGenerator (`rails generate model Foo
    # x:references` delegates its own migration creation to
    # ActiveRecord::Generators::ModelGenerator#create_migration_file, a
    # *different* method than MigrationGenerator's own, so both host classes
    # need their own hook). Both wire it the same way: override
    # `create_migration_file`, call `super`, then
    # `wire_inverse_associations_from_references` — matching the
    # override-and-call-super style Thecore::Generators::ModelGenerator
    # already uses for `create_model_file`/`add_default_concerns`.
    #
    # Requires the includer to already provide (directly or via
    # Thecore::Generators::AtomAware, included by both host classes):
    #   - `attributes` — Rails::Generators::GeneratedAttribute array (from
    #     ActiveRecord's own migration/model generator `argument`)
    #   - `table_name` — Rails::Generators::NamedBase; memoized into
    #     @table_name, which for MigrationGenerator is populated by
    #     ActiveRecord's own `set_local_assigns!` (run during `super`) from
    #     the migration's file name (`add_x_to_y`/`create_y`), and for
    #     ModelGenerator resolves directly from the model's own class name -
    #     either way it names the table/model *gaining* the reference.
    #   - `destination_root`/`host_app_root` — Thecore::Generators::AtomAware
    module AssociationWiring
      HEADER_COMMENT = <<~RUBY.freeze
        # This file is maintained by thecore_generators (migration generator's
        # inverse-association wiring - see
        # docs/adr/0003-migration-driven-inverse-association-wiring.md in the
        # thecore repo). Associations below are appended automatically whenever
        # a `references` column targeting this model is added elsewhere.
        # Do not hand-edit the generated section: a future generator run may
        # append to it again, and hand edits are not accounted for.
      RUBY

      AFTER_INITIALIZE_TEMPLATE = <<~RUBY.freeze
        Rails.application.configure do
            config.after_initialize do
            end
        end
      RUBY

      def self.included(base)
        base.class_option :non_interactive, type: :boolean, default: false,
          desc: "Skip the inverse-association cardinality prompt and default to has_many " \
                "(no real TTY is available to CI or scripted invocations, e.g. the VS Code " \
                "extension)"
      end

      private

      # Entry point, called after `super` from the includer's own
      # `create_migration_file` override.
      def wire_inverse_associations_from_references
        return if options[:migration] == false # ModelGenerator's --no-migration
        return if attributes.nil?

        owning_table_name = table_name
        return if owning_table_name.blank?

        reference_attributes = attributes.select(&:reference?)
        return if reference_attributes.empty?

        reference_attributes.each { |attribute| wire_inverse_association(owning_table_name, attribute) }
      end

      def wire_inverse_association(owning_table_name, attribute)
        target_class_name = attribute.singular_name.camelize
        cardinality = prompt_cardinality_for(target_class_name)
        return if cardinality == :skip

        association_line = association_line_for(cardinality, owning_table_name)
        write_target_concern(target_class_name, association_line)
        register_after_initialize(target_class_name)
        log_cross_boundary_dependency(target_class_name)
      end

      def association_line_for(cardinality, owning_table_name)
        if cardinality == :has_one
          "has_one :#{owning_table_name.singularize}"
        else
          "has_many :#{owning_table_name}"
        end
      end

      def prompt_cardinality_for(target_class_name)
        return :has_many unless interactive_association_prompt?

        answer = ask(
          "Inverse association on #{target_class_name} for this reference " \
          "(has_many/has_one/skip)?",
          default: "has_many",
          limited_to: %w[has_many has_one skip]
        )
        answer.to_s.strip.to_sym
      end

      # No real TTY is present for CI/scripted/extension invocations (or the
      # includer was explicitly told not to prompt via --non-interactive) -
      # default straight to has_many, per ADR 0003.
      def interactive_association_prompt?
        !options[:non_interactive] && $stdin.tty? && $stdout.tty?
      end

      def concern_path_for(target_class_name)
        "config/initializers/concern_#{target_class_name.underscore}.rb"
      end

      def concern_module_name_for(target_class_name)
        "Concern#{target_class_name}"
      end

      def write_target_concern(target_class_name, association_line)
        concern_path = concern_path_for(target_class_name)

        if File.exist?(File.join(destination_root, concern_path))
          insert_association_into_existing_concern(concern_path, association_line)
        else
          create_concern_file(concern_path, concern_module_name_for(target_class_name), association_line)
        end
      end

      def create_concern_file(concern_path, concern_module_name, association_line)
        content = <<~RUBY
          #{HEADER_COMMENT}
          module #{concern_module_name}
            extend ActiveSupport::Concern

            included do
              #{association_line}
            end
          end
        RUBY

        create_file(concern_path, content)
      end

      def insert_association_into_existing_concern(concern_path, association_line)
        full_path = File.join(destination_root, concern_path)
        content = File.read(full_path)

        if content.match?(/^\s*#{Regexp.escape(association_line)}\s*$/)
          say_status :skip, "#{concern_path} already has `#{association_line}`", :blue
          return
        end

        insert_into_file(concern_path, "    #{association_line}\n", after: /included do\n/)
      end

      def register_after_initialize(target_class_name)
        path = "config/initializers/after_initialize.rb"
        full_path = File.join(destination_root, path)

        create_file(path, AFTER_INITIALIZE_TEMPLATE) unless File.exist?(full_path)

        registration_line = "#{target_class_name}.send(:include, #{concern_module_name_for(target_class_name)})"
        content = File.read(full_path)
        return if content.include?(registration_line)

        insert_into_file(path, "        #{registration_line}\n", after: /config\.after_initialize do\n/)
      end

      # Cross-boundary case (ADR 0003): the concern always lives in the
      # invoking app/ATOM (destination_root), never the target model's own -
      # so when the target model actually lives elsewhere, the generated
      # `TargetModel.send(:include, ...)` line depends on that model's
      # constant being loaded, which requires a real gem/path dependency a
      # human has to add. We only log it — never edit a gemspec/Gemfile.
      def log_cross_boundary_dependency(target_class_name)
        target_root = Thecore::Generators::WorkspaceContext.model_root_for(
          class_name: target_class_name, app_root: host_app_root
        )
        return if target_root.nil? || target_root == destination_root

        own_is_atom = destination_root != host_app_root
        target_is_atom = target_root != host_app_root
        own_label = own_is_atom ? File.basename(destination_root) : "the host app"
        target_label = target_is_atom ? File.basename(target_root) : "the host app"

        message = "Cross-boundary reference: #{target_class_name} lives in #{target_label}, but the " \
          "generated concern was written into #{own_label} (ADR 0003: the concern always lives in the " \
          "invoking app/ATOM). #{dependency_hint(own_is_atom, target_is_atom, target_root)}"

        say_status :dependency, message, :yellow
      end

      def dependency_hint(own_is_atom, target_is_atom, target_root)
        target_gem_name = File.basename(target_root)

        if own_is_atom && target_is_atom
          "Add a gem dependency in this ATOM's gemspec, e.g.: spec.add_dependency \"#{target_gem_name}\""
        elsif !own_is_atom && target_is_atom
          "Add a Gemfile dependency in the host app, e.g.: gem \"#{target_gem_name}\", " \
            "path: \"vendor/submodules/#{target_gem_name}\""
        else
          "The target model lives in the host app; confirm this ATOM is meant to reference host-app " \
            "code directly (no gemspec/Gemfile dependency line applies here)."
        end
      end
    end
  end
end
