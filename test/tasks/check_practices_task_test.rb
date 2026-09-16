require "test_helper"

# Exercises `rails thecore:check_practices` end-to-end (thecore_generators#13):
# invokes the real Rake task in-process against fixtures written directly
# into test/dummy (the only booted Rails app available to this gem's test
# suite - see CLAUDE.md's "Test infrastructure" section), asserting on
# captured stdout and exit behavior, not on Thecore::CheckPractices::Runner's
# own internal methods.
#
# Every fixture this file writes into test/dummy is created fresh (verified
# against test/dummy's tracked-in-git baseline) and torn down after each
# test via `register_cleanup_for`, which walks up from the fixture's path to
# the first already-existing ancestor directory and removes only what this
# test itself created - test/dummy's own pre-existing files (config/locales/
# en.yml, app/models/user.rb, app/models/concerns/.keep, ...) are never
# touched.
class Thecore::CheckPracticesTaskTest < ActiveSupport::TestCase
  DUMMY_ROOT = Rails.root

  setup do
    @created_paths = []
    Rake::Task["thecore:check_practices"].reenable
  end

  teardown do
    @created_paths.reverse_each { |path| FileUtils.rm_rf(path) }
  end

  test "reports Scaffold Files violations for the host app when after_initialize.rb/assets.rb are absent" do
    out = invoke_task

    assert_match(/Missing Scaffold File: after_initialize\.rb/, out)
    assert_match(/Missing Scaffold File: assets\.rb/, out)
  end

  test "reports no Scaffold Files violations once after_initialize.rb/assets.rb carry their markers" do
    write_fixture("config/initializers/after_initialize.rb", "Rails.application.configure do\n  config.after_initialize do\n  end\nend\n")
    write_fixture("config/initializers/assets.rb", "Rails.application.config.assets.precompile += %w( foo.js )\n")

    out = invoke_task

    refute_match(/after_initialize\.rb/, out)
    refute_match(/assets\.rb/, out)
    assert_match(/No violations found/, out)
  end

  test "reports a marker violation for a scaffold file that exists but lost its marker" do
    write_fixture("config/initializers/after_initialize.rb", "# nothing useful here\n")
    write_fixture("config/initializers/assets.rb", "Rails.application.config.assets.precompile += %w( foo.js )\n")

    out = invoke_task

    assert_match(/after_initialize\.rb is missing the `Rails\.application\.configure do` marker/, out)
  end

  test "scans every ATOM under vendor/submodules/ in addition to the host app by default" do
    build_atom_fixture!("sample_atom")
    write_fixture("vendor/submodules/sample_atom/config/initializers/assets.rb", "Rails.application.config.assets.precompile += %w( foo.js )\n")
    # Deliberately no after_initialize.rb inside the ATOM.

    out = invoke_task

    assert_match(%r{vendor/submodules/sample_atom/config/initializers/after_initialize\.rb:\n\s+\[ERROR\] Missing Scaffold File: after_initialize\.rb}, out)
  end

  test "--atom=NAME scopes the audit to a single ATOM, skipping the host app" do
    build_atom_fixture!("sample_atom")
    write_fixture("vendor/submodules/sample_atom/config/initializers/assets.rb", "Rails.application.config.assets.precompile += %w( foo.js )\n")
    # Host app itself has no after_initialize.rb/assets.rb either, but must not be reported.

    out = invoke_task("--atom=sample_atom")

    assert_match(%r{vendor/submodules/sample_atom/config/initializers/after_initialize\.rb}, out)
    refute_match(%r{\A#{Regexp.escape(DUMMY_ROOT.to_s)}/config/initializers}, out)
  end

  test "--atom=NAME pointing at a non-existent ATOM aborts instead of silently scanning nothing" do
    out, err = capture_io do
      error = assert_raises(SystemExit) { invoke_with_argv(["--atom=does_not_exist"]) }
      assert_equal 1, error.status
    end

    assert_match(/does_not_exist/, out + err)
  end

  test "reports zero model violations for a model with no Api::/RailsAdmin:: concern (ADR 0001 default state)" do
    with_valid_scaffold_files!
    write_fixture("app/models/no_concern_fixture.rb", "class NoConcernFixture < ApplicationRecord\nend\n")

    out = invoke_task

    refute_match(/NoConcernFixture/, out)
    assert_match(/No violations found/, out)
  end

  test "reports an orphan include violation when a model includes a concern module whose file doesn't exist" do
    with_valid_scaffold_files!
    write_fixture("app/models/orphan_fixture.rb", "class OrphanFixture < ApplicationRecord\n  include Api::OrphanFixture\nend\n")

    out = invoke_task

    assert_match(/OrphanFixture: includes Api::OrphanFixture but its concern file is missing/, out)
  end

  test "does not treat a longer, differently-named include as a match for a shorter model name (prefix false positive)" do
    with_valid_scaffold_files!
    # "include Api::FooBar" contains "include Api::Foo" as a literal
    # substring - Foo must not be reported as orphaning a concern it never
    # asked to include.
    write_fixture("app/models/foo.rb", "class Foo < ApplicationRecord\n  include Api::FooBar\nend\n")

    out = invoke_task

    refute_match(/\bFoo:/, out)
  end

  test "reports a missing-marker violation when the concern file exists but lacks its required marker" do
    with_valid_scaffold_files!
    write_fixture("app/models/marker_fixture.rb", "class MarkerFixture < ApplicationRecord\n  include Api::MarkerFixture\nend\n")
    write_fixture("app/models/concerns/api/marker_fixture.rb", "module Api::MarkerFixture\nend\n")

    out = invoke_task

    assert_match(/MarkerFixture: api concern missing 'extend ActiveSupport::Concern' marker/, out)
    assert_match(/MarkerFixture: api concern missing 'cattr_accessor :json_attrs' marker/, out)
  end

  test "human-readable default output is grouped by file" do
    write_fixture("config/initializers/after_initialize.rb", "# missing marker\n")
    write_fixture("config/initializers/assets.rb", "# missing marker\n")

    out = invoke_task

    after_initialize_path = File.join(DUMMY_ROOT, "config/initializers/after_initialize.rb")
    assets_path = File.join(DUMMY_ROOT, "config/initializers/assets.rb")
    assert_match(/#{Regexp.escape(after_initialize_path)}:\n\s+\[ERROR\]/, out)
    assert_match(/#{Regexp.escape(assets_path)}:\n\s+\[ERROR\]/, out)
  end

  test "--json emits the structured violation schema" do
    write_fixture("config/initializers/after_initialize.rb", "# missing marker\n")
    write_fixture("config/initializers/assets.rb", "Rails.application.config.assets.precompile += %w( foo.js )\n")

    out = invoke_task("--json")

    data = JSON.parse(out)
    assert data.key?("violations")
    violation = data["violations"].first
    assert_equal %w[file line message severity fixable code], violation.keys
    assert_equal false, violation["fixable"]
    assert_equal "missing_after_initialize_marker", violation["code"]
  end

  test "exits non-zero when violations are present and zero when none" do
    capture_io do
      error = assert_raises(SystemExit) { invoke_with_argv([]) }
      assert_equal 1, error.status
    end

    write_fixture("config/initializers/after_initialize.rb", "Rails.application.configure do\n  config.after_initialize do\n  end\nend\n")
    write_fixture("config/initializers/assets.rb", "Rails.application.config.assets.precompile += %w( foo.js )\n")
    Rake::Task["thecore:check_practices"].reenable

    capture_io { invoke_with_argv([]) } # does not raise SystemExit
  end

  private

  def with_valid_scaffold_files!
    write_fixture("config/initializers/after_initialize.rb", "Rails.application.configure do\n  config.after_initialize do\n  end\nend\n")
    write_fixture("config/initializers/assets.rb", "Rails.application.config.assets.precompile += %w( foo.js )\n")
  end

  def build_atom_fixture!(name)
    write_fixture("vendor/submodules/#{name}/#{name}.gemspec", "")
  end

  def write_fixture(relative_path, content)
    full_path = File.join(DUMMY_ROOT, relative_path)
    register_cleanup_for(full_path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, content)
    full_path
  end

  def register_cleanup_for(full_path)
    candidate = full_path
    candidate = File.dirname(candidate) until File.exist?(File.dirname(candidate))
    @created_paths << candidate unless @created_paths.include?(candidate)
  end

  # Most fixtures in this file deliberately produce at least one violation,
  # which makes the task call `exit(1)` (see the "exits non-zero..." test
  # for a dedicated, explicit assertion on that). Minitest treats SystemExit
  # as a pass-through exception (by design, so a genuine `exit` inside a test
  # process isn't silently swallowed) - left unrescued here, it would escape
  # the test method entirely and kill the whole test process instead of
  # failing just one test. Callers that need to assert on the exit itself
  # use `invoke_with_argv` directly, wrapped in `assert_raises(SystemExit)`.
  def invoke_task(*cli_args)
    capture_io do
      begin
        invoke_with_argv(cli_args)
      rescue SystemExit
        nil
      end
    end.first
  end

  def invoke_with_argv(cli_args)
    original_argv = ARGV.dup
    ARGV.replace(cli_args.empty? ? [] : ["--", *cli_args])
    Rake::Task["thecore:check_practices"].invoke
  ensure
    ARGV.replace(original_argv)
    Rake::Task["thecore:check_practices"].reenable
  end
end
