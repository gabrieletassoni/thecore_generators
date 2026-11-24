require "test_helper"
require "open3"
require "tmpdir"
require "json"
require "yaml"
require "uri"

# The App application template (thecore_generators#17/#18, ADR 0005 in the thecore repo)
# is a Rails application template, not a Thor::Group generator — its only real entry
# point is `rails new -m`, so this is the one seam it's tested through: a real `rails
# new` subprocess against a scratch tmp directory, asserting on the resulting file tree.
# A real subprocess (not an in-process Rails::Generators::AppGenerator.start call) is
# used deliberately — this test suite already boots a full Rails::Application
# (test/dummy) in-process for the generator tests elsewhere in this file list, and a
# second, unrelated `rails new` run sharing that same process is an unnecessary risk
# to court for no benefit.
#
# Kept offline and deterministic (thecore_generators#17's own acceptance criteria):
# `--skip-bundle` stops Rails' own automatic bundle of the gems this template adds,
# and answering "no" to the template's own interactive installer-chain prompt (fed via
# stdin) stops it from calling `bundle install`/`rails generate ...` itself either —
# both are required together, independently, to avoid any live network call.
class AppTemplateTest < Minitest::Test
  TEMPLATE_PATH = File.expand_path("../../lib/templates/app_template.rb", __dir__)
  GEM_ROOT = File.expand_path("../..", __dir__)
  # thecore_generators#18's asset-source override point, pinned at a fixture checked
  # into this gem's own test folder rather than thecore's real samples/ (which this
  # gem doesn't own and shouldn't duplicate a live copy of) — keeps the whole suite
  # offline and deterministic, no live HTTP calls to raw.githubusercontent.com.
  SAMPLES_FIXTURE_DIR = File.expand_path("../fixtures/thecore_samples", __dir__)
  # Seam S1 of thecore_devcontainer#5: a local checkout of thecore's REAL samples/
  # directory (e.g. `<thecore checkout>/samples`). Unset = the real-samples test skips,
  # so the suite stays offline by default; point it at any thecore checkout (a worktree
  # included) to test that checkout's samples through this template.
  REAL_SAMPLES_ENV = "THECORE_REAL_SAMPLES_DIR"

  def test_core_scaffolding_matches_thecore_generators_17_acceptance_criteria
    Dir.mktmpdir do |dir|
      app_path = File.join(dir, "sample_app")

      stdout, stderr, status = spawn_rails_new(app_path, chdir: dir)
      assert status.success?, "`rails new -m app_template.rb` failed:\n#{stdout}\n#{stderr}"

      gemfile = File.read(File.join(app_path, "Gemfile"))

      %w[devise cancancan rails_admin sassc-rails].each do |gem_name|
        assert_match(/^\s*gem ["']#{Regexp.escape(gem_name)}["']/, gemfile,
          "expected the core Gemfile stack to include an active `#{gem_name}` line")
      end

      # ADR 0001 (thecore repo) requires model_driven_api >= 3.9.0 / thecore_ui_rails_admin
      # >= 3.8.0 for the DefaultModuleRegistry default-concern behavior. The security
      # floors above them are asserted on the real samples (assert_gem_floor_practices).
      dsl = Bundler::Dsl.new
      dsl.eval_gemfile(File.join(app_path, "Gemfile"))
      # Last release below each ADR 0001 floor: the Gemfile must refuse it.
      { "model_driven_api" => "3.8.99", "thecore_ui_rails_admin" => "3.7.99" }.each do |name, below_floor|
        dep = dsl.dependencies.find { |d| d.name == name }
        assert dep, "expected an active `#{name}` line"
        refute dep.requirement.satisfied_by?(Gem::Version.new(below_floor)),
          "expected #{name} to stay above the ADR 0001 floor (refusing #{below_floor})"
      end

      # New apps start on Rails 8.1 (Odoo #6091): 8.1.4.1 carries the 2026-11-04 security
      # fixes, 8.2 is not supported by the 3.x ATOMs yet.
      rails = dsl.dependencies.find { |d| d.name == "rails" }
      assert rails, "expected an active `rails` line"
      { "8.1.4.1" => true, "8.1.5" => true, "8.1.4" => false, "7.2.4" => false, "8.2.0" => false }.each do |version, ok|
        assert_equal ok, rails.requirement.satisfied_by?(Gem::Version.new(version)),
          "expected the Gemfile to #{ok ? "accept" : "refuse"} rails #{version}"
      end

      # What the Thecore engines need before anything can boot the app (Rails' own
      # importmap:install, devise:install, every bin/rails command): Devise's ORM hook, since
      # they load `User` at boot, and the app's Ability, which thecore_auth_commons references.
      assert_match(%r{^require "devise/orm/active_record"$},
        File.read(File.join(app_path, "config/initializers/00_devise_orm.rb")))
      assert_match(/class Ability\n  include CanCan::Ability\n\n  def initialize\(user\); end/,
        File.read(File.join(app_path, "app/models/ability.rb")))

      # Sprockets, as the pilot and RailsAdmin 3 use: Rails 8's `rails new` only does Propshaft.
      assert_match(/^gem ["']sprockets-rails["']/, gemfile)
      refute_match(/^gem ["']propshaft["']/, gemfile)
      assert_match(%r{^//= link_directory \.\./stylesheets \.css$},
        File.read(File.join(app_path, "app/assets/config/manifest.js")))
      # Rails 8's layout links the Propshaft name `:app`; Sprockets only has application.css.
      layout = File.read(File.join(app_path, "app/views/layouts/application.html.erb"))
      assert_match(/stylesheet_link_tag "application"/, layout)
      refute_match(/stylesheet_link_tag :app\b/, layout)

      assert_thecore3_runtime_practices(app_path)
      assert_same_as_rails_skip_switches(app_path)

      # Rails 8 no longer generates them, and thecore_backend_commons extends both at boot.
      assert_match(/class Connection < ActionCable::Connection::Base/,
        File.read(File.join(app_path, "app/channels/application_cable/connection.rb")))
      assert_match(/class Channel < ActionCable::Channel::Base/,
        File.read(File.join(app_path, "app/channels/application_cable/channel.rb")))

      # Matched loosely (any 3.x, not a hardcoded minor) since this is this gem's own,
      # self-referential version constraint -- it will legitimately move on every
      # future release of thecore_generators itself, unlike the external ADR 0001
      # floors above, which only change deliberately and rarely.
      assert_match(/^\s*gem ["']thecore_generators["'],\s*["']~>\s*3\.\d+["'],\s*group:\s*:development/, gemfile,
        "expected thecore_generators to be added as a :development-only dependency")

      %w[thecore_print_commons thecore_tcp_debug thecore_download_documents thecore_dataentry_commons].each do |gem_name|
        assert_match(/^\s*#\s*gem ["']#{Regexp.escape(gem_name)}["'].*#.+/, gemfile,
          "expected `#{gem_name}` to be listed commented-out with a purpose comment, discoverable but off by default")
      end
      # Gems that arrive as dependencies anyway are named as such, never offered as optional.
      %w[thecore_settings thecore_background_jobs thecore_ui_commons].each do |gem_name|
        refute_match(/^\s*#?\s*gem ["']#{gem_name}["']/, gemfile, "`#{gem_name}` is already a dependency, not optional")
        assert_match(/^#.*#{gem_name} \(via thecore_/, gemfile, "expected `#{gem_name}` named as already in the bundle")
      end

      %w[submodules external].each do |placeholder_dir|
        keep_file = File.join("vendor", placeholder_dir, ".keep")
        assert File.file?(File.join(app_path, keep_file)),
          "expected an empty, git-trackable vendor/#{placeholder_dir}/ placeholder"
        assert_equal [keep_file],
          Dir.glob("vendor/#{placeholder_dir}/**/*", base: app_path, flags: File::FNM_DOTMATCH)
            .reject { |p| p.end_with?("/.", "/..") },
          "vendor/#{placeholder_dir}/ should contain nothing but the placeholder — no pre-wired content"
      end

      # thecore_generators#18: devcontainer/CI/CLAUDE.md assets fetched from thecore's
      # samples (the fixture above, via THECORE_SAMPLES_SOURCE), overwriting whatever
      # the bootstrap "Setup Devcontainer" step would have created. Asserting byte-exact
      # equality against the fixture (not just "a file exists" / a content pattern)
      # proves the fetch round-trip actually pulled from the intended source — a
      # pattern-only check could pass even if the wrong file got fetched, as long as it
      # coincidentally matched; equality can't.
      %w[
        devcontainer.json docker-compose.yml Dockerfile create-db-user.sql
        link-host-home.sh check-plugins.sh heal-stale-containers.sh github-accounts.sh
        docker-socket-gid.sh .gitignore ldap-users.ldif
      ].each do |file|
        destination = File.join(app_path, ".devcontainer", file)
        assert File.file?(destination), "expected .devcontainer/#{file} to be fetched from thecore's samples"
        assert_equal File.read(File.join(SAMPLES_FIXTURE_DIR, "devcontainer", file)), File.read(destination),
          "expected the fetched .devcontainer/#{file} to match the fixture byte-for-byte"
      end
      %w[link-host-home.sh check-plugins.sh heal-stale-containers.sh github-accounts.sh
         docker-socket-gid.sh].each do |script|
        mode = File.stat(File.join(app_path, ".devcontainer", script)).mode
        assert (mode & 0o111).positive?, "expected .devcontainer/#{script} to be executable"
      end

      # The fixture's devcontainer.json (unlike the real thecore/samples one, kept
      # deliberately minimal — see SAMPLES_FIXTURE_DIR's comment) still carries the
      # commented gh/glab mounts specifically, since that's the one piece of content
      # this ticket's acceptance criteria calls out by name.
      devcontainer_json = File.read(File.join(app_path, ".devcontainer", "devcontainer.json"))
      %w[gh glab].each do |cli|
        assert_match(/^\s*\/\/\s*"source=.*#{cli}/, devcontainer_json,
          "expected the #{cli} CLI config mount to be present but commented out")
      end

      %w[
        .gitlab-ci.yml .github/workflows/ci.yml .github/workflows/security.yml CLAUDE.md AGENTS.md
        script/security_summary.rb test/script/security_summary_test.rb
        test/application_system_test_case.rb test/system/sign_in_test.rb
        docs/agents/issue-tracker.md docs/agents/triage-labels.md docs/agents/domain.md
      ].each do |file|
        destination = File.join(app_path, file)
        assert File.file?(destination), "expected #{file} to be fetched from thecore's samples"
        assert_equal File.read(File.join(SAMPLES_FIXTURE_DIR, file)), File.read(destination),
          "expected the fetched #{file} to match the fixture byte-for-byte"
      end

      claude_md = File.read(File.join(app_path, "CLAUDE.md"))
      assert_match(/mattpocock-skills/, claude_md, "expected the universal skill-plugin section")
      assert_match(/ask-matt/, claude_md, "expected the universal required-skill-sequence section")
      assert_match(/TODO/, claude_md, "expected project-specific sections left as TODO placeholders")
    end
  end

  # Seam S1 (thecore_devcontainer#5): the app a developer actually gets from the REAL
  # thecore samples, not the minimal fixture above. Every app-side practice the pilot
  # (mytask-imas) has is asserted here, one `assert_*_practices` helper per area --
  # later tickets add their own helper and call it from this one method, so the
  # expensive `rails new` runs once.
  def test_app_generated_from_real_thecore_samples_carries_pilot_practices
    samples_dir = real_samples_dir
    Dir.mktmpdir do |dir|
      app_path = File.join(dir, "sample_app")

      stdout, stderr, status = spawn_rails_new(
        app_path, chdir: dir, extra_env: { "THECORE_SAMPLES_SOURCE" => samples_dir }
      )
      assert status.success?, "`rails new -m app_template.rb` on #{samples_dir} failed:\n#{stdout}\n#{stderr}"

      assert_devcontainer_practices(app_path)
      assert_system_test_practices(app_path)
      assert_test_database_practices(app_path)
      assert_ci_test_database_practices(app_path)
      assert_agent_docs_practices(app_path)
      assert_docker_build_practices(app_path)
      assert_security_ci_practices(app_path)
      assert_gem_floor_practices(app_path)
      assert_github_workflow_practices(app_path)
      assert_thecore3_runtime_practices(app_path)
    end
  end

  # Seam S3 (Odoo #6091): the installer chain for real, as "Create App" runs it
  # (THECORE_APP_TEMPLATE_RUN_INSTALLERS=true): a real bundle and every installer, then the
  # generated app migrates, passes its own tests and eager-loads. Skipped unless
  # THECORE_REAL_INSTALL=1: it needs the network, a PostgreSQL server (PG* variables) and
  # this gem's Rails installed globally (`rails _<version>_ new`, outside this gem's bundle,
  # so the app's own `bundle install` resolves its own Gemfile). Nothing runs with
  # DATABASE_URL, which in the devcontainer names the host app's development database.
  def test_app_with_installers_migrates_passes_its_tests_and_eager_loads
    skip "set THECORE_REAL_INSTALL=1 to run the real installer chain" unless ENV["THECORE_REAL_INSTALL"] == "1"

    Dir.mktmpdir do |dir|
      app_path = File.join(dir, "thecore_s3_app")
      env = {
        "THECORE_SAMPLES_SOURCE" => SAMPLES_FIXTURE_DIR,
        "THECORE_APP_TEMPLATE_NON_INTERACTIVE" => "1",
        "THECORE_APP_TEMPLATE_RUN_INSTALLERS" => "true",
        "DATABASE_URL" => nil,
        "RAILS_ENV" => nil,
        "JUNIT_REPORT_DIR" => nil # this suite's own CI report, never the generated app's
      }
      run = lambda do |*command, chdir:, extra: {}|
        out, status = Bundler.with_unbundled_env { Open3.capture2e(env.merge(extra), *command, chdir: chdir) }
        assert status.success?, "`#{command.join(" ")}` failed:\n#{out}"
        out
      end

      run.call("rails", "_#{Rails.version}_", "new", app_path, "--database=postgresql", "--skip-git", "--quiet",
        "-m", TEMPLATE_PATH, chdir: dir)
      assert_match(%r{^\s*require ["']devise/orm/active_record["']},
        File.read(File.join(app_path, "config/initializers/devise.rb")),
        "expected devise:install to write the ActiveRecord ORM hook, not this gem's generator ORM")

      test_env = { "RAILS_ENV" => "test" }
      begin
        run.call("bin/rails", "db:create", "db:migrate", chdir: app_path, extra: test_env)
        output = run.call("bin/rails", "test", chdir: app_path, extra: test_env)
        # The fixture samples bring no tests of their own: what matters is a green, booting suite.
        assert_match(/\d+ runs, \d+ assertions, 0 failures, 0 errors/, output)
        run.call("bin/rails", "runner", "Rails.application.eager_load!", chdir: app_path, extra: test_env)
        # The Thecore 3 runtime after a real bundle and every installer: none of Rails 8's
        # Solid/Kamal/Thruster pieces is in the lock, on disk or referenced anywhere.
        assert_thecore3_runtime_practices(app_path)
        locked = Bundler::LockfileParser.new(File.read(File.join(app_path, "Gemfile.lock"))).specs.map(&:name)
        assert_empty locked & RAILS8_RUNTIME_GEMS, "expected none of #{RAILS8_RUNTIME_GEMS} in the lock"
        leftovers = Dir.glob("**/*", File::FNM_DOTMATCH, base: app_path).reject do |f|
          f.start_with?("log/", "tmp/", "storage/", ".git/") || f == "Gemfile.lock" ||
            File.directory?(File.join(app_path, f))
        end.select { |f| File.read(File.join(app_path, f)).scrub.match?(/solid_(queue|cache|cable)|kamal|thrust/i) }
        assert_empty leftovers, "expected no file to reference Solid Queue/Cache/Cable, Kamal or Thruster"
        # Production boots on the pilot's runtime: Sidekiq (set by thecore_backend_commons),
        # Action Cable on Redis, one database. The Thecore engines read their settings at boot,
        # so it connects to this test's own throwaway test database, never another one.
        s3_database_url = URI::Generic.build(
          scheme: "postgres", host: ENV.fetch("PGHOST", "db"), port: ENV.fetch("PGPORT", 5432).to_i,
          userinfo: "#{ENV.fetch("PGUSER", "postgres")}:#{ENV.fetch("PGPASSWORD", "postgres")}",
          path: "/#{File.basename(app_path)}_test"
        ).to_s
        prod = run.call("bin/rails", "runner",
          'print [ActiveJob::Base.queue_adapter_name, ActionCable.server.config.cable["adapter"], ' \
          'ActiveRecord::Base.configurations.configs_for(env_name: "production").map(&:name)].inspect',
          chdir: app_path, extra: { "RAILS_ENV" => "production", "SECRET_KEY_BASE_DUMMY" => "1",
                                    "REDIS_URL" => "redis://localhost:6379/1", "DATABASE_URL" => s3_database_url })
        assert_includes prod, '["sidekiq", "redis", ["primary"]]'

        # A page with the app's own layout renders (its stylesheet resolves in Sprockets).
        rendered = run.call("bin/rails", "runner",
          'print ApplicationController.render(inline: "s3-ok", layout: "application")',
          chdir: app_path, extra: test_env)
        assert_match(/s3-ok/, rendered)
      ensure
        Bundler.with_unbundled_env { Open3.capture2e(env.merge(test_env), "bin/rails", "db:drop", chdir: app_path) }
      end
    end
  end

  # Rails 8's runtime defaults the Thecore 3 stack replaces (thecore_generators#27, stage 1).
  RAILS8_RUNTIME_GEMS = %w[solid_cache solid_queue solid_cable kamal thruster].freeze
  RAILS8_RUNTIME_FILES = %w[
    config/deploy.yml .kamal bin/kamal bin/thrust bin/jobs config/queue.yml config/cache.yml
    config/recurring.yml db/cache_schema.rb db/queue_schema.rb db/cable_schema.rb
  ].freeze

  # A new app runs on the pilot's (mytask-imas) Thecore 3 runtime, not on Rails 8's defaults:
  # Sidekiq (thecore_backend_commons sets the production adapter), Action Cable on Redis, one
  # production database (a Thecore deploy has one), the Thecore Dockerfile instead of Kamal and
  # Thruster. Solid Queue/Cable/Cache arrive with release/4 (ADR 0035 in mytask-imas, #27).
  def assert_thecore3_runtime_practices(app_path)
    gemfile = File.read(File.join(app_path, "Gemfile"))
    RAILS8_RUNTIME_GEMS.each do |name|
      refute_match(/^\s*gem ["']#{name}["']/, gemfile, "expected no `#{name}` in the Gemfile")
    end
    refute_match(/Use the database-backed adapters|kamal-deploy|basecamp\/thruster/, gemfile,
      "expected the removed gems' comments gone too")
    RAILS8_RUNTIME_FILES.each do |file|
      refute File.exist?(File.join(app_path, file)), "expected no #{file}"
    end

    production = File.read(File.join(app_path, "config/environments/production.rb"))
    refute_match(/solid_cache_store|solid_queue/, production)
    assert_match(/^\s*# config\.cache_store = :mem_cache_store$/, production)
    if Rails::VERSION::MAJOR >= 8
      # Rails 8's skeleton leaves them off; `--skip-kamal` would turn them on. The installation's
      # proxy terminates SSL. (Rails 7.2's own skeleton turns force_ssl on.)
      assert_match(/^\s*# config\.force_ssl = true$/, production)
      assert_match(/^\s*# config\.assume_ssl = true$/, production)
    end
    refute_match(/plugin :solid_queue/, File.read(File.join(app_path, "config/puma.rb")))

    database = YAML.safe_load(ERB.new(File.read(File.join(app_path, "config/database.yml"))).result, aliases: true)
    assert_equal "#{File.basename(app_path)}_production", database.dig("production", "database"),
      "expected a single production database, not primary/cache/queue/cable"
    refute database["production"].key?("primary"), "expected no multi-database production config"

    cable = YAML.safe_load(ERB.new(File.read(File.join(app_path, "config/cable.yml"))).result, aliases: true)
    assert_equal "redis", cable.dig("production", "adapter")
    assert_equal "#{File.basename(app_path)}_production", cable.dig("production", "channel_prefix")
    assert_match(/ENV\.fetch\("REDIS_URL"\)/, File.read(File.join(app_path, "config/cable.yml")))
  end

  # The runtime files are exactly what `rails new --skip-solid --skip-kamal --skip-thruster`
  # writes for an app of the same name, except the two SSL lines `--skip-kamal` turns on (a
  # Thecore installation terminates SSL at its proxy). Rails 7.2 has no such switches.
  def assert_same_as_rails_skip_switches(app_path)
    skip "Rails #{Rails.version} has no --skip-solid/--skip-kamal" if Rails::VERSION::MAJOR < 8

    Dir.mktmpdir do |dir|
      reference = File.join(dir, File.basename(app_path))
      stdout, stderr, status = Open3.capture3(
        { "BUNDLE_GEMFILE" => File.join(GEM_ROOT, "Gemfile") },
        "bundle", "exec", "rails", "new", reference, "--database=postgresql", "--skip-bundle", "--skip-git",
        "--quiet", "--skip-solid", "--skip-kamal", "--skip-thruster", chdir: dir
      )
      assert status.success?, "reference `rails new` failed:\n#{stdout}\n#{stderr}"

      %w[config/database.yml config/puma.rb config/cable.yml .dockerignore].each do |file|
        assert_equal File.read(File.join(reference, file)), File.read(File.join(app_path, file)),
          "expected #{file} to be what `rails new --skip-solid --skip-kamal --skip-thruster` writes"
      end
      ssl_on = ->(text) { text.sub(/^  # config\.assume_ssl = true$/, "  config.assume_ssl = true")
        .sub(/^  # config\.force_ssl = true$/, "  config.force_ssl = true") }
      assert_equal File.read(File.join(reference, "config/environments/production.rb")),
        ssl_on.call(File.read(File.join(app_path, "config/environments/production.rb"))),
        "expected production.rb to differ from the skip switches' only in the SSL lines"
      refute File.exist?(File.join(reference, "bin/thrust")), "reference sanity check"
    end
  end

  # thecore_generators#23: non-interactive mode, installer chain declined. Fed empty
  # stdin (not "no\n") specifically to prove the template never reads from stdin at all
  # on this path -- if it fell through to the interactive `yes?` call despite the env
  # vars, this would hang (Open3.capture3 has no timeout) rather than fail cleanly, so
  # an empty-stdin run is a meaningfully stronger assertion than merely checking the
  # exit status afterward.
  #
  # THECORE_APP_TEMPLATE_RUN_INSTALLERS=true is deliberately NOT covered here: that
  # path performs a real `bundle install` plus several `rails generate`/`rails_command`
  # network-touching steps, the same "known non-blocking limitation" already documented
  # for the interactive "yes" path when thecore_generators#17 shipped (see this file's
  # own git history / docs/agents/app-template.md) -- kept as a manual-verification-only path for the same
  # reason, not an oversight.
  def test_non_interactive_mode_skips_installer_chain_when_run_installers_is_false
    Dir.mktmpdir do |dir|
      app_path = File.join(dir, "sample_app")

      stdout, stderr, status = spawn_rails_new(
        app_path, chdir: dir, stdin: "",
        extra_env: {
          "THECORE_APP_TEMPLATE_NON_INTERACTIVE" => "1",
          "THECORE_APP_TEMPLATE_RUN_INSTALLERS" => "false"
        }
      )
      assert status.success?, "expected a clean run with no stdin needed:\n#{stdout}\n#{stderr}"

      # An empty-stdin `yes?` call would itself resolve to "no" (matching this test's
      # own expected end-state) even without any non-interactive handling at all --
      # so the interactive prompt text's absence, not just the installer chain's, is
      # the one signal that actually distinguishes "the env vars were honored" from
      # "the old interactive path happened to land on the same answer by accident".
      refute_match(/Run `bundle install` and the standard installer generators/, stdout,
        "expected the interactive prompt never printed when THECORE_APP_TEMPLATE_NON_INTERACTIVE is set")

      # devise:install/rails_admin:install/active_storage:install are the installer
      # chain's own first steps -- their absence is the observable proof the chain
      # never ran, since none of the core Gemfile-stack code above this section creates
      # this file on its own.
      refute File.file?(File.join(app_path, "config/initializers/devise.rb")),
        "expected the installer chain to be skipped when THECORE_APP_TEMPLATE_RUN_INSTALLERS=false"
    end
  end

  def test_non_interactive_mode_aborts_when_run_installers_is_unset
    Dir.mktmpdir do |dir|
      app_path = File.join(dir, "sample_app")

      stdout, stderr, status = spawn_rails_new(
        app_path, chdir: dir, stdin: "",
        extra_env: { "THECORE_APP_TEMPLATE_NON_INTERACTIVE" => "1" }
      )
      refute status.success?, "expected the template to abort when the installer-chain choice is unspecified"
      assert_match(/THECORE_APP_TEMPLATE_RUN_INSTALLERS/, stdout + stderr,
        "expected the abort message to name the missing env var")
    end
  end

  def test_non_interactive_mode_aborts_when_run_installers_is_invalid
    Dir.mktmpdir do |dir|
      app_path = File.join(dir, "sample_app")

      stdout, stderr, status = spawn_rails_new(
        app_path, chdir: dir, stdin: "",
        extra_env: {
          "THECORE_APP_TEMPLATE_NON_INTERACTIVE" => "1",
          "THECORE_APP_TEMPLATE_RUN_INSTALLERS" => "please"
        }
      )
      refute status.success?, "expected the template to abort on an unrecognized value"
      assert_match(/THECORE_APP_TEMPLATE_RUN_INSTALLERS/, stdout + stderr,
        "expected the abort message to name the offending env var")
    end
  end

  private

  # THECORE_REAL_SAMPLES_DIR: unset/blank skips (offline default); set but not a
  # thecore samples directory fails, so a typo never turns into a silent skip.
  def real_samples_dir
    dir = ENV[REAL_SAMPLES_ENV].to_s.strip
    skip "#{REAL_SAMPLES_ENV} not set: point it at a thecore checkout's samples/ to run S1" if dir.empty?
    dir = File.expand_path(dir)
    assert File.file?(File.join(dir, "devcontainer", "devcontainer.json")),
      "#{REAL_SAMPLES_ENV}=#{dir} is not a thecore samples/ directory (no devcontainer/devcontainer.json)"
    dir
  end

  # The pilot's devcontainer practices: stale containers healed on the host before
  # compose starts, the host's docker.sock group handed to the app container, the host
  # home aliased for Claude Code's plugin paths, one SSH key per GitHub account, and the
  # plugin check -- each a script the container can run, wired where the pilot wires it.
  def assert_devcontainer_practices(app_path)
    %w[heal-stale-containers.sh docker-socket-gid.sh link-host-home.sh github-accounts.sh
       check-plugins.sh].each do |script|
      path = File.join(app_path, ".devcontainer", script)
      assert File.file?(path), "expected .devcontainer/#{script} in the generated app"
      assert File.executable?(path), "expected .devcontainer/#{script} to be executable"
    end

    devcontainer = parse_jsonc(File.read(File.join(app_path, ".devcontainer", "devcontainer.json")))
    post_create = devcontainer["postCreateCommand"].to_s.split("&&").map(&:strip)
    assert_includes post_create, "bash .devcontainer/github-accounts.sh",
      "expected postCreateCommand to run the multi-GitHub-account script"

    assert_host_paths_created_before_heal(devcontainer)

    # Every container process runs as the dev user, not root (root-owned binstubs break bundle).
    compose = YAML.safe_load(File.read(File.join(app_path, ".devcontainer", "docker-compose.yml")), aliases: true)
    app_service = compose.dig("services", devcontainer["service"])
    refute_nil app_service, "expected docker-compose.yml to define the #{devcontainer["service"]} service"
    assert_equal "vscode", app_service["user"], "expected the app service to run as user vscode"

    # docker.sock keeps the host's gid: docker-socket-gid.sh writes it to .devcontainer/.env,
    # the app service adds it, and that per-host .env never reaches git.
    assert_equal ["${DOCKER_SOCKET_GID:-996}"], app_service["group_add"],
      "expected the app service to group_add the host's docker.sock gid"
    gitignore = File.read(File.join(app_path, ".devcontainer", ".gitignore")).lines.map(&:strip)
    assert_includes gitignore, "/.env", "expected .devcontainer/.gitignore to keep the per-host .env out of git"
  end

  # On-demand system tests (ADR 0010 in thecore): the devcontainer runs a `selenium` browser the
  # app container reaches through SELENIUM_URL, and an `ldap` test server loaded from the LDIF it
  # mounts; the app's system test case drives that remote browser.
  def assert_system_test_practices(app_path)
    compose = YAML.safe_load(File.read(File.join(app_path, ".devcontainer", "docker-compose.yml")), aliases: true)
    services = compose.fetch("services")
    assert_match %r{\Aselenium/standalone-chromium:\d}, services.dig("selenium", "image").to_s,
      "expected a pinned selenium/standalone-chromium service"
    assert_equal "http://selenium:4444", services.dig("app", "environment", "SELENIUM_URL"),
      "expected the app service to point SELENIUM_URL at the selenium service"
    assert_match %r{\Aosixia/openldap:\d}, services.dig("ldap", "image").to_s, "expected a pinned osixia/openldap service"
    ldif = services.dig("ldap", "volumes").to_a.map { |v| v.split(":").first }
    assert_includes ldif, "./ldap-users.ldif", "expected the ldap service to load .devcontainer/ldap-users.ldif"
    assert File.file?(File.join(app_path, ".devcontainer", "ldap-users.ldif")), "expected .devcontainer/ldap-users.ldif"

    system_test_case = File.read(File.join(app_path, "test", "application_system_test_case.rb"))
    assert_includes system_test_case, %(ENV["SELENIUM_URL"]), "expected the system test case to use SELENIUM_URL"
    assert Dir[File.join(app_path, "test", "system", "*_test.rb")].any?, "expected at least one system test"
  end

  # Top-level keys GitHub Actions accepts in a workflow file; any other key (such as a
  # docker-compose style `x-...` anchor holder) makes GitHub reject the whole workflow.
  GITHUB_WORKFLOW_KEYS = %w[name run-name on permissions env defaults concurrency jobs].freeze

  def assert_github_workflow_practices(app_path)
    workflows = Dir[File.join(app_path, ".github", "workflows", "*.{yml,yaml}")]
    refute_empty workflows, "expected the generated app to carry GitHub workflows"
    workflows.each do |path|
      # Psych reads a bare `on:` key as `true`.
      keys = YAML.safe_load(File.read(path), aliases: true).keys.map { |key| key == true ? "on" : key.to_s }
      assert_empty keys - GITHUB_WORKFLOW_KEYS,
        "#{File.basename(path)} has top-level keys GitHub Actions rejects"
    end
  end

  HEAL_CALL = "bash .devcontainer/heal-stale-containers.sh '${localWorkspaceFolder}'"
  SOCKET_GID_CALL = "bash .devcontainer/docker-socket-gid.sh"

  # Every active bind mount must have its host path created by initializeCommand (on the
  # host, before `docker compose up`), or a fresh machine can't start the container: a
  # missing directory fails the mount, a missing file becomes a directory. The heal call
  # follows, then the docker.sock gid call last. Checked by running the part before the heal call against an empty HOME
  # (the ~/.claude.json mount is a file, the others directories), then against a HOME
  # whose ~/.claude.json already has content, which must survive.
  def assert_host_paths_created_before_heal(devcontainer)
    command = devcontainer["initializeCommand"].to_s
    assert command.end_with?("#{HEAL_CALL} && #{SOCKET_GID_CALL}"),
      "expected initializeCommand to end by running the heal script on the workspace folder, " \
      "then the docker.sock gid script, got: #{command}"
    setup = command.delete_suffix(SOCKET_GID_CALL).strip.delete_suffix("&&").strip
      .delete_suffix(HEAL_CALL).strip.delete_suffix("&&").strip

    sources = Array(devcontainer["mounts"]).filter_map do |mount|
      mount[/(?:\A|,)source=([^,]+)/, 1] if mount.include?("type=bind")
    end
    assert_includes sources, "${localEnv:HOME}/.claude.json", "expected the ~/.claude.json mount to be active"
    assert_includes sources, "${localEnv:HOME}/.claude", "expected the ~/.claude mount to be active"

    Dir.mktmpdir do |home|
      run_with_home = lambda do
        _out, err, status = Open3.capture3("bash", "-c", setup.gsub("${localEnv:HOME}", home))
        assert status.success?, "initializeCommand's host-path setup failed: #{err}"
      end

      run_with_home.call
      sources.each do |source|
        path = source.gsub("${localEnv:HOME}", home)
        if source.end_with?(".json")
          assert File.file?(path), "expected initializeCommand to create the mounted file #{source}"
        else
          assert File.directory?(path), "expected initializeCommand to create the mounted directory #{source}"
        end
      end

      claude_json = File.join(home, ".claude.json")
      File.write(claude_json, %({"kept":true}))
      run_with_home.call
      assert_equal %({"kept":true}), File.read(claude_json), "expected an existing ~/.claude.json to be left untouched"
    end
  end

  # The pilot has no root Dockerfile: the Thecore build script (`app-compile.sh` in
  # thecore_devcontainer) prefers a root `Dockerfile` when one exists, so the Kamal-style
  # one `rails new` 7.2 generates (and the entrypoint script it runs) must not survive,
  # or CI would build the app with it instead of the Thecore Dockerfile.
  def assert_docker_build_practices(app_path)
    refute File.exist?(File.join(app_path, "Dockerfile")),
      "expected no root Dockerfile, so the Thecore build script uses the Thecore Dockerfile"
    refute File.exist?(File.join(app_path, "bin", "docker-entrypoint")),
      "expected no bin/docker-entrypoint (only the removed Rails Dockerfile runs it)"
  end

  GITLAB_SECURITY_TEMPLATES = %w[Jobs/SAST.gitlab-ci.yml Jobs/Secret-Detection.gitlab-ci.yml].freeze
  # The template jobs those two includes define, and the jobs the sample adds itself.
  GITLAB_SCANNER_JOBS = %w[semgrep-sast secret_detection].freeze
  GITLAB_SECURITY_JOBS = %w[brakeman bundler-audit security-summary].freeze
  GITLAB_SCHEDULE_EXCLUDED_JOBS = %w[build test lint to-dev to-prod].freeze
  SUMMARY_COMMAND = "ruby script/security_summary.rb gl-sast-report.json gl-secret-detection-report.json"

  # The pilot's security CI (mytask-imas .gitlab-ci.yml, CLAUDE.md "Security scanning"):
  # on GitLab, SAST and Secret Detection, brakeman, bundler-audit failing only on the
  # nightly schedule, a security-summary job turning the CE reports into an orange job,
  # every security job starting with the pipeline, and the nightly schedule never building,
  # testing or deploying; on GitHub, brakeman and bundler-audit (nightly too) outside the
  # version-gated CI. The summary script and its test come with the app, and the test passes there.
  def assert_security_ci_practices(app_path)
    gitlab = YAML.safe_load(File.read(File.join(app_path, ".gitlab-ci.yml")), aliases: true)

    includes = Array(gitlab["include"]).map { |i| i.is_a?(Hash) ? i["template"] : i }
    GITLAB_SECURITY_TEMPLATES.each do |template|
      assert_includes includes, template, "expected .gitlab-ci.yml to include the #{template} template"
    end
    schedule_rule = Array(gitlab.dig("workflow", "rules")).find { |r| r["if"].to_s.include?('"schedule"') }
    refute_nil schedule_rule, "expected a workflow rule for scheduled pipelines"
    %w[SAST_DISABLED SECRET_DETECTION_DISABLED].each do |var|
      assert_equal "true", schedule_rule.dig("variables", var).to_s,
        "expected scheduled pipelines to set #{var}, so the nightly runs bundler-audit only"
    end

    (GITLAB_SCANNER_JOBS + GITLAB_SECURITY_JOBS).each do |name|
      job = gitlab_job(gitlab, name)
      if name == "security-summary"
        needed = Array(job["needs"]).map { |n| n.is_a?(Hash) ? n["job"] : n }
        assert_equal GITLAB_SCANNER_JOBS.sort, needed.sort,
          "expected security-summary to wait only for the two scanners"
      else
        assert_equal [], job["needs"], "expected #{name} to start with the pipeline (needs: [])"
      end
    end

    brakeman = gitlab_job(gitlab, "brakeman")
    assert brakeman["allow_failure"], "expected brakeman to report only (allow_failure)"
    assert(Array(brakeman["script"]).any? { |c| c.match?(/\Abrakeman\b/) }, "expected the brakeman job to run brakeman")

    audit = gitlab_job(gitlab, "bundler-audit")
    assert(Array(audit["script"]).any? { |c| c.include?("bundle-audit check --update") },
      "expected the bundler-audit job to run `bundle-audit check --update`")
    audit_rules = Array(audit["rules"])
    nightly = audit_rules.find { |r| r["if"].to_s.include?('"schedule"') }
    on_push = audit_rules.find { |r| r["if"].to_s.include?('"push"') }
    refute_nil nightly, "expected bundler-audit to run on the nightly schedule"
    assert_equal false, nightly["allow_failure"], "expected the nightly bundler-audit to fail the pipeline"
    refute_nil on_push, "expected bundler-audit to run on every push"
    assert_equal true, on_push["allow_failure"], "expected bundler-audit on push to report only"

    summary = gitlab_job(gitlab, "security-summary")
    assert summary["allow_failure"], "expected security-summary to turn orange, not red"
    assert_includes Array(summary["script"]), SUMMARY_COMMAND, "expected security-summary to run the summary script"

    GITLAB_SCHEDULE_EXCLUDED_JOBS.each do |name|
      job = gitlab.fetch(name) { flunk "expected a `#{name}` job in .gitlab-ci.yml" }
      assert_includes Array(job.dig("except", "refs")), "schedules",
        "expected #{name} never to run in the nightly security schedule"
    end

    github_ci = YAML.safe_load(File.read(File.join(app_path, ".github/workflows/ci.yml")), aliases: true)
    refute github_ci.fetch(true, github_ci["on"]).to_h.key?("schedule"),
      "expected the GitHub build/test/lint/deploy workflow never to run on a schedule"

    security_path = File.join(app_path, ".github/workflows/security.yml")
    assert File.file?(security_path), "expected a GitHub security workflow"
    github = YAML.safe_load(File.read(security_path), aliases: true)
    triggers = github.fetch(true, github["on"]).to_h # YAML 1.1 reads a bare `on:` key as true
    assert triggers.key?("push"), "expected the GitHub security workflow to run on every push"
    refute triggers["push"].to_h.key?("paths"), "expected the GitHub security workflow not to wait for a version bump"
    assert triggers.key?("schedule"), "expected the GitHub security workflow to run nightly"
    runs = ->(job) { Array(github.dig("jobs", job, "steps")).filter_map { |s| s["run"] }.join("\n") }
    assert_match(/^brakeman\b/, runs.call("brakeman"), "expected a GitHub brakeman job")
    assert_includes runs.call("bundler-audit"), "bundle-audit check --update", "expected a GitHub bundler-audit job"
    assert_equal true, github.dig("jobs", "brakeman", "continue-on-error"), "expected GitHub brakeman to report only"
    assert_match(/schedule/, github.dig("jobs", "bundler-audit", "continue-on-error").to_s,
      "expected GitHub bundler-audit to fail only on the nightly schedule")

    %w[script/security_summary.rb test/script/security_summary_test.rb].each do |file|
      assert File.file?(File.join(app_path, file)), "expected #{file} in the generated app"
    end
    output, status = Open3.capture2e(RbConfig.ruby, "test/script/security_summary_test.rb", chdir: app_path)
    assert status.success?, "expected the security summary's test to pass in the generated app:\n#{output}"
    assert_match(/\b3 runs, .*\b0 failures, 0 errors\b/, output, "expected the summary test's three cases to run")

    claude_md = File.read(File.join(app_path, "CLAUDE.md"))
    scanning = markdown_section(claude_md, "## Security scanning")
    ["brakeman", "bundler-audit", "SAST", "Secret Detection", "security-summary", "script/security_summary.rb",
     "schedule", "allow_failure", "needs: []", ".github/workflows/security.yml"].each do |term|
      assert_includes scanning, term, "expected \"Security scanning\" in CLAUDE.md to cover #{term}"
    end
  end

  # A GitLab job with its `extends` (hidden jobs in the same file) merged in, as GitLab does.
  def gitlab_job(gitlab, name)
    job = gitlab.fetch(name) { flunk "expected a `#{name}` job in .gitlab-ci.yml" }
    Array(job["extends"]).reverse.reduce(job.except("extends")) do |merged, parent|
      gitlab_job(gitlab, parent).merge(merged)
    end
  end

  # Each gem's first release with the fix the pilot (mytask-imas) depends on, and the
  # last release without it: the generated Gemfile must accept the first and refuse the
  # second, so a `bundle update --conservative` from an old lock can't stay below it.
  # The transitive ones (thecore_auth_commons, thecore_backend_commons) need their own
  # line for that.
  GEM_FLOORS = {
    "rails" => %w[8.1.4.1 8.1.4], # the 2026-11-04 security fixes (21 advisories)
    "puma" => %w[7.2.1 7.2.0], # PROXY protocol v1 CVE-2026-47736/47737
    "model_driven_api" => %w[3.13.2 3.13.1], # JSON with include: works on Rails 8.1 (3.13.1: no class instantiated from the path)
    "thecore_auth_commons" => %w[3.6.3 3.6.2], # OAuth takes the identity only from OmniAuth
    "thecore_backend_commons" => %w[3.11.0 3.10.0], # resolves on Rails 8.1 (3.10.0: no job retries, failures capped)
    "thecore_ui_rails_admin" => %w[3.8.7 3.8.6] # RailsAdmin's User create form answered 500 under Devise 5
  }.freeze
  # Kept on the pilot's redis 5 line: redis 6 is untried with redis-namespace and Sidekiq 7.
  REDIS_BROKEN = "6.0.0"

  # The pilot's Gemfile floors and pins (thecore_devcontainer#17), checked twice: on the
  # Gemfile's requirements, and on a real `bundle lock` against rubygems.org, which must
  # resolve and pick versions the app can boot with.
  def assert_gem_floor_practices(app_path)
    gemfile = File.join(app_path, "Gemfile")
    dsl = Bundler::Dsl.new
    dsl.eval_gemfile(gemfile)
    requirements = dsl.dependencies.group_by(&:name).transform_values { |deps| deps.map(&:requirement) }

    GEM_FLOORS.each do |name, (fixed, vulnerable)|
      reqs = requirements[name]
      assert reqs, "expected the Gemfile to declare #{name}, to set its floor"
      assert reqs.all? { |r| r.satisfied_by?(Gem::Version.new(fixed)) }, "expected the Gemfile to accept #{name} #{fixed}"
      refute reqs.all? { |r| r.satisfied_by?(Gem::Version.new(vulnerable)) },
        "expected the Gemfile to refuse #{name} #{vulnerable}"
    end
    assert requirements["redis"], "expected the Gemfile to pin redis for Action Cable's adapter"
    refute requirements["redis"].all? { |r| r.satisfied_by?(Gem::Version.new(REDIS_BROKEN)) },
      "expected the Gemfile to refuse redis #{REDIS_BROKEN}, which the pilot hasn't tried"

    stdout, stderr, status = Bundler.with_unbundled_env do
      Open3.capture3({ "BUNDLE_GEMFILE" => gemfile }, "bundle", "lock", chdir: app_path)
    end
    assert status.success?, "`bundle lock` of the generated app failed:\n#{stdout}\n#{stderr}"
    locked = Bundler::LockfileParser.new(File.read("#{gemfile}.lock")).specs.to_h { |s| [s.name, s.version] }
    GEM_FLOORS.each do |name, (fixed, _)|
      assert_operator locked.fetch(name), :>=, Gem::Version.new(fixed), "expected #{name} >= #{fixed} in the lock"
    end
    assert_operator locked.fetch("redis"), :<, Gem::Version.new(REDIS_BROKEN), "expected redis < 6 in the lock"
    # Sidekiq 7 (via thecore_background_jobs) broke on connection_pool 3; 7.3.10 caps it itself.
    assert_operator locked.fetch("connection_pool"), :<, Gem::Version.new("3"), "expected connection_pool 2.x in the lock"
  end

  AGENT_DOCS = %w[issue-tracker.md triage-labels.md domain.md].freeze
  TRIAGE_LABELS = %w[needs-triage needs-info ready-for-agent ready-for-human wontfix].freeze
  # Customer-specific practices of the pilot that must never reach a generic app.
  CUSTOMER_SPECIFIC = /Odoo|Odooly|VPN|MS ?SQL|SQL Server|tiny_?tds|IMAS|Gamma|Bancolini/i

  # The pilot's agent docs (thecore_devcontainer#13): docs/agents/ telling skills where
  # tickets go, an AGENTS.md that only points to CLAUDE.md, and a CLAUDE.md stating the
  # rules the pilot learned -- with none of the pilot's customer-specific content.
  def assert_agent_docs_practices(app_path)
    AGENT_DOCS.each do |doc|
      assert File.file?(File.join(app_path, "docs", "agents", doc)), "expected docs/agents/#{doc} in the generated app"
    end

    tracker = File.read(File.join(app_path, "docs", "agents", "issue-tracker.md"))
    assert_match(/git remote get-url origin/, tracker, "expected the issue tracker to be chosen from the git remote")
    assert_match(/GitHub Issues/, tracker, "expected GitHub Issues as the tracker for a github.com remote")
    assert_match(/GitLab Issues/, tracker, "expected GitLab Issues as the tracker for a GitLab remote")
    assert_match(/`gh issue create/, tracker, "expected the gh commands for GitHub Issues")
    assert_match(/`glab issue create/, tracker, "expected the glab commands for GitLab Issues")

    labels = File.read(File.join(app_path, "docs", "agents", "triage-labels.md"))
    TRIAGE_LABELS.each { |label| assert_includes labels, "`#{label}`", "expected the #{label} triage label" }

    agents_md_path = File.join(app_path, "AGENTS.md")
    assert File.file?(agents_md_path), "expected AGENTS.md in the generated app"
    agents_md = File.read(agents_md_path)
    assert_match(/CLAUDE\.md/, agents_md, "expected AGENTS.md to point to CLAUDE.md")
    assert_operator agents_md.lines.count { |l| !l.strip.empty? }, :<=, 10,
      "expected AGENTS.md to only point to CLAUDE.md, not duplicate it"

    claude_md = File.read(File.join(app_path, "CLAUDE.md"))
    atom = markdown_section(claude_md, "## Changing an ATOM")
    ["vendor/submodules/", "git submodule add -b release/3", "release/3", "--conservative", "Gemfile.lock"].each do |step|
      assert_includes atom, step, "expected \"Changing an ATOM\" to cover #{step}"
    end

    skills = markdown_section(claude_md, "## Agent skills")
    %w[issue-tracker triage-labels domain].each do |doc|
      assert_includes skills, "docs/agents/#{doc}.md", "expected \"Agent skills\" to point to docs/agents/#{doc}.md"
    end

    conventions = markdown_section(claude_md, "## Code conventions")
    assert_match(/retr(y|ied)/i, conventions, "expected the no-job-retries rule")
    assert_match(/serializable/i, conventions, "expected the serializable job arguments rule")
    assert_match(/Base64/, conventions, "expected the Base64-for-binary job arguments rule")
    assert_match(/Arel\.sql/, conventions, "expected the Arel.sql rule")
    assert_match(/ThecoreSettings::Setting\.find_by/, conventions, "expected the settings-read-at-runtime rule")
    assert_match(%r{vendor/deploytargets/.*SECRET_KEY_BASE|SECRET_KEY_BASE.*vendor/deploytargets/}m, claude_md,
      "expected the no-secrets-in-vendor/deploytargets/ rule")

    plugin = markdown_section(claude_md, "## Claude Code skills")
    assert_match(/User-invoked only/, plugin, "expected the user-invoked skills listed")
    assert_match(/Model-invocable/, plugin, "expected the model-invocable skills listed")

    commands = markdown_section(claude_md, "## Common commands")
    assert_includes commands, "thecore:atom", "expected thecore:atom among the common commands"
    assert_includes commands, "thecore:collection_action", "expected thecore:collection_action among the common commands"

    (["CLAUDE.md", "AGENTS.md"] + AGENT_DOCS.map { |d| "docs/agents/#{d}" }).each do |file|
      refute_match CUSTOMER_SPECIFIC, File.read(File.join(app_path, file)), "#{file} carries customer-specific content"
    end
  end

  # The text under a Markdown heading, up to the next heading of the same or higher level
  # (a `#` line inside a fenced code block is a shell comment, not a heading).
  def markdown_section(text, heading)
    level = heading[/\A#+/].size
    lines = text.lines
    start = lines.index { |l| l.chomp == heading }
    assert start, "expected a \"#{heading}\" section"
    in_fence = false
    section = [lines[start]]
    lines[(start + 1)..].each do |line|
      in_fence = !in_fence if line.start_with?("```")
      break if !in_fence && line.match?(/\A\#{1,#{level}} /)

      section << line
    end
    section.join
  end

  # The pilot's test-database rule (mytask-imas test/test_helper.rb): the devcontainer's
  # global DATABASE_URL points at development, so the test helper swaps whatever database
  # it names for `<app>_test` before the app boots -- running tests never wipes dev data.
  # Observed by loading the generated helper and stopping at its first require_relative
  # (config/environment), where the app would read DATABASE_URL.
  def assert_test_database_practices(app_path)
    {
      "postgres://postgres:postgres@db:5432/app_dev?pool=5" => "postgres://postgres:postgres@db:5432/sample_app_test?pool=5",
      "postgres://postgres:postgres@db:5432/anything_else" => "postgres://postgres:postgres@db:5432/sample_app_test",
      # Server only, no database (the CI samples' form): still the test database.
      "postgres://postgres:postgres@db:5432" => "postgres://postgres:postgres@db:5432/sample_app_test"
    }.each do |dev_url, test_url|
      assert_equal test_url, database_url_seen_by_test_helper(app_path, dev_url),
        "expected test/test_helper.rb to swap DATABASE_URL=#{dev_url} for the test database"
    end
    assert_equal "", database_url_seen_by_test_helper(app_path, nil),
      "expected test/test_helper.rb to leave DATABASE_URL unset when it is unset"
  end

  def database_url_seen_by_test_helper(app_path, database_url)
    # Stdlib the helper may require is preloaded, so that only the helper's own
    # require_relative of config/environment reaches the stub.
    probe = <<~'RUBY'
      require "uri"
      $stdout.sync = true
      def require_relative(path)
        abort "unexpected require_relative #{path}" unless path.end_with?("config/environment")
        print ENV["DATABASE_URL"].to_s
        exit!(0)
      end
      load "test/test_helper.rb"
    RUBY
    env = { "DATABASE_URL" => database_url }
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-e", probe, chdir: app_path)
    assert status.success?, "loading test/test_helper.rb failed:\n#{stderr}"
    stdout
  end

  # Both CI samples' test jobs can actually reach a database: a Postgres service, a
  # DATABASE_URL naming only that service (so database.yml's `<app>_test` applies, the
  # same name the test helper forces), RAILS_ENV=test, and the test database prepared
  # before the tests run -- `rails test` alone fails with NoDatabaseError on a fresh server.
  def assert_ci_test_database_practices(app_path)
    gitlab = YAML.safe_load(File.read(File.join(app_path, ".gitlab-ci.yml")), aliases: true)
    test_job = gitlab.fetch("test") { flunk "expected a `test` job in .gitlab-ci.yml" }
    service = Array(test_job["services"]).map { |s| s.is_a?(Hash) ? s : { "name" => s } }
      .find { |s| s["name"].to_s.start_with?("postgres") }
    refute_nil service, "expected the GitLab test job to declare a Postgres service"
    gitlab_vars = (gitlab["variables"] || {}).merge(test_job["variables"] || {})
    gitlab_host = service["alias"] || service["name"].split(":").first
    assert_ci_database_url(gitlab_vars["DATABASE_URL"], gitlab_host, gitlab_vars["POSTGRES_PASSWORD"], "GitLab")
    assert_equal "test", gitlab_vars["RAILS_ENV"], "expected the GitLab test job to set RAILS_ENV=test"
    assert_ci_prepares_test_database(Array(test_job["script"]), "GitLab")

    github = YAML.safe_load(File.read(File.join(app_path, ".github/workflows/ci.yml")), aliases: true)
    test_job = github.dig("jobs", "test") || flunk("expected a `test` job in .github/workflows/ci.yml")
    service_name, service = (test_job["services"] || {}).find { |_, s| s["image"].to_s.start_with?("postgres") }
    refute_nil service, "expected the GitHub test job to declare a Postgres service"
    github_env = (github["env"] || {}).merge(test_job["env"] || {})
    assert_ci_database_url(github_env["DATABASE_URL"], service_name, service.dig("env", "POSTGRES_PASSWORD"), "GitHub")
    assert_equal "test", github_env["RAILS_ENV"], "expected the GitHub test job to set RAILS_ENV=test"
    assert_ci_prepares_test_database(test_job["steps"].filter_map { |step| step["run"] }, "GitHub")
  end

  def assert_ci_database_url(url, host, password, ci)
    refute_nil url, "expected the #{ci} test job to set DATABASE_URL"
    uri = URI.parse(url)
    assert_equal "postgres", uri.scheme.sub(/ql\z/, ""), "expected the #{ci} DATABASE_URL to be a Postgres URL"
    assert_equal host, uri.host, "expected the #{ci} DATABASE_URL to point at the Postgres service"
    assert_equal password.to_s, uri.password.to_s, "expected the #{ci} DATABASE_URL to use the service's password"
    assert_includes ["", "/"], uri.path, "expected the #{ci} DATABASE_URL to name only the server, not a database"
  end

  def assert_ci_prepares_test_database(commands, ci)
    prepare = commands.index { |c| c.match?(/\brails db:test:prepare\b/) }
    run = commands.index { |c| c.match?(/\brails test\b/) }
    refute_nil run, "expected the #{ci} test job to run `rails test`"
    refute_nil prepare, "expected the #{ci} test job to run `rails db:test:prepare`"
    assert_operator prepare, :<, run, "expected the #{ci} test job to prepare the test database before the tests"
  end

  # devcontainer.json is JSONC: drops // and /* */ comments outside strings and
  # trailing commas, then parses it as JSON.
  def parse_jsonc(text)
    out = +""
    i = 0
    in_string = false
    while i < text.length
      c = text[i]
      if in_string
        out << c
        if c == "\\"
          out << text[i + 1].to_s
          i += 1
        elsif c == '"'
          in_string = false
        end
      elsif c == '"'
        in_string = true
        out << c
      elsif text[i, 2] == "//"
        i += 1 until i >= text.length || text[i] == "\n"
        next
      elsif text[i, 2] == "/*"
        i = (text.index("*/", i + 2) || text.length - 2) + 2
        next
      else
        out << c
      end
      i += 1
    end
    JSON.parse(out.gsub(/,(\s*[}\]])/, "\\1"))
  end

  # Extracted so thecore_generators#18 (which extends this same test with
  # devcontainer/CI/CLAUDE.md asset assertions against the same generated app, per its
  # own acceptance criteria) can reuse this exact invocation rather than re-deriving
  # the `chdir`/`BUNDLE_GEMFILE`/stdin dance below a second time. `extra_env:` was added
  # for thecore_generators#23's non-interactive-mode tests, merged over the base env
  # below so callers can override `THECORE_APP_TEMPLATE_NON_INTERACTIVE`/
  # `THECORE_APP_TEMPLATE_RUN_INSTALLERS` without needing to know the base env exists.
  def spawn_rails_new(app_path, chdir:, stdin: "no\n", extra_env: {})
    # `chdir` is deliberately the scratch tmp dir, NOT this gem's own root: plain
    # `rails` (railties' exe/rails, via Rails::AppLoader.exec_app) walks *up* the
    # directory tree from cwd looking for a `bin/rails` to delegate to before it
    # ever runs as the `rails new` generator (see this gem's own CLAUDE.md,
    # "Dir.pwd cannot be trusted..."). thecore_generators lives nested under this
    # host backend repo, which has its own `bin/rails` a few directories up — cwd'd
    # there, that walk-up would silently exec the *host app's* bin/rails instead of
    # generating a new app. `BUNDLE_GEMFILE` (rather than cwd) is what tells
    # Bundler which bundle's `rails` gem to resolve.
    env = {
      "BUNDLE_GEMFILE" => File.join(GEM_ROOT, "Gemfile"),
      # thecore_generators#18: points the template's asset-fetch step at the local
      # fixture above instead of the real raw GitHub URL it defaults to.
      "THECORE_SAMPLES_SOURCE" => SAMPLES_FIXTURE_DIR
    }.merge(extra_env)

    Open3.capture3(
      env,
      "bundle", "exec", "rails", "new", app_path,
      "--database=postgresql", "--asset-pipeline=sprockets",
      "--skip-bundle", "--skip-git", "--quiet",
      "-m", TEMPLATE_PATH,
      stdin_data: stdin,
      chdir: chdir
    )
  end
end
