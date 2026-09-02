require "generators/thecore/workspace_context"

module Thecore
  module Generators
    # Shared by Thecore::Generators::ModelGenerator and MigrationGenerator:
    # redirects file placement into an ATOM directory when
    # Thecore::Generators::WorkspaceContext detects one (from `Dir.pwd` or an
    # explicit `--atom=NAME`), and otherwise leaves the wrapped ActiveRecord
    # generator's own placement (relative to `destination_root`, already the
    # host app root for a real `rails generate` invocation) untouched.
    #
    # Two distinct placement mechanisms need covering, since ActiveRecord's
    # generators don't derive both from `destination_root`:
    #   - Model/module/test files are `template`d at paths relative to
    #     `destination_root` — overriding `destination_root` itself (in
    #     `initialize`) redirects all of these, including the file the
    #     inherited `hook_for :test_framework` generates, since Thor's
    #     `_shared_configuration` passes the (already-overridden)
    #     `destination_root` on to hooked generators automatically.
    #   - The migration file's directory instead comes from
    #     `ActiveRecord::Generators::Migration#db_migrate_path`, computed from
    #     `Rails.application.config.paths["db/migrate"]` — i.e. always the
    #     real app root, regardless of `destination_root`. This must be
    #     overridden separately.
    module AtomAware
      def self.included(base)
        base.class_option :atom, type: :string, default: nil,
          desc: "Explicit ATOM name (under vendor/submodules/) to target, overriding cwd-based detection"
      end

      def initialize(*args)
        super
        @host_app_root = destination_root
        self.destination_root = atom_dir if atom_dir
      end

      # The true host-app root, captured before `destination_root` is
      # (possibly) overridden above — for a real `rails generate` invocation
      # this is `Rails::Command.root`, in tests whatever
      # `Rails::Generators::TestCase` configured as `destination_root`.
      # Unlike `destination_root` (which becomes the ATOM dir once
      # overridden), this always stays the app root, giving
      # Thecore::Generators::WorkspaceContext.model_root_for a stable anchor
      # to search from regardless of where *this* invocation itself landed.
      attr_reader :host_app_root

      # The absolute ATOM directory this generator's files should land in, or
      # nil for plain host-app context. Resolved once, before
      # `destination_root` is (possibly) overridden above, since the
      # pre-override `destination_root` (== `host_app_root`) is the correct
      # app-root anchor for resolving an explicit `--atom=NAME`.
      def atom_dir
        return @atom_dir if @atom_dir_resolved

        @atom_dir_resolved = true
        @atom_dir = Thecore::Generators::WorkspaceContext.atom_dir_for(
          cwd: Dir.pwd,
          app_root: host_app_root,
          atom_name: options[:atom]
        )
      end

      private

      def db_migrate_path
        atom_dir ? File.join(atom_dir, "db", "migrate") : super
      end
    end
  end
end
