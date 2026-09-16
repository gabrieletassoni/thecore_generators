module Thecore
  module Generators
    # Shared helper logic for Thecore's own per-action generators
    # (RootActionGenerator - thecore_generators#11, MemberActionGenerator -
    # thecore_generators#12): everything about them that is NOT the action
    # file's own RailsAdmin action type/template content, and not a Thor
    # *task* method itself.
    #
    # Thor::Group (which Rails::Generators::Base/NamedBase extends)
    # discovers its task list via a `method_added` hook that only fires for
    # methods defined directly, via `def`, in the generator class's own
    # body - never for methods a class merely picks up through `include`.
    # So each of `validate_action_name!`/`create_action_file`/
    # `create_view_js_scss_companions`/`add_after_initialize_require`/
    # `add_assets_precompile_line`/`add_locale_entries` must still be a
    # thin method defined directly on RootActionGenerator/
    # MemberActionGenerator themselves (identical one-liners in both); only
    # the private logic those methods delegate to lives here.
    #
    # Extracted once both generators existed and turned out identical apart
    # from that thin task-method layer and their directory name
    # ("root_actions"/"member_actions") - not a speculative abstraction
    # built ahead of a second user.
    #
    # The including class must declare `action_kind "root_action"` (or
    # `"member_action"`) at the class body level, which derives both the
    # directory name (pluralized: "root_actions"/"member_actions") and the
    # wording used in the name-validation error message.
    module ActionCompanion
      def self.included(base)
        base.extend(ClassMethods)
      end

      # A class-level accessor, not an instance `define_method`, and
      # deliberately so: any *instance* method this DSL defined directly on
      # the including generator class - even a private one, since Thor's
      # `method_added` hook fires and registers it as a task at the moment
      # `define_method` returns, before a later `private` call could demote
      # it - would itself become a spurious Thor task (this was tried and
      # caught via `RootActionGenerator.all_tasks.keys` including
      # "action_kind" as an actual, if harmless, generator step). Storing
      # the value in a class-level ivar instead, read back via
      # `self.class.action_kind` from the private instance methods below,
      # adds no method to the generator class's own instance side at all.
      module ClassMethods
        def action_kind(value = nil)
          @action_kind = value unless value.nil?
          @action_kind
        end
      end

      private

      def validate_action_name_for_kind!
        return if name.match?(/\A[a-z_][a-z0-9_]*\z/)

        raise Thor::Error,
          "'#{name}' is not a valid #{self.class.action_kind.tr("_", " ")} name - use " \
          "snake_case, starting with a lowercase letter or underscore (a leading digit would " \
          "make the generated `topic: :#{name}` symbol invalid Ruby)."
      end

      def action_dir_name
        "#{self.class.action_kind}s"
      end

      # lib/<action_dir_name> in ATOM context (on the load path via the
      # gemspec), config/<action_dir_name> in host-app context (not on the
      # load path, hence the full-path require in `require_line` below) -
      # see docs/adr/0001-main-app-actions-live-in-config.md in
      # thecore_code_extension.
      def action_file_path
        base_dir = atom_dir ? "lib" : "config"
        File.join(base_dir, action_dir_name, "#{file_name}.rb")
      end

      def require_line
        if atom_dir
          "require '#{action_dir_name}/#{file_name}'"
        else
          "require Rails.root.join('config', '#{action_dir_name}', '#{file_name}').to_s"
        end
      end

      def assets_precompile_line
        "Rails.application.config.assets.precompile += %w( rails_admin/actions/#{file_name}.js " \
          "rails_admin/actions/#{file_name}.css )"
      end

      def action_name_camel_case
        file_name.downcase.gsub(/[-_]([a-z0-9])/) { Regexp.last_match(1).upcase }
      end

      def title_case_name
        file_name.split("_").map(&:capitalize).join(" ")
      end
    end
  end
end
