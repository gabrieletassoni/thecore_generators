require "thor/error"

module Thecore
  module Generators
    # Ruby port of thecore_code_extension's libs/workspaceContext.js
    # (specifically its `atomRootOf`/`hasGemspec` gemspec-presence-under-
    # vendor/submodules detection). The extension resolved context from a
    # right-clicked VS Code folder; here we resolve it from the invoking
    # process's `Dir.pwd`, since a terminal has no clicked folder — see
    # docs/adr/0002-thecore-generators-gem-and-generator-hook-mechanism.md in
    # the thecore repo.
    #
    # There is no AppContext/ATOMContext class pair here (unlike the JS
    # original): a generator only ever needs one thing from this module — the
    # absolute ATOM directory to redirect file placement to, or `nil` when
    # `cwd` (and no `--atom` override) resolves to plain host-app context, in
    # which case the generator leaves Rails' own default placement (relative
    # to `destination_root`, already the app root for a real `rails generate`
    # invocation) untouched.
    module WorkspaceContext
      module_function

      # Returns the absolute ATOM directory for placement, or nil for
      # host-app context.
      #
      # `atom_name`, when present (a generator's `--atom=NAME` option), is an
      # explicit override that skips `cwd`-based detection entirely and is
      # resolved as `<app_root>/vendor/submodules/<atom_name>` instead — this
      # is what lets `--atom=NAME` work "from anywhere", independent of `cwd`.
      # `app_root` is the generator's own (pre-override) `destination_root`:
      # for a real `rails generate` invocation that is already
      # `Rails::Command.root` (see rails/commands/generate/generate_command.rb),
      # and in tests it's whatever `Rails::Generators::TestCase` configured as
      # `destination_root` — either way it's the correct anchor without this
      # module needing its own notion of "the app root".
      def atom_dir_for(cwd:, app_root:, atom_name: nil)
        atom_name = atom_name.to_s.strip
        return resolve_named_atom(app_root, atom_name) unless atom_name.empty?

        resolve_cwd_atom(cwd)
      end

      # Walks up from `dir` until the immediate parent directory is
      # `vendor/submodules` — that child is the ATOM root. Mirrors
      # workspaceContext.js's `atomRootOf`. Returns nil if `dir` is not
      # inside a `vendor/submodules/<atom>/` tree at all.
      def atom_root_of(dir)
        current = File.expand_path(dir.to_s)

        loop do
          parent = File.dirname(current)
          return nil if parent == current # reached the filesystem root

          if File.basename(parent) == "submodules" && File.basename(File.dirname(parent)) == "vendor"
            return current
          end

          current = parent
        end
      end

      # Ported from workspaceContext.js's `hasGemspec`: an ATOM directory is
      # valid when it contains `<dirname>.gemspec` or, since gem names can't
      # contain dashes, the dash-to-underscore variant of it.
      def gemspec_path_for(atom_dir)
        atom_name = File.basename(atom_dir)

        [atom_name, atom_name.tr("-", "_")].each do |candidate|
          path = File.join(atom_dir, "#{candidate}.gemspec")
          return path if File.exist?(path)
        end

        nil
      end

      def valid_atom_dir?(atom_dir)
        File.directory?(atom_dir) && !gemspec_path_for(atom_dir).nil?
      end

      class << self
        private

        def resolve_named_atom(app_root, atom_name)
          candidate = File.join(app_root.to_s, "vendor", "submodules", atom_name)
          return candidate if valid_atom_dir?(candidate)

          raise Thor::Error,
            "No ATOM named '#{atom_name}' found at #{candidate} " \
            "(expected a #{atom_name}.gemspec or #{atom_name.tr('-', '_')}.gemspec inside it)."
        end

        def resolve_cwd_atom(cwd)
          candidate = atom_root_of(cwd)
          return nil unless candidate

          unless valid_atom_dir?(candidate)
            raise Thor::Error,
              "#{candidate} is under vendor/submodules/ but has no gemspec - " \
              "not a valid Thecore ATOM."
          end

          candidate
        end
      end
    end
  end
end
