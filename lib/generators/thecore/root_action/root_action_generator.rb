require "rails/generators/named_base"
require "generators/thecore/atom_aware"
require "generators/thecore/companion_files"
require "generators/thecore/action_companion"

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
    #
    # The full generator step sequence (validate → create_action_file →
    # create_view_js_scss_companions → add_after_initialize_require →
    # add_assets_precompile_line → add_locale_entries) and everything about
    # placement/naming lives in Thecore::Generators::ActionCompanion, shared
    # with MemberActionGenerator (thecore_generators#12) — only this class's
    # own `templates/action.rb.tt`/`action.html.erb.tt`/`action.js.tt` (the
    # RailsAdmin `:root` action type and its fetch + ActionCable-broadcast
    # example) are Root-specific.
    class RootActionGenerator < Rails::Generators::NamedBase
      include Thecore::Generators::AtomAware
      include Thecore::Generators::CompanionFiles
      include Thecore::Generators::ActionCompanion

      action_kind "root_action"

      source_root File.expand_path("templates", __dir__)

      # Thin task methods, required on each class directly (see
      # ActionCompanion's own comment for why) - each delegates to shared
      # private logic there.
      def validate_action_name!
        validate_action_name_for_kind!
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
    end
  end
end
