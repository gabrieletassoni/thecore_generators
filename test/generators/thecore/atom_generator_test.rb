require "test_helper"
require "generators/thecore/atom/atom_generator"
require "fileutils"
require "tmpdir"
require "open3"

class Thecore::Generators::AtomGeneratorTest < Rails::Generators::TestCase
  tests Thecore::Generators::AtomGenerator

  GEM_ROOT = File.expand_path("../../..", __dir__)

  # Same fixture tree test/templates/app_template_test.rb already points
  # THECORE_SAMPLES_SOURCE at (thecore_generators#18/#22) - reused, not
  # duplicated, so the two test suites can never drift on what "the samples
  # fixture" contains. Anchored off GEM_ROOT (not a hand-counted "../../" from
  # this file's own nesting depth) so it stays correct if either test file ever
  # moves - app_template_test.rb's own copy of this constant predates this one
  # and still uses the hand-counted form.
  SAMPLES_FIXTURE_DIR = File.join(GEM_ROOT, "test", "fixtures", "thecore_samples")

  # Deliberately NOT under this gem's own tmp/ (unlike every other generator test in
  # this suite) - #create_rails_engine shells out to a real `bundle exec rails
  # plugin new`, and plain `rails` (railties' exe/rails, via
  # Rails::AppLoader.exec_app) walks *up* the directory tree from cwd looking for a
  # bin/rails to delegate to before ever running as the `plugin new` generator. This
  # gem lives nested under the host backend repo, which has its own bin/rails a few
  # directories up - a destination_root under this gem's own tmp/ would hit that
  # walk-up and silently delegate into the *host app's* bin/rails instead (the exact
  # trap test/templates/app_template_test.rb already documents and hit directly
  # while writing thecore_generators#17). A path under the system tmp dir means the
  # walk-up finds nothing to delegate to, so `bundle exec rails plugin new` runs
  # generically, as intended.
  destination File.join(Dir.tmpdir, "thecore_generators_atom_test")

  NON_INTERACTIVE_ARGS = [
    "--non-interactive",
    "--summary=TCP Debugger",
    "--description=Debugs TCP connections",
    "--author=Alchemic IT",
    "--email=dev@alchemic.it",
    "--url=https://github.com/example/tcp_debugger",
  ].freeze

  # point_samples_source_at_fixture! runs first, deliberately: if a later setup
  # callback raises, teardown still runs, and restore_samples_source! must have
  # something real to restore rather than wiping out a developer's own exported
  # THECORE_SAMPLES_SOURCE for the rest of the (single, shared - no parallel
  # workers in this suite) test process.
  setup :point_samples_source_at_fixture!
  setup :prepare_destination
  setup :create_vendor_submodules_dir!
  setup :create_host_gemfile!
  teardown :restore_samples_source!

  test "fails with a clear error when vendor/submodules doesn't exist yet" do
    FileUtils.rm_rf(File.join(destination_root, "vendor"))

    error = assert_raises(Thor::Error) { run_generator ["tcp_debugger"] + NON_INTERACTIVE_ARGS, debug: true }
    assert_match(/vendor\/submodules does not exist/, error.message)
  end

  test "rejects a name with shell metacharacters or spaces instead of word-splitting into the shell-out" do
    error = assert_raises(Thor::Error) { run_generator ["tcp debugger"] + NON_INTERACTIVE_ARGS, debug: true }
    assert_match(/not a valid ATOM name/, error.message)
  end

  test "refuses to overwrite an existing vendor/submodules entry with the same name" do
    FileUtils.mkdir_p(File.join(destination_root, "vendor", "submodules", "tcp_debugger"))

    error = assert_raises(Thor::Error) { run_generator ["tcp_debugger"] + NON_INTERACTIVE_ARGS, debug: true }
    assert_match(/tcp_debugger already exists/, error.message)
  end

  test "--non-interactive without the required flags aborts, listing exactly what's missing" do
    error = assert_raises(Thor::Error) do
      run_generator ["tcp_debugger", "--non-interactive", "--summary=Only this one"], debug: true
    end
    assert_match(/--description/, error.message)
    assert_match(/--author/, error.message)
    assert_match(/--email/, error.message)
    assert_match(/--url/, error.message)
    refute_match(/--summary/, error.message)
  end

  test "generates a complete ATOM end-to-end with default (included) API/Admin dependencies" do
    output = run_generator ["tcp_debugger"] + NON_INTERACTIVE_ARGS

    atom = "vendor/submodules/tcp_debugger"

    # The dummy app runs on PostgreSQL, the only database Thecore targets (never SQLite).
    assert_file "#{atom}/test/dummy/config/database.yml" do |content|
      config = YAML.safe_load(content, aliases: true)
      %w[development test production].each do |env|
        assert_equal "postgresql", config[env]["adapter"], "#{env} should use PostgreSQL"
        assert_equal "tcp_debugger_#{env}", config[env]["database"]
      end
    end
    assert_file "#{atom}/Gemfile" do |content|
      refute_match(/sqlite3/, content)
      assert_equal 1, content.scan(/^\s*gem\s+["']pg["']/).size, "pg should be declared exactly once"
    end

    # The test-database rule: under the devcontainer's global DATABASE_URL (pointing at the
    # host app's development database), a test run keeps the server/credentials but always
    # uses the ATOM's own test database, so running the tests never touches development data.
    assert_equal "postgres://postgres:postgres@db:5432/tcp_debugger_test?sslmode=disable",
      database_url_seen_by_dummy_boot(atom, "postgres://postgres:postgres@db:5432/myapp_development?sslmode=disable")
    # A URL naming only the server (the CI samples' form) keeps its host and gains the database.
    assert_equal "postgres://postgres:postgres@db:5432/tcp_debugger_test",
      database_url_seen_by_dummy_boot(atom, "postgres://postgres:postgres@db:5432")
    assert_file "#{atom}/test/test_helper.rb" do |content|
      assert_operator content.index('ENV["RAILS_ENV"] = "test"'), :<,
        content.index("require_relative \"../test/dummy/config/environment\""),
        "the test helper must set RAILS_ENV=test before booting the dummy app"
    end

    # Only Thecore's CI: none of the workflow/dependabot files `rails plugin new` adds by itself.
    workflows = Dir.children(File.join(destination_root, atom, ".github/workflows")) - [".keep"]
    assert_equal ["gempush.yml"], workflows
    assert_no_file "#{atom}/.github/dependabot.yml"
    assert_file "#{atom}/.gitlab-ci.yml"

    # Next steps follow the pilot's "Changing an ATOM" workflow.
    assert_includes output, "git submodule add -b release/3 <remote-url> vendor/submodules/tcp_debugger"
    assert_includes output, 'gem "tcp_debugger", path: "vendor/submodules/tcp_debugger"'
    assert_includes output, "bundle update tcp_debugger --conservative"
    # The ATOM's own tests: create its test database first, then the Rails test runner.
    assert_includes output, "bundle install && bin/rails db:create && bin/rails test"
    refute_includes output, "rake test"

    assert_file "#{atom}/lib/tcp_debugger/engine.rb"
    assert_file "#{atom}/tcp_debugger.gemspec" do |content|
      assert_match(/spec\.authors\s*=\s*\["Alchemic IT"\]/, content)
      assert_match(/spec\.email\s*=\s*\["dev@alchemic\.it"\]/, content)
      assert_match(/spec\.homepage\s*=\s*"https:\/\/github\.com\/example\/tcp_debugger"/, content)
      assert_match(/spec\.summary\s*=\s*"TCP Debugger"/, content)
      assert_match(/spec\.description\s*=\s*"Debugs TCP connections"/, content)
      assert_match(/spec\.add_dependency "rails"/, content)
      # 3.13.2: older ones raise FrozenError rendering JSON with include: on Rails 8.1.
      assert_match(/spec\.add_dependency "model_driven_api", "~> 3\.13", ">= 3\.13\.2"/, content)
      assert_match(/spec\.add_dependency "thecore_ui_rails_admin", "~> 3\.8"/, content)
      assert_match(/spec\.metadata\["allowed_push_host"\]\s*=\s*"https:\/\/rubygems\.org"/, content)
      assert_match(/spec\.metadata\["source_code_uri"\]\s*=\s*spec\.homepage/, content)
      assert_match(/spec\.metadata\["changelog_uri"\]\s*=\s*"#\{spec\.homepage\}\/blob\/release\/3\/CHANGELOG\.md"/, content)
    end

    assert_file "#{atom}/Gemfile" do |content|
      assert_match(/^gem ["']pg["']/, content)
      assert_match(/gem 'model_driven_api', '~> 3\.13', '>= 3\.13\.2'/, content)
      assert_match(/gem 'thecore_ui_rails_admin', '~> 3\.8'/, content)
    end
    assert_file "#{atom}/lib/tcp_debugger.rb" do |content|
      assert_match(/require 'model_driven_api'/, content)
      assert_match(/require 'thecore_ui_rails_admin'/, content)
    end

    %w[
      db/migrate app/models/concerns/api app/models/concerns/rails_admin
      config/initializers config/locales lib/root_actions lib/member_actions
      lib/collection_actions app/assets/javascripts app/assets/stylesheets
      app/views/rails_admin/main .github/workflows
    ].each { |dir| assert_file "#{atom}/#{dir}/.keep" }

    assert_file "#{atom}/config/initializers/after_initialize.rb", /config\.after_initialize do/
    assert_file "#{atom}/config/initializers/add_to_db_migration.rb", /paths\['db\/migrate'\]/
    assert_file "#{atom}/config/initializers/assets.rb", /config\.assets\.precompile/
    assert_file "#{atom}/config/initializers/abilities.rb" do |content|
      assert_match(/module Abilities/, content)
      assert_match(/class TcpDebugger/, content)
    end
    assert_file "#{atom}/db/seeds.rb", /Seeding Data into DB from tcp_debugger/

    # The host-app pieces the Thecore engines need at boot, in the dummy app.
    assert_file "#{atom}/test/dummy/app/models/ability.rb", /class Ability\n  include CanCan::Ability/
    assert_file "#{atom}/test/dummy/config/initializers/devise.rb", %r{require "devise/orm/active_record"}
    # Rails 8 no longer generates app/channels/application_cable, which thecore_backend_commons
    # extends at boot (its channels subclass ApplicationCable::Channel).
    assert_file "#{atom}/test/dummy/app/channels/application_cable/connection.rb",
      /module ApplicationCable\n  class Connection < ActionCable::Connection::Base/
    assert_file "#{atom}/test/dummy/app/channels/application_cable/channel.rb",
      /module ApplicationCable\n  class Channel < ActionCable::Channel::Base/
    assert_file "#{atom}/Gemfile", /^gem 'minitest', '~> 5\.25'$/

    assert_file "#{atom}/config/locales/en.yml" do |content|
      assert_nil YAML.safe_load(content)["en"]
    end
    assert_file "#{atom}/config/locales/it.yml"

    assert_file "#{atom}/.github/workflows/gempush.yml" do |content|
      # A version is published once: version_exists is set from its tag and gates every publish step.
      assert_match(/echo "version_exists=true" >> "\$GITHUB_ENV"/, content)
      assert_match(/echo "version_exists=false" >> "\$GITHUB_ENV"/, content)
      assert_match(/if: env\.version_exists == 'false'/, content)
    end
    assert_github_test_gate(atom)
    # The JUnit report the CI keeps: minitest-reporters, active only when JUNIT_REPORT_DIR is set.
    assert_file "#{atom}/test/support/junit_report.rb", /if ENV\["JUNIT_REPORT_DIR"\]/
    assert_file "#{atom}/test/test_helper.rb", %r{require_relative "support/junit_report"}
    assert_file "#{atom}/Gemfile", /^gem 'minitest-reporters', '~> 1\.8'$/
    # No --gem-host: GitHub publishes to RubyGems, with the RubyGems token.
    publish = gempush_publish_step(atom)
    assert_match(/^gem push \*\.gem$/, publish["run"])
    assert_equal "${{secrets.RUBYGEMS_AUTH_TOKEN}}", publish.dig("env", "GEM_HOST_API_KEY")
    # A rerun after a failed tag push (host Odoo #6259): the version already on RubyGems is
    # not pushed again (RubyGems refuses it), so the tag and the release that follow still run.
    ok, calls = run_publish_step(atom, published: true)
    assert ok, "expected the publish step to succeed on a version already on RubyGems"
    assert(calls.any? { |c| c.start_with?("curl ") && c.include?("https://rubygems.org/api/v2/rubygems/tcp_debugger/versions/1.0.0.json") })
    refute(calls.any? { |c| c.start_with?("gem push") }, "expected no gem push for a version already published")
    ok, calls = run_publish_step(atom, published: false)
    assert ok
    assert_includes calls, "gem push *.gem"
    assert_file "#{atom}/.gitlab-ci.yml" do |content|
      data = YAML.safe_load(content)
      assert_equal "dev@alchemic.it", data["variables"]["GITLAB_EMAIL"]
      assert_equal "Alchemic IT", data["variables"]["GITLAB_USER_NAME"]
      assert_equal "gabrieletassoni/vscode-devcontainers-thecore:3", data["image"]
      assert_gitlab_publish_ci(data)
      # No private gem host: gem-compile.sh falls back to RubyGems only when the target is unset,
      # never on an "https:///" built from an empty variable.
      refute data["variables"].key?("GITLAB_GEM_REPO_TARGET"), "expected no gem target, so RubyGems is used"
    end
    %w[script/security_summary.rb test/script/security_summary_test.rb].each do |file|
      assert_file "#{atom}/#{file}" do |content|
        assert_equal File.read(File.join(SAMPLES_FIXTURE_DIR, file)), content
      end
    end

    git_dir = File.join(destination_root, atom, ".git")
    assert File.directory?(git_dir), "expected #{atom} to be git-initialized"
    log = Dir.chdir(File.join(destination_root, atom)) { `git log --oneline` }
    assert_equal 1, log.lines.size, "expected exactly one initial commit, got:\n#{log}"

    # Publishes like the real ATOMs: the repository lives on release/3, the only branch that publishes.
    branch = Dir.chdir(File.join(destination_root, atom)) { `git branch --show-current`.strip }
    assert_equal "release/3", branch
    assert_includes output, "git push -u origin release/3"
    gempush = YAML.safe_load(File.read(File.join(destination_root, atom, ".github/workflows/gempush.yml")))
    assert_equal({ "push" => { "branches" => ["release/3"] }, "pull_request" => { "branches" => ["release/3"] } },
      gempush.fetch(true, gempush["on"]),
      "expected the GitHub workflow to run on pushes and pull requests on release/3 only")
    assert_equal "github.event_name == 'push'", gempush.dig("jobs", "publish", "if"),
      "expected a pull request to run the tests but never publish"

    assert_file "Gemfile" do |content|
      assert_match(/gem "tcp_debugger", path: "vendor\/submodules\/tcp_debugger"/, content)
    end

    assert_file "#{atom}/CLAUDE.md" do |content|
      assert_equal File.read(File.join(SAMPLES_FIXTURE_DIR, "ATOM_CLAUDE.md")), content
    end

    assert_generated_atom_tests_pass(atom)
  end

  test "--skip-api-admin-deps omits model_driven_api/thecore_ui_rails_admin from the Gemfile, gemspec, and entry file" do
    output = run_generator ["tcp_debugger", "--skip-api-admin-deps", "--gem-host=https://gems.example.com/"] +
      NON_INTERACTIVE_ARGS

    atom = "vendor/submodules/tcp_debugger"

    assert_file "#{atom}/Gemfile" do |content|
      assert_match(/^gem ["']pg["']/, content)
      refute_match(/model_driven_api/, content)
      refute_match(/thecore_ui_rails_admin/, content)
    end
    assert_file "#{atom}/lib/tcp_debugger.rb" do |content|
      refute_match(/require 'model_driven_api'/, content)
      refute_match(/require 'thecore_ui_rails_admin'/, content)
    end
    assert_file "#{atom}/tcp_debugger.gemspec" do |content|
      # Dual support (Odoo #6091): Thecore 3 hosts run Rails 7.2 or 8.1, never 8.2 yet.
      assert_match(/spec\.add_dependency "rails", ">= 7\.2", "< 8\.2"$/, content)
      refute_match(/model_driven_api/, content)
      refute_match(/thecore_ui_rails_admin/, content)
      # --gem-host: the gem is pushed to the private server, and only there.
      assert_match(/spec\.metadata\["allowed_push_host"\]\s*=\s*"https:\/\/gems\.example\.com"$/, content)
    end
    assert_file "#{atom}/.gitlab-ci.yml" do |content|
      assert_equal "https://gems.example.com/", YAML.safe_load(content).dig("variables", "GITLAB_GEM_REPO_TARGET")
    end
    assert_includes output, 'source "https://gems.example.com/" do'
    # The GitHub workflow publishes to the same host allowed_push_host names, never to RubyGems.
    publish = gempush_publish_step(atom)
    assert_match(%r{^gem push --host https://gems\.example\.com \*\.gem$}, publish["run"])
    assert_equal "${{secrets.GEMS_REPO_CREDENTIALS}}", publish.dig("env", "GEM_HOST_API_KEY")
    refute_match(/rubygems/i, publish.to_s)
    # Resumable like the RubyGems one (host Odoo #6259): a version the host already has is not pushed
    # again. The lookup authenticates with the same key, as the private host wants for reading too.
    ok, calls = run_publish_step(atom, published: true)
    assert ok, "expected the publish step to succeed on a version already on the host"
    assert(calls.any? { |c| c.start_with?("gem spec --remote tcp_debugger -v 1.0.0") && c.include?("--source https://the-key@gems.example.com/") })
    refute(calls.any? { |c| c.start_with?("gem push") }, "expected no gem push for a version already published")
    ok, calls = run_publish_step(atom, published: false)
    assert ok
    assert_includes calls, "gem push --host https://gems.example.com *.gem"

    # Scaffold Files/directories are still created regardless of this choice.
    assert_file "#{atom}/config/initializers/after_initialize.rb"
    assert_file "#{atom}/app/models/concerns/api/.keep"

    # No CanCan/Devise in this bundle: no abilities initializer, no dummy Ability/Devise setup.
    assert_no_file "#{atom}/config/initializers/abilities.rb"
    assert_no_file "#{atom}/test/dummy/app/models/ability.rb"
    assert_no_file "#{atom}/test/dummy/config/initializers/devise.rb"

    assert_generated_atom_tests_pass(atom)
    # Without a lockfile the ATOM resolves the newest Rails its gemspec allows: 8.1, never 8.2.
    assert_match(/^    rails \(8\.1\.\d/, File.read(File.join(destination_root, atom, "Gemfile.lock")))
  end

  test "--gem-host accepts only a host name, not a path" do
    error = assert_raises(Thor::Error) do
      run_generator ["tcp_debugger", "--gem-host=gems.example.com/private"] + NON_INTERACTIVE_ARGS, debug: true
    end
    assert_match(/--gem-host/, error.message)
    assert_no_directory "vendor/submodules/tcp_debugger"
  end

  test "does not duplicate an existing host Gemfile entry for the same gem name" do
    File.write(File.join(destination_root, "Gemfile"),
      "source \"https://rubygems.org\"\n\ngem 'tcp_debugger', '~> 1.0'\n")

    run_generator ["tcp_debugger"] + NON_INTERACTIVE_ARGS

    assert_file "Gemfile" do |content|
      assert_equal 1, content.scan(/gem\s+["']tcp_debugger["']/).size
      assert_match(/gem 'tcp_debugger', '~> 1\.0'/, content)
      refute_match(/path: "vendor\/submodules\/tcp_debugger"/, content)
    end
  end

  # S2 on thecore's REAL samples (THECORE_REAL_SAMPLES_DIR, as in the App template's S1 test;
  # skipped when unset, so the suite stays offline): the ATOM's CLAUDE.md documents how it is
  # tested, published and scanned, and the security summary's own test passes inside the ATOM.
  test "an ATOM generated from the real thecore samples documents publishing and passes the summary's test" do
    samples_dir = ENV["THECORE_REAL_SAMPLES_DIR"].to_s.strip
    skip "THECORE_REAL_SAMPLES_DIR not set: point it at a thecore checkout's samples/" if samples_dir.empty?
    ENV["THECORE_SAMPLES_SOURCE"] = samples_dir

    run_generator ["tcp_debugger", "--skip-api-admin-deps"] + NON_INTERACTIVE_ARGS
    atom = "vendor/submodules/tcp_debugger"

    claude_md = File.read(File.join(destination_root, atom, "CLAUDE.md"))
    assert_equal File.read(File.join(samples_dir, "ATOM_CLAUDE.md")), claude_md
    commands = markdown_section(claude_md, "## Common commands")
    create_db, run_tests = commands.index("bin/rails db:create"), commands.index("bin/rails test")
    assert create_db && run_tests && create_db < run_tests,
      "expected the test sequence bin/rails db:create, then bin/rails test"
    refute_includes commands, "rake test"
    publishing = markdown_section(claude_md, "## Publishing")
    ["release/3", "lib/<name>/version.rb", "RubyGems", "gempush.yml", "allowed_push_host", "gem-compile.sh",
     "GITLAB_GEM_REPO_TARGET", "--gem-host", "bundle update <name> --conservative"].each do |term|
      assert_includes publishing, term, "expected \"Publishing\" in the ATOM's CLAUDE.md to cover #{term}"
    end
    scanning = markdown_section(claude_md, "## Security scanning")
    ["SAST", "Secret Detection", "security-summary", "script/security_summary.rb", "allow_failure",
     "bundler-audit"].each do |term|
      assert_includes scanning, term, "expected \"Security scanning\" in the ATOM's CLAUDE.md to cover #{term}"
    end

    %w[script/security_summary.rb test/script/security_summary_test.rb].each do |file|
      assert_equal File.read(File.join(samples_dir, file)), File.read(File.join(destination_root, atom, file))
    end
    assert_generated_atom_tests_pass(atom)
    output, status = Bundler.with_unbundled_env do
      Open3.capture2e({ "BUNDLE_GEMFILE" => File.join(destination_root, atom, "Gemfile"), "RAILS_ENV" => "test" },
        "bin/rails test test/script/security_summary_test.rb", chdir: File.join(destination_root, atom))
    end
    assert status.success?, "expected the security summary's test to pass in the ATOM:\n#{output}"
    assert_match(/\b3 runs, .*\b0 failures, 0 errors\b/, output, "expected the summary test's three cases to run")
  end

  # Exercises just #fetch_claude_md directly, the same "build the generator
  # instance, call the one method under test" pattern
  # association_wiring_test.rb already established - the happy-path CLAUDE.md
  # fetch itself is covered as part of the full end-to-end test above (it needs
  # a real `vendor/submodules/tcp_debugger` on disk anyway, already paid for by
  # that test's own `rails plugin new` run), so this only needs to prove the
  # *failure* path, which doesn't need the engine scaffolded at all - skipping
  # the expensive subprocess spawn entirely.
  test "a CLAUDE.md fetch failure aborts with a clear message naming the file/source/error" do
    ENV["THECORE_SAMPLES_SOURCE"] = File.join(Dir.tmpdir, "thecore_generators_atom_test_missing_samples")
    generator = Thecore::Generators::AtomGenerator.new(["tcp_debugger"], {}, destination_root: destination_root)

    error = assert_raises(SystemExit) { generator.send(:fetch_claude_md) }
    assert_match(/Failed to fetch ATOM_CLAUDE\.md/, error.message)
  end

  private

  def create_vendor_submodules_dir!
    FileUtils.mkdir_p(File.join(destination_root, "vendor", "submodules"))
  end

  def point_samples_source_at_fixture!
    @original_samples_source = ENV["THECORE_SAMPLES_SOURCE"]
    ENV["THECORE_SAMPLES_SOURCE"] = SAMPLES_FIXTURE_DIR
  end

  def restore_samples_source!
    ENV["THECORE_SAMPLES_SOURCE"] = @original_samples_source
  end

  # The step of the generated GitHub workflow that runs `gem push`.
  def gempush_publish_step(atom)
    gempush = YAML.safe_load(File.read(File.join(destination_root, atom, ".github/workflows/gempush.yml")))
    gempush.dig("jobs", "publish", "steps").find { |step| step["run"].to_s.include?("gem push") }
  end

  # Runs the generated publish step's script as GitHub does (bash -e -o pipefail) for version 1.0.0,
  # with stub `curl` and `gem` that answer as if the version were already on the gem host or not.
  # Returns whether the script succeeded and the curl/gem command lines it ran.
  def run_publish_step(atom, published:)
    script = gempush_publish_step(atom)["run"]
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "bin")
      calls = File.join(dir, "calls")
      FileUtils.mkdir_p(bin)
      File.write(File.join(dir, "#{File.basename(atom)}.gemspec"), "")
      write_stub(bin, "curl", %(echo "curl $*" >> #{calls.dump}\nprintf '%s' #{published ? 200 : 404}))
      write_stub(bin, "gem", %(echo "gem $*" >> #{calls.dump}\n[ "$1" = spec ] && exit #{published ? 0 : 2}\nexit 0))
      env = { "PATH" => "#{bin}:#{ENV.fetch("PATH")}", "HOME" => dir, "version" => "1.0.0", "GEM_HOST_API_KEY" => "the-key" }
      _output, status = Open3.capture2e(env, "bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", script, chdir: dir)
      [status.success?, File.exist?(calls) ? File.readlines(calls, chomp: true) : []]
    end
  end

  def write_stub(bin, name, body)
    path = File.join(bin, name)
    File.write(path, "#!/bin/bash\n#{body}\n")
    File.chmod(0o755, path)
  end

  # Runs the generated dummy app's config/boot.rb in a clean Ruby process, as the test
  # helper does (RAILS_ENV=test), and returns the DATABASE_URL it ends up with. Bundler is
  # kept out of it (no outer bundle, a missing BUNDLE_GEMFILE) since the ATOM's own gems
  # aren't installed here; boot.rb skips `bundler/setup` when its Gemfile is absent.
  def database_url_seen_by_dummy_boot(atom, database_url)
    boot = File.join(destination_root, atom, "test/dummy/config/boot.rb")
    env = {
      "RAILS_ENV" => "test",
      "DATABASE_URL" => database_url,
      "BUNDLE_GEMFILE" => File.join(Dir.tmpdir, "thecore_generators_no_such_gemfile"),
    }
    stdout, stderr, status = Bundler.with_unbundled_env do
      Open3.capture3(env, "ruby", "-e", "load #{boot.dump}; print ENV['DATABASE_URL']")
    end
    assert status.success?, "loading #{boot} failed:\n#{stderr}"
    stdout
  end

  # S2: the freshly generated ATOM passes its own test suite, untouched, on PostgreSQL. Runs
  # what an ATOM author runs (bundle install, create the test database, `bin/rails test`) in
  # the ATOM's own bundle, outside this gem's. The database server is whatever the dummy's
  # database.yml/DATABASE_URL resolve to (`db` in the devcontainer and in this suite's docker
  # run); the test-database rule keeps it on tcp_debugger_test either way.
  def assert_generated_atom_tests_pass(atom)
    atom_path = File.join(destination_root, atom)
    # JUNIT_REPORT_DIR removed: this suite's own CI sets it, and inherited by the ATOM it would
    # switch the ATOM's output to the JUnit reporter and empty this gem's own report directory.
    env = { "BUNDLE_GEMFILE" => File.join(atom_path, "Gemfile"), "RAILS_ENV" => "test", "JUNIT_REPORT_DIR" => nil }
    output = ["bundle install --quiet", "bin/rails db:create", "bin/rails test"].map do |command|
      output, status = Bundler.with_unbundled_env do
        Open3.capture2e(env, command, chdir: atom_path)
      end
      assert status.success?, "`#{command}` failed in the generated ATOM:\n#{output}"
      output
    end.last
    assert_match(/[1-9]\d* runs, \d+ assertions, 0 failures, 0 errors/, output, "the ATOM's own tests didn't run")

    # As CI runs it: the same suite writes the JUnit report the release keeps.
    junit_dir = File.join(atom_path, "tmp", "junit")
    output, status = Bundler.with_unbundled_env do
      Open3.capture2e(env.merge("JUNIT_REPORT_DIR" => junit_dir), "bin/rails test", chdir: atom_path)
    end
    assert status.success?, "`bin/rails test` with JUNIT_REPORT_DIR failed in the generated ATOM:\n#{output}"
    reports = Dir[File.join(junit_dir, "*.xml")]
    assert_equal 1, reports.size, "expected one JUnit report in #{junit_dir}"
    assert_match(/<testsuite /, File.read(reports.first))
  end

  # GitHub (thecore_generators#26, the base ATOMs' gempush.yml): a test job on PostgreSQL 15 that
  # keeps the JUnit report, and a publish job that runs only after it and only on a push.
  def assert_github_test_gate(atom)
    gempush = YAML.safe_load(File.read(File.join(destination_root, atom, ".github/workflows/gempush.yml")))
    test = gempush.dig("jobs", "test") || flunk("expected a `test` job in gempush.yml")
    assert_equal "postgres:15-bookworm", test.dig("services", "postgres", "image")
    assert_equal "${{ github.workspace }}/tmp/junit", test.dig("env", "JUNIT_REPORT_DIR")
    runs = test["steps"].map { |step| step["run"] }.compact
    assert_includes runs, "bin/rails db:create"
    assert_includes runs, "bin/rails test"
    upload = test["steps"].find { |step| step["uses"].to_s.start_with?("actions/upload-artifact") }
    assert upload, "expected the test job to keep the JUnit report as an artifact"
    assert_equal "always()", upload["if"]
    assert_equal "test", gempush.dig("jobs", "publish", "needs"), "expected publish to need the green test job"
    publish_runs = gempush.dig("jobs", "publish", "steps").map { |step| step["run"].to_s }
    push_at = publish_runs.index { |run| run.include?("gem push") }
    tag_at = publish_runs.index { |run| run.include?("git tag") }
    assert_operator push_at, :<, tag_at, "expected the gem pushed before the tag, so a failed push can be retried"
  end

  # The real spot ATOMs' GitLab CI (mytask): build and push only when lib/*/version.rb changes
  # (never on a tag), plus GitLab CE's SAST and Secret Detection, whose findings the
  # security-summary job turns into an orange job.
  def assert_gitlab_publish_ci(data)
    # thecore_generators#26 (mytask's .gitlab-ci.yml): test_gem on PostgreSQL 15 on every branch
    # push, and build_gem only after it, keeping the published version's JUnit report.
    test_gem = data.fetch("test_gem")
    assert_equal "test", test_gem["stage"]
    assert_equal [{ "name" => "postgres:15-bookworm", "alias" => "db" }], test_gem["services"]
    assert_includes test_gem["script"], "bin/rails test"
    assert_equal ["tmp/junit/*.xml"], Array(test_gem.dig("artifacts", "reports", "junit"))
    assert_equal ["test_gem"], data.dig("build_gem", "needs")
    assert_equal "never", data.dig("build_gem", "artifacts", "expire_in")

    build = data.fetch("build_gem")
    assert_equal ["/usr/bin/gem-compile.sh"], build["script"]
    assert_equal [{ "if" => "$CI_COMMIT_TAG", "when" => "never" },
      { "changes" => ["lib/*/version.rb"], "when" => "on_success" },
      { "when" => "never" }], build["rules"], "expected build_gem to run only on a version bump"

    templates = Array(data["include"]).map { |i| i["template"] }
    assert_equal %w[Jobs/SAST.gitlab-ci.yml Jobs/Secret-Detection.gitlab-ci.yml], templates
    assert_equal [], data.dig("semgrep-sast", "needs")
    assert_equal [], data.dig("secret_detection", "needs")

    summary = data.fetch("security-summary")
    assert_equal "test", summary["stage"]
    assert_includes data["stages"], "test"
    assert summary["allow_failure"], "expected security-summary to turn orange, not red"
    assert_equal %w[semgrep-sast secret_detection], summary["needs"].map { |n| n["job"] }
    assert(summary["needs"].all? { |n| n["optional"] }, "expected both scanner needs to be optional")
    assert_equal ["ruby script/security_summary.rb gl-sast-report.json gl-secret-detection-report.json"],
      summary["script"]
  end

  # The body of a "## " section, up to the next "## " heading.
  def markdown_section(markdown, heading)
    start = markdown.index(/^#{Regexp.escape(heading)}$/)
    flunk "expected a \"#{heading}\" section" unless start
    rest = markdown[(start + heading.size)..]
    rest[0, rest.index(/^## /) || rest.size]
  end

  def create_host_gemfile!
    File.write(File.join(destination_root, "Gemfile"), "source \"https://rubygems.org\"\n")
  end
end
