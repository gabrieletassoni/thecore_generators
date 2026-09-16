require "rails/generators/named_base"
require "generators/thecore/atom_aware"
require "generators/thecore/companion_files"
require "generators/thecore/action_companion"

module Thecore
  module Generators
    # `rails generate thecore:member_action NAME` — a Ruby port of
    # thecore_code_extension's addMemberAction.js (thecore_generators#12),
    # the Member Action counterpart to RootActionGenerator
    # (thecore_generators#11). Shares the entire generator step sequence and
    # placement/naming logic with it via Thecore::Generators::ActionCompanion
    # (see that module and RootActionGenerator's own comment) — only this
    # class's own `templates/action.rb.tt`/`action.html.erb.tt`/
    # `action.js.tt` are Member-specific: the RailsAdmin `:member` action
    # type and its XHR + form PATCH example, matching what
    # `addMemberAction.js` produces today (not unified with Root's fetch +
    # ActionCable-broadcast template).
    #
    # Discovered automatically by Rails::Generators' own namespace-by-path
    # convention (`generators/thecore/member_action/member_action_generator.rb`
    # → "thecore:member_action") — no Railtie registration needed, same as
    # RootActionGenerator.
    class MemberActionGenerator < Rails::Generators::NamedBase
      include Thecore::Generators::AtomAware
      include Thecore::Generators::CompanionFiles
      include Thecore::Generators::ActionCompanion

      action_kind "member_action"

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
