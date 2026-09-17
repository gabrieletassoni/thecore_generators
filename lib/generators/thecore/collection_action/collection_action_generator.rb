require "rails/generators/named_base"
require "generators/thecore/atom_aware"
require "generators/thecore/companion_files"
require "generators/thecore/action_companion"

module Thecore
  module Generators
    # `rails generate thecore:collection_action NAME` (thecore_generators#21,
    # per ADR 0006 in the thecore repo) — the third sibling to
    # RootActionGenerator/MemberActionGenerator. Unlike those two, there is
    # no prior thecore_code_extension JS command this ports (no
    # `addCollectionAction.js` ever existed — collection_actions were only
    # ever audited by check_practices, never generated), so its own
    # `templates/action.rb.tt` deliberately mirrors RootActionGenerator's
    # simplicity (a minimal GET/JSON example with an ActivityLogChannel
    # broadcast) rather than the real, more complex hand-written
    # `save_filters.rb`/`load_filters.rb` pattern already living in
    # thecore_ui_rails_admin — a generator's starter template exists to be
    # customized from a simple base, not to demonstrate every RailsAdmin
    # :collection feature.
    #
    # Structurally identical to RootActionGenerator/MemberActionGenerator:
    # same three includes, same thin task-method sequence (see
    # ActionCompanion's own comment for why those can't be shared further),
    # only `action_kind` and this class's own templates differ. No changes
    # needed anywhere in AtomAware/CompanionFiles/ActionCompanion —
    # `action_kind "collection_action"` alone is enough for placement
    # (lib/collection_actions or config/collection_actions),
    # pluralization, and validation wording to fall out correctly.
    class CollectionActionGenerator < Rails::Generators::NamedBase
      include Thecore::Generators::AtomAware
      include Thecore::Generators::CompanionFiles
      include Thecore::Generators::ActionCompanion

      action_kind "collection_action"

      source_root File.expand_path("templates", __dir__)

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
