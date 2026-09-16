require "yaml"

module Thecore
  module Generators
    # Shared companion-file behavior for Thecore's own custom-action
    # generators: ensuring config/initializers/after_initialize.rb and
    # assets.rb exist and carry the right require/precompile line, and
    # writing the RailsAdmin action's locale entries. Introduced by
    # RootActionGenerator (thecore_generators#11) and reused as-is by
    # MemberActionGenerator (thecore_generators#12).
    #
    # Faithful Ruby port of the corresponding parts of thecore_code_extension's
    # addRootAction.js/addMemberAction.js: the after_initialize.rb/assets.rb
    # ensure-and-append logic, and the locale-entry merge behavior — broadened
    # per thecore_generators#11's acceptance criteria to write into every
    # *.yml file already present under the locales directory, not just
    # en.yml/it.yml (the JS original only ever touched those two).
    #
    # Deliberately duplicates (rather than shares) the after_initialize.rb
    # skeleton Thecore::Generators::AssociationWiring already writes — same
    # structure/anchor, so the two compose fine regardless of which one
    # happens to create the file first, but kept separate to avoid touching
    # already-shipped Phase 1 code for this ticket.
    module CompanionFiles
      AFTER_INITIALIZE_TEMPLATE = <<~RUBY.freeze
        Rails.application.configure do
            config.after_initialize do
            end
        end
      RUBY

      ASSETS_TEMPLATE = <<~RUBY.freeze
        # PLEASE, uncomment if needed.
        # For Example: in the case there's a root action called tcp_debug, add the following lines to include css and javascripts for auto loading:
        # Rails.application.config.assets.precompile += %w(
        #   main_tcp_debug.js
        #   main_tcp_debug.css
        # )
      RUBY

      private

      # Renders the shared view/JS/SCSS companion trio for a RailsAdmin
      # custom action (root or member) into the workspace's fixed
      # app/views/rails_admin/main, app/assets/javascripts/rails_admin/actions,
      # and app/assets/stylesheets/rails_admin/actions directories — the same
      # relative paths regardless of ATOM vs host-app context (only the
      # action's own controller-config file, handled by the including
      # generator, is placed differently: lib/root_actions vs
      # config/root_actions, and similarly for member actions).
      # Requires "action.html.erb.tt"/"action.js.tt"/"action.scss.tt" to be
      # present in the including generator's own source_paths. Takes no
      # argument deliberately: the template bodies themselves read the
      # including generator's own `file_name` (via NamedBase) through the ERB
      # binding `template` evaluates them in, so a separate action-name
      # argument here would only rename the destination files while the
      # content inside kept using `file_name` — a silent name/content
      # mismatch. Callers needing a different action name for content must
      # get there via their own `file_name`, not a parameter to this method.
      def render_view_js_scss_companions!
        template "action.html.erb.tt", File.join("app/views/rails_admin/main", "#{file_name}.html.erb")
        template "action.js.tt", File.join("app/assets/javascripts/rails_admin/actions", "#{file_name}.js")
        template "action.scss.tt", File.join("app/assets/stylesheets/rails_admin/actions", "#{file_name}.scss")
      end

      # Ensures config/initializers/after_initialize.rb exists (creating it
      # from the skeleton above if absent) and that `require_line` is present
      # inside its `config.after_initialize do ... end` block — idempotently.
      def ensure_after_initialize_require!(require_line)
        path = "config/initializers/after_initialize.rb"
        full_path = File.join(destination_root, path)

        create_file(path, AFTER_INITIALIZE_TEMPLATE) unless File.exist?(full_path)

        content = File.read(full_path)
        if content.include?(require_line)
          say_status :skip, "#{path} already requires it", :blue
        else
          insert_into_file(path, "        #{require_line}\n", after: /config\.after_initialize do\n/)
        end
      end

      # Ensures config/initializers/assets.rb exists (creating it from the
      # skeleton above if absent) and that `precompile_line` is appended to
      # it — idempotently.
      def ensure_assets_precompile_line!(precompile_line)
        path = "config/initializers/assets.rb"
        full_path = File.join(destination_root, path)

        create_file(path, ASSETS_TEMPLATE) unless File.exist?(full_path)

        content = File.read(full_path)
        if content.include?(precompile_line)
          say_status :skip, "#{path} already has the precompile line", :blue
        else
          append_to_file(path, "\n#{precompile_line}\n")
        end
      end

      # Writes the RailsAdmin action's menu/title/breadcrumb locale entry
      # (all three set to `title`, matching addRootAction.js/
      # addMemberAction.js's mergeYaml behavior) under `admin.actions.<key>`
      # into every *.yml file already present under config/locales — not just
      # en.yml/it.yml, per thecore_generators#11's acceptance criteria. When
      # the locales directory has no *.yml file yet, en.yml and it.yml are
      # created first and then updated the same way.
      def write_action_locale_entries!(key, title)
        locales_dir = File.join(destination_root, "config", "locales")
        existing = Dir.exist?(locales_dir) ? Dir.children(locales_dir).select { |f| f.end_with?(".yml") } : []

        existing = %w[en.yml it.yml] if existing.empty?

        existing.sort.each do |file|
          rel_path = File.join("config", "locales", file)
          full_path = File.join(destination_root, rel_path)
          default_lang = File.basename(file, ".yml")

          create_file(rel_path, "#{default_lang}:\n") unless File.exist?(full_path)
          merge_action_locale_entry!(rel_path, default_lang, key, title)
        end
      end

      # `lang` is the file's own single top-level key when it already has
      # exactly one (the locale code, e.g. "en" in a Rails/Devise-style
      # "devise.en.yml" whose filename does not equal its locale code) —
      # falling back to `default_lang` (derived from the filename) only for
      # an empty/freshly-created file, where there is nothing yet to read the
      # real locale code from.
      def merge_action_locale_entry!(rel_path, default_lang, key, title)
        full_path = File.join(destination_root, rel_path)
        data = YAML.load_file(full_path) || {}
        lang = data.size == 1 ? data.keys.first : default_lang
        data[lang] = {} unless data[lang].is_a?(Hash)
        data[lang]["admin"] = {} unless data[lang]["admin"].is_a?(Hash)
        data[lang]["admin"]["actions"] = {} unless data[lang]["admin"]["actions"].is_a?(Hash)
        data[lang]["admin"]["actions"][key] = { "menu" => title, "title" => title, "breadcrumb" => title }

        create_file(rel_path, YAML.dump(data), force: true, verbose: false)
      end
    end
  end
end
