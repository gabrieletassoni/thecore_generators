require "rails/generators/named_base"
require "generators/thecore/atom_aware"
require "generators/thecore/companion_files"

module Thecore
  module Generators
    # `rails generate thecore:root_action NAME` — a Ruby port of
    # thecore_code_extension's addRootAction.js (thecore_generators#11),
    # producing the same end result from a terminal: the RailsAdmin root
    # action file, its view/JS/SCSS companions, the after_initialize.rb
    # require line, the assets.rb precompile line, and locale entries — with
    # ATOM-aware placement via the same Thecore::Generators::AtomAware
    # mechanism the Model/Migration generators already use.
    #
    # Discovered automatically by Rails::Generators' own namespace-by-path
    # convention (this file's path derives the "thecore:root_action"
    # namespace) — no Railtie registration needed, unlike
    # ModelGenerator/MigrationGenerator, since there is no built-in Rails
    # generator being overridden here.
    #
    # Unlike ModelGenerator/MigrationGenerator, Thecore::Generators::AtomAware
    # only supplies `atom_dir`/`host_app_root` and the `--atom` option here —
    # this generator does not override `destination_root` placement for a
    # single fixed subpath the way Model/Migration's templates do, because the
    # action file itself lives at a *different* relative path depending on
    # context (ATOM: lib/root_actions/, host app: config/root_actions/ — see
    # docs/adr/0001-main-app-actions-live-in-config.md in
    # thecore_code_extension for why the host-app side avoids lib/). AtomAware
    # still redirects `destination_root` into the ATOM dir when one is
    # detected, so the view/JS/SCSS/locale/after_initialize/assets companions
    # (fixed relative paths, shared with the host-app case) land in the right
    # place automatically.
    class RootActionGenerator < Rails::Generators::NamedBase
      include Thecore::Generators::AtomAware
      include Thecore::Generators::CompanionFiles

      source_root File.expand_path("templates", __dir__)

      def validate_action_name!
        return if name.match?(/\A[a-z_][a-z0-9_]*\z/)

        raise Thor::Error,
          "'#{name}' is not a valid root action name - use snake_case, starting with a " \
          "lowercase letter or underscore (a leading digit would make the generated " \
          "`topic: :#{name}` symbol invalid Ruby)."
      end

      def create_action_file
        template "action.rb.tt", action_file_path
      end

      def create_view_js_scss_companions
        render_view_js_scss_companions!
      end

      def add_after_initialize_require
        ensure_after_initialize_require!(require_line)
      end

      def add_assets_precompile_line
        ensure_assets_precompile_line!(assets_precompile_line)
      end

      def add_locale_entries
        write_action_locale_entries!(file_name, title_case_name)
      end

      private

      # lib/root_actions in ATOM context (on the load path via the gemspec),
      # config/root_actions in host-app context (not on the load path, hence
      # the full-path require in `require_line` below) — see
      # docs/adr/0001-main-app-actions-live-in-config.md.
      def action_file_path
        base_dir = atom_dir ? "lib" : "config"
        File.join(base_dir, "root_actions", "#{file_name}.rb")
      end

      def require_line
        if atom_dir
          "require 'root_actions/#{file_name}'"
        else
          "require Rails.root.join('config', 'root_actions', '#{file_name}').to_s"
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
