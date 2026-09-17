require "test_helper"
require "generators/thecore/atom/atom_generator"
require "fileutils"
require "tmpdir"

class Thecore::Generators::AtomGeneratorTest < Rails::Generators::TestCase
  tests Thecore::Generators::AtomGenerator

  GEM_ROOT = File.expand_path("../../../..", __dir__)

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

  setup :prepare_destination
  setup :create_vendor_submodules_dir!
  setup :create_host_gemfile!

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
    run_generator ["tcp_debugger"] + NON_INTERACTIVE_ARGS

    atom = "vendor/submodules/tcp_debugger"

    assert_file "#{atom}/lib/tcp_debugger/engine.rb"
    assert_file "#{atom}/tcp_debugger.gemspec" do |content|
      assert_match(/spec\.authors\s*=\s*\["Alchemic IT"\]/, content)
      assert_match(/spec\.email\s*=\s*\["dev@alchemic\.it"\]/, content)
      assert_match(/spec\.homepage\s*=\s*"https:\/\/github\.com\/example\/tcp_debugger"/, content)
      assert_match(/spec\.summary\s*=\s*"TCP Debugger"/, content)
      assert_match(/spec\.description\s*=\s*"Debugs TCP connections"/, content)
      assert_match(/spec\.add_dependency "rails"/, content)
      assert_match(/spec\.add_dependency "model_driven_api", "~> 3\.9"/, content)
      assert_match(/spec\.add_dependency "thecore_ui_rails_admin", "~> 3\.8"/, content)
      assert_match(/spec\.metadata\["allowed_push_host"\]\s*=\s*"https:\/\/rubygems\.org"/, content)
      assert_match(/spec\.metadata\["source_code_uri"\]\s*=\s*spec\.homepage/, content)
      assert_match(/spec\.metadata\["changelog_uri"\]\s*=\s*"#\{spec\.homepage\}\/blob\/master\/CHANGELOG\.md"/, content)
    end

    assert_file "#{atom}/Gemfile" do |content|
      assert_match(/gem 'pg'/, content)
      assert_match(/gem 'model_driven_api', '~> 3\.9'/, content)
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

    assert_file "#{atom}/config/locales/en.yml" do |content|
      assert_nil YAML.safe_load(content)["en"]
    end
    assert_file "#{atom}/config/locales/it.yml"

    assert_file "#{atom}/.github/workflows/gempush.yml" do |content|
      # The two fixed bugs: correct awk closing syntax, and version_exists actually set.
      assert_match(/awk -F'\.' '\{print \$1"\."\$2"\."\$3\}'/, content)
      refute_match(/\$3\}\)/, content)
      assert_match(/echo "version_exists=true" >> "\$GITHUB_ENV"/, content)
      assert_match(/echo "version_exists=false" >> "\$GITHUB_ENV"/, content)
      assert_match(/if: env\.version_exists == 'false'/, content)
    end
    assert_file "#{atom}/.gitlab-ci.yml" do |content|
      data = YAML.safe_load(content)
      assert_equal "dev@alchemic.it", data["variables"]["GITLAB_EMAIL"]
      assert_equal "Alchemic IT", data["variables"]["GITLAB_USER_NAME"]
      assert_equal "gabrieletassoni/vscode-devcontainers-thecore:3", data["image"]
    end

    git_dir = File.join(destination_root, atom, ".git")
    assert File.directory?(git_dir), "expected #{atom} to be git-initialized"
    log = Dir.chdir(File.join(destination_root, atom)) { `git log --oneline` }
    assert_equal 1, log.lines.size, "expected exactly one initial commit, got:\n#{log}"

    assert_file "Gemfile" do |content|
      assert_match(/gem "tcp_debugger", path: "vendor\/submodules\/tcp_debugger"/, content)
    end
  end

  test "--skip-api-admin-deps omits model_driven_api/thecore_ui_rails_admin from the Gemfile, gemspec, and entry file" do
    run_generator ["tcp_debugger", "--skip-api-admin-deps"] + NON_INTERACTIVE_ARGS

    atom = "vendor/submodules/tcp_debugger"

    assert_file "#{atom}/Gemfile" do |content|
      assert_match(/gem 'pg'/, content)
      refute_match(/model_driven_api/, content)
      refute_match(/thecore_ui_rails_admin/, content)
    end
    assert_file "#{atom}/lib/tcp_debugger.rb" do |content|
      refute_match(/require 'model_driven_api'/, content)
      refute_match(/require 'thecore_ui_rails_admin'/, content)
    end
    assert_file "#{atom}/tcp_debugger.gemspec" do |content|
      assert_match(/spec\.add_dependency "rails"/, content)
      refute_match(/model_driven_api/, content)
      refute_match(/thecore_ui_rails_admin/, content)
    end

    # Scaffold Files/directories are still created regardless of this choice.
    assert_file "#{atom}/config/initializers/after_initialize.rb"
    assert_file "#{atom}/app/models/concerns/api/.keep"
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

  private

  def create_vendor_submodules_dir!
    FileUtils.mkdir_p(File.join(destination_root, "vendor", "submodules"))
  end

  def create_host_gemfile!
    File.write(File.join(destination_root, "Gemfile"), "source \"https://rubygems.org\"\n")
  end
end
