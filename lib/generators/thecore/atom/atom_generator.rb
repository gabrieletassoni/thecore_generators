require "rails/generators/named_base"
require "generators/thecore/tty_detection"
require "generators/thecore/sample_fetcher"
require "shellwords"
require "yaml"

module Thecore
  module Generators
    # `rails generate thecore:atom NAME` (thecore_generators#20, per ADR 0006 in the
    # thecore repo) — a Ruby port of thecore_code_extension's createATOM.js, producing
    # a complete, working ATOM end-to-end from a terminal: no VS Code, no extension
    # required.
    #
    # Unlike every other generator in this gem, AtomGenerator does NOT include
    # Thecore::Generators::AtomAware and takes no --atom=NAME option — creating a
    # *new* ATOM is only ever a host-app-root operation (it makes no sense to run
    # "from inside" an ATOM that doesn't exist yet). destination_root therefore stays
    # fixed at the host app root for the whole generator; every path this class writes
    # is expressed relative to that root via #atom_root ("vendor/submodules/<name>"),
    # not via AtomAware's destination_root-redirection trick.
    #
    # Two Gemfiles are in play here — the host app's own (destination_root/Gemfile)
    # and the freshly-scaffolded ATOM's own (vendor/submodules/<name>/Gemfile) — which
    # is why Rails::Generators::Actions#gem (used once, in #add_gem_to_host_gemfile)
    # can't be reused for the ATOM's own Gemfile: #gem's own implementation always
    # writes through `in_root { ... }`, and Thor::Actions#in_root is hardcoded to
    # `@destination_stack.first` (the *original* destination_root), not whatever
    # #inside might currently have pushed — so it can never be redirected to a nested
    # path. The ATOM's own Gemfile is instead mutated via plain #append_to_file calls
    # against an explicit relative path.
    class AtomGenerator < Rails::Generators::NamedBase
      class_option :non_interactive, type: :boolean, default: false,
        desc: "Skip all interactive prompts; every required value must be supplied " \
              "via --summary/--description/--author/--email/--url, and the " \
              "API/Admin dependency choice defaults to included unless " \
              "--skip-api-admin-deps is also passed"
      class_option :summary, type: :string, default: nil,
        desc: "The ATOM's one-line summary (required with --non-interactive)"
      class_option :description, type: :string, default: nil,
        desc: "The ATOM's longer description (required with --non-interactive)"
      class_option :author, type: :string, default: nil,
        desc: "The ATOM's author name (required with --non-interactive)"
      class_option :email, type: :string, default: nil,
        desc: "The ATOM author's email (required with --non-interactive)"
      class_option :url, type: :string, default: nil,
        desc: "The ATOM's homepage URL (required with --non-interactive)"
      class_option :skip_api_admin_deps, type: :boolean, default: false,
        desc: "Don't add model_driven_api/thecore_ui_rails_admin as dependencies " \
              "(only consulted with --non-interactive; interactively this is its " \
              "own yes/no prompt, default yes)"

      source_root File.expand_path("templates", __dir__)

      # Validated the same way as createATOM.js's own six prompts: every field must
      # be present; email must contain "@"; url must start with "http". Order matches
      # the original prompt sequence.
      REQUIRED_STRING_FIELDS = {
        "summary" => ->(v) { !v.to_s.strip.empty? },
        "description" => ->(v) { !v.to_s.strip.empty? },
        "author" => ->(v) { !v.to_s.strip.empty? },
        "email" => ->(v) { v.to_s.include?("@") },
        "url" => ->(v) { v.to_s.start_with?("http") },
      }.freeze

      # This gem's own ADR 0001 floor (matching the App template's already-corrected
      # versions) — not createATOM.js's stale "~> 3.1"/"~> 3.2".
      MODEL_DRIVEN_API_VERSION = "~> 3.9"
      THECORE_UI_RAILS_ADMIN_VERSION = "~> 3.8"

      # Faithful port of templates/createATOM/after_initialize.rb /
      # templates/createATOM/assets.rb in thecore_code_extension — static content,
      # no per-ATOM interpolation, so these are plain constants rather than .tt files.
      AFTER_INITIALIZE_CONTENT = <<~RUBY
        Rails.application.configure do
            config.after_initialize do
                # For example, it can be used to load a root action defined in lib, for example:
                # require 'root_actions/tcp_debug'
            end
        end
      RUBY

      ASSETS_CONTENT = <<~RUBY
        # PLEASE, uncomment if needed.
        # For Example: in the case there's a root action called tcp_debug, add the following lines to include css and javascripts for auto loading:
        # Rails.application.config.assets.precompile += %w(
        #   main_tcp_debug.js
        #   main_tcp_debug.css
        # )
      RUBY

      # Faithful port of createATOM.js's addCICDFiles gempush.yml, with its two
      # long-standing bugs fixed (thecore_generators#20 acceptance criteria): the awk
      # pipeline computing the version string had a stray, unmatched `)` instead of a
      # closing `}'`; and `version_exists` was referenced in two steps' `if:`
      # conditions but never actually set anywhere (the "check" step only ever did
      # `echo $?`), so those two steps have never run for any ATOM generated this way.
      # Fixed here by actually writing `version_exists` to $GITHUB_ENV based on
      # whether a git tag for the computed version already exists - kept as an
      # `env.*`-style if: condition (not switched to `steps.*.outputs.*`) to stay as
      # close to the original's structure as the fix allows.
      GEMPUSH_YML_CONTENT = <<~YAML
        name: Ruby Gem
        on: push
        jobs:
          build:
            name: Build + Publish
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v3
              - name: Check if version already exists
                run: |
                  version=$(grep -oP 'VERSION = "\\K[^"]+' lib/*/version.rb | awk -F'.' '{print $1"."$2"."$3}')
                  git fetch --unshallow --tags
                  if git rev-parse "$version" >/dev/null 2>&1; then
                    echo "version_exists=true" >> "$GITHUB_ENV"
                  else
                    echo "version_exists=false" >> "$GITHUB_ENV"
                  fi
              - name: Set git tag
                if: env.version_exists == 'false'
                run: |
                  git config --local user.email "noreply@alchemic.it"
                  git config --local user.name "AlchemicIT"
                  version=$(grep -oP 'VERSION = "\\K[^"]+' lib/*/version.rb | awk -F'.' '{print $1"."$2"."$3}')
                  git tag -a $version -m "Version $version"
                  git push --tags
              - name: Publish to RubyGems
                if: env.version_exists == 'false'
                env:
                  GEM_HOST_API_KEY: ${{secrets.RUBYGEMS_AUTH_TOKEN}}
                run: |
                  mkdir -p $HOME/.gem
                  touch $HOME/.gem/credentials
                  chmod 0600 $HOME/.gem/credentials
                  printf -- "---\\n:rubygems_api_key: ${GEM_HOST_API_KEY}\\n" > $HOME/.gem/credentials
                  gem build *.gemspec
                  gem push *.gem
      YAML

      SCAFFOLD_DIRECTORIES = %w[
        db/migrate
        app/models/concerns/api
        app/models/concerns/rails_admin
        config/initializers
        config/locales
        lib/root_actions
        lib/member_actions
        lib/collection_actions
        app/assets/javascripts
        app/assets/stylesheets
        app/views/rails_admin/main
        .github/workflows
      ].freeze

      # Gem-name convention (matches real examples in this very ecosystem, including
      # the hyphenated `thecore-spot-overrides`) - lowercase, starting with a letter,
      # letters/digits/underscore/hyphen only. Deliberately stricter than NamedBase's
      # own permissive `name` parsing: without this, a name containing a space or
      # shell metacharacter would flow straight into the unescaped shell-out in
      # #create_rails_engine (word-splitting or, worse, executing arbitrary shell),
      # and a namespaced name (`acme/widget`) would desync #atom_root (which uses
      # only #file_name, "widget") from #class_name (which uses the full namespaced
      # "Acme::Widget"), breaking the abilities.rb template.
      NAME_PATTERN = /\A[a-z][a-z0-9_-]*\z/

      def validate_atom_name!
        return if file_name.match?(NAME_PATTERN)

        raise Thor::Error,
          "'#{file_name}' is not a valid ATOM name - use lowercase letters, digits, " \
          "underscores, or hyphens, starting with a letter (e.g. tcp_debugger)."
      end

      def ensure_submodules_dir_exists!
        return if File.directory?(File.join(destination_root, "vendor", "submodules"))

        raise Thor::Error,
          "vendor/submodules does not exist under #{destination_root} - run `rails generate " \
          "thecore:atom` from a Thecore host app root that already has it (see the App " \
          "application template, thecore_generators#17/#18) before creating an ATOM."
      end

      # `rails plugin new`'s own `-f` (force) suppresses its normal file-collision
      # prompt, so without this guard a name colliding with an existing ATOM (a real
      # scenario in this very host app: `vendor/submodules/mytask` already exists)
      # would silently overwrite that ATOM's working tree with freshly-generated
      # plugin skeleton files - caught during review, reproduced directly against
      # this app's own real `mytask` submodule.
      def ensure_atom_does_not_already_exist!
        return unless File.exist?(File.join(destination_root, atom_root))

        raise Thor::Error,
          "#{atom_root} already exists - choose a different name, or remove it first if you " \
          "really mean to regenerate it."
      end

      def validate_non_interactive_options!
        return unless effectively_non_interactive?

        missing = REQUIRED_STRING_FIELDS.reject { |key, valid| valid.call(options[key]) }.keys
        return if missing.empty?

        raise Thor::Error,
          "Missing required flags for --non-interactive: #{missing.map { |k| "--#{k}" }.join(", ")}"
      end

      def collect_metadata
        @summary = required_field("summary", "the summary of the ATOM, i.e. TCP Debugger")
        @description = required_field("description", "the description of the ATOM, i.e. TCP Debugger")
        @author = required_field("author", "the author of the ATOM, i.e. Alchemic IT")
        @email = required_field("email", "the email of the ATOM author")
        @url = required_field("url", "the url of the ATOM")
      end

      def collect_api_admin_deps_choice
        @include_api_admin_deps =
          if effectively_non_interactive?
            !options[:skip_api_admin_deps]
          else
            ask(
              "Include model_driven_api/thecore_ui_rails_admin as dependencies?",
              default: "yes", limited_to: %w[yes no]
            ) == "yes"
          end
      end

      # Faithful to createATOM.js's own `rails plugin new "<path>" -fG
      # --skip-gemfile-entry --skip-hotwire --full` invocation, cwd'd to
      # vendor/submodules (via #inside, which - unlike file-writing actions below -
      # genuinely changes the OS process's cwd for #run's sake). `bundle exec` is a
      # deliberate addition over the JS original (which shells a bare `rails`,
      # relying entirely on whatever's globally on PATH): it makes gem resolution
      # explicit rather than incidental, and costs nothing in the real host-app case,
      # where cwd already sits under that app's own Gemfile either way. `file_name`
      # is Shellwords-escaped even though #validate_atom_name! already restricts it
      # to a shell-safe character set - defense in depth, matching the same care
      # #git_init_and_commit already takes with the free-text @author/@email.
      def create_rails_engine
        inside("vendor/submodules") do
          run("bundle exec rails plugin new #{Shellwords.escape(file_name)} " \
                "-fG --skip-gemfile-entry --skip-hotwire --full",
            abort_on_failure: true)
        end
      end

      # #create_file already `mkdir_p`s its own parent directory, so a separate
      # #empty_directory call per entry would just be redundant work (and, for the
      # 3 of these 12 that #create_scaffold_files/#create_locale_files/
      # #create_ci_files populate with a real file moments later, entirely so).
      def create_scaffold_directories
        SCAFFOLD_DIRECTORIES.each { |dir| create_file(File.join(atom_root, dir, ".keep")) }
      end

      def create_scaffold_files
        create_file File.join(atom_root, "config/initializers/after_initialize.rb"), AFTER_INITIALIZE_CONTENT
        create_file File.join(atom_root, "config/initializers/add_to_db_migration.rb"),
          "Rails.application.config.paths['db/migrate'] << File.expand_path(\"../../db/migrate\", __dir__)\n"
        create_file File.join(atom_root, "config/initializers/assets.rb"), ASSETS_CONTENT
        template "abilities.rb.tt", File.join(atom_root, "config/initializers/abilities.rb")
        template "seeds.rb.tt", File.join(atom_root, "db/seeds.rb")
      end

      # Bare "en:\n"/"it:\n", matching the exact convention
      # Thecore::Generators::CompanionFiles#write_action_locale_entries! already uses
      # for this identical "no locale file yet" bootstrap case elsewhere in this gem
      # - not the YAML-document-with-null-value shape `{"en"=>nil}.to_yaml` produces,
      # which is equivalent once parsed but an unnecessary second on-disk convention
      # for the same thing.
      def create_locale_files
        create_file File.join(atom_root, "config/locales/en.yml"), "en:\n"
        create_file File.join(atom_root, "config/locales/it.yml"), "it:\n"
      end

      def create_ci_files
        create_file File.join(atom_root, ".github/workflows/gempush.yml"), GEMPUSH_YML_CONTENT

        gitlab_ci = {
          "image" => "gabrieletassoni/vscode-devcontainers-thecore:3",
          "variables" => {
            "GITLAB_EMAIL" => @email,
            "GITLAB_USER_NAME" => @author,
            "GITLAB_GEM_REPO_TARGET" => 'https://${GEM_HOST}/',
            "GEM_HOST_API_KEY" => '${GEMS_REPO_CREDENTIALS}',
          },
          "stages" => %w[build release],
          "build_gem" => {
            "rules" => [{ "if" => "$CI_COMMIT_TAG", "when" => "never" }, { "when" => "always" }],
            "stage" => "build",
            "script" => ["/usr/bin/gem-compile.sh"],
          },
        }
        create_file File.join(atom_root, ".gitlab-ci.yml"), gitlab_ci.to_yaml
      end

      def setup_gemfile
        gemfile_addition = +"\ngem 'pg'\n"
        gemfile_addition << "gem 'model_driven_api', '#{MODEL_DRIVEN_API_VERSION}'\n" \
          "gem 'thecore_ui_rails_admin', '#{THECORE_UI_RAILS_ADMIN_VERSION}'\n" if @include_api_admin_deps
        append_to_file File.join(atom_root, "Gemfile"), gemfile_addition

        return unless @include_api_admin_deps

        append_to_file File.join(atom_root, "lib", "#{file_name}.rb"),
          "\nrequire 'model_driven_api'\nrequire 'thecore_ui_rails_admin'\n"
      end

      # One read, one write, one pass of in-memory substitutions - not createATOM.js's
      # own blind "rewrite every line, branching on substring" approach (the current
      # `rails plugin new --full` gemspec template, verified directly against a real
      # generation rather than assumed from the JS original, has moved on
      # significantly: new `homepage_uri`/`license` lines, different summary/
      # description wording - a full-file line-by-line port would silently stop
      # matching several of these fields), and not 8 separate #gsub_file calls
      # either (each its own full read-modify-write cycle against the same small
      # file - wasted I/O for no benefit). One deliberate correctness fix over the
      # original along the way: the JS's `.add_dependency` branch *replaces* the
      # whole line, which happens to be `spec.add_dependency "rails", ...` in
      # current Rails - silently dropping the gem's own Rails dependency entirely.
      # This appends the two Thecore dependencies right after that line instead of
      # replacing it.
      def setup_gemspec
        gemspec_path = File.join(atom_root, "#{file_name}.gemspec")
        content = File.read(File.join(destination_root, gemspec_path))

        content = content.sub(/^(\s*spec\.add_dependency\s+["']rails["'].*)$/) do
          next Regexp.last_match(1) unless @include_api_admin_deps

          "#{Regexp.last_match(1)}\n  spec.add_dependency \"model_driven_api\", \"#{MODEL_DRIVEN_API_VERSION}\"\n" \
            "  spec.add_dependency \"thecore_ui_rails_admin\", \"#{THECORE_UI_RAILS_ADMIN_VERSION}\""
        end
        content = content.sub(/^\s*spec\.authors\s*=.*$/, "  spec.authors     = [#{@author.to_s.inspect}]")
        content = content.sub(/^\s*spec\.email\s*=.*$/, "  spec.email       = [#{@email.to_s.inspect}]")
        content = content.sub(/^\s*spec\.homepage\s*=.*$/, "  spec.homepage    = #{@url.to_s.inspect}")
        content = content.sub(/^\s*spec\.summary\s*=.*$/, "  spec.summary     = #{@summary.to_s.inspect}")
        content = content.sub(/^\s*spec\.description\s*=.*$/, "  spec.description = #{@description.to_s.inspect}")
        content = content.sub(/^\s*spec\.metadata\["allowed_push_host"\]\s*=.*$/,
          '  spec.metadata["allowed_push_host"] = "https://rubygems.org"')
        content = content.sub(/^\s*spec\.metadata\["source_code_uri"\]\s*=.*$/,
          '  spec.metadata["source_code_uri"] = spec.homepage')
        content = content.sub(/^\s*spec\.metadata\["changelog_uri"\]\s*=.*$/,
          '  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/master/CHANGELOG.md"')

        create_file gemspec_path, content, force: true
      end

      # Completes this generator's scope (thecore_generators#22, ADR 0006): fetches
      # thecore's own samples/ATOM_CLAUDE.md and writes it as the new ATOM's
      # CLAUDE.md, via the shared Thecore::Generators::SampleFetcher - the same
      # THECORE_SAMPLES_SOURCE mechanism the App template's own (separate, still
      # independent - see sample_fetcher.rb's own header for why) asset fetch
      # already established.
      #
      # A fetch failure here raises SystemExit (via Kernel#abort), not Thor::Error
      # like every guard method above - a deliberate inconsistency, not an
      # oversight: it matches the App template's own established convention for
      # this exact class of failure (an external, this-run-only fetch, as opposed
      # to a validation the generator could have caught before doing any real
      # work), and the ticket's own acceptance criteria asks for "fail-fast abort,"
      # not a Thor::Error. A failure here does leave the partially-generated
      # vendor/submodules/<name> directory behind (rails plugin new/the Gemfile/
      # gemspec edits already succeeded) - #ensure_atom_does_not_already_exist!
      # then refuses a same-named retry until it's removed by hand; the abort
      # message says so.
      #
      # NOTE: like the App template's own fetch of thecore/samples/CLAUDE.md
      # before it, this 404s against the real default GitHub URL until thecore's
      # `master` actually carries the commit that added samples/ATOM_CLAUDE.md
      # (thecore#18) - as of this gem's 3.11.0 release that commit exists only in
      # a local `thecore` checkout, not yet pushed. Same operational sequencing
      # note as the App template's own CLAUDE.md section: push `thecore` before
      # relying on the default in production.
      def fetch_claude_md
        Thecore::Generators::SampleFetcher.fetch_thecore_sample(
          self, "ATOM_CLAUDE.md", File.join(atom_root, "CLAUDE.md"), label: "the thecore:atom generator"
        )
      end

      # `-fG` (`rails plugin new`'s own force+skip-git flags) means no git repo and no
      # .gitignore exist yet at this point - a deliberate gap in createATOM.js this
      # ticket narrows, not fully closes (ADR 0006): a local, safe `git init` +
      # initial commit, but remote creation and `git submodule add` stay a logged,
      # human-run follow-up rather than something this generator automates. No
      # .gitignore is written (out of this ticket's scope - see ADR 0006/the ticket's
      # own acceptance criteria, which doesn't list one): verified directly that a
      # fresh `rails plugin new --full` output has no log/tmp/sqlite artifacts yet to
      # need ignoring - nothing has been bundled or run against the dummy app at this
      # point, so the initial commit is clean regardless.
      def git_init_and_commit
        atom_path = File.join(destination_root, atom_root)
        committed = inside(atom_root) do
          run("git init -q -b master", abort_on_failure: true)
          run("git add -A", abort_on_failure: true)
          # Not abort_on_failure: a freshly-generated tree always has something to
          # commit in normal use, but `git commit` failing (e.g. "nothing to
          # commit", however that state arose) shouldn't kill the whole process via
          # a raw, unexplained Kernel#abort when every file this generator actually
          # promises has already been written successfully by this point. The
          # result is still checked below, so a real failure changes what gets
          # logged rather than being silently treated as success.
          run(
            "git -c user.name=#{Shellwords.escape(@author)} -c user.email=#{Shellwords.escape(@email)} " \
              'commit -q -m "Initial commit"',
            abort_on_failure: false
          )
        end

        if committed
          say_status :next_steps, <<~MSG.strip, :yellow
            #{file_name} is git-initialized locally with one commit, but has no remote yet. To finish wiring it in:
              1. Create a repository for it on the git host of your choice (GitHub, GitLab, ...)
              2. cd #{atom_path} && git remote add origin <remote-url> && git push -u origin master
              3. From this app's root: git submodule add <remote-url> vendor/submodules/#{file_name}
          MSG
        else
          say_status :warning, <<~MSG.strip, :red
            #{file_name} was git-initialized, but `git commit` did not succeed - it has no commit
            yet. Check the output above, commit by hand once resolved, then follow the usual
            steps to create a remote and `git submodule add` it into this app.
          MSG
        end
      end

      # Guards against the same name-collision scenario #ensure_atom_does_not_already_exist!
      # protects the ATOM directory itself from: a host Gemfile that already
      # declares a same-named gem (real in this very host app - `mytask` is
      # resolved from a gem server today) would otherwise get a second, conflicting
      # `gem "mytask", path: ...` line appended, and the next `bundle install`
      # fails outright ("You cannot specify the same gem twice"). In the normal
      # case (no prior entry) this is unreachable in practice anyway, since
      # #ensure_atom_does_not_already_exist! already refuses a name whose
      # vendor/submodules/<name> directory exists - kept as its own explicit check
      # since a Gemfile entry and a vendor/submodules directory are two independent
      # pieces of state that could in principle drift apart.
      def add_gem_to_host_gemfile
        gemfile_path = File.join(destination_root, "Gemfile")
        if File.exist?(gemfile_path) && File.read(gemfile_path).match?(/^\s*gem\s+["']#{Regexp.escape(file_name)}["']/)
          say_status :skip, "Gemfile already declares '#{file_name}' - not adding a second entry", :yellow
          return
        end

        gem file_name, path: "vendor/submodules/#{file_name}"
      end

      private

      def atom_root
        File.join("vendor", "submodules", file_name)
      end

      # True whenever prompting for input isn't viable: --non-interactive was
      # passed explicitly, or (via the shared Thecore::Generators::TtyDetection,
      # also used by AssociationWiring's own `interactive_association_prompt?`)
      # there's no real TTY behind stdin/stdout at all - a CI runner or a
      # shelled-out child process that simply forgot the flag. Without this,
      # #required_field's own `ask`-in-a-loop would spin forever re-prompting a
      # stream that can never supply input, since a closed/EOF stdin makes Thor's
      # `ask` return nil immediately.
      def effectively_non_interactive?
        options[:non_interactive] || !Thecore::Generators::TtyDetection.real_tty?
      end

      # Interactive: loop with Thor's own `ask` until the validator passes, echoing
      # the same "not valid, try again" wording createATOM.js's input boxes used.
      # Non-interactive (explicit or TTY-detected): already validated present by
      # #validate_non_interactive_options! (a task method that always runs first),
      # so this simply reads the option.
      def required_field(key, prompt_hint)
        return options[key] if effectively_non_interactive?

        validate = REQUIRED_STRING_FIELDS.fetch(key)
        loop do
          value = ask("Enter #{prompt_hint}:")
          return value if validate.call(value)

          say_status :error, "The #{key} is not valid. Please try again.", :red
        end
      end

    end
  end
end
