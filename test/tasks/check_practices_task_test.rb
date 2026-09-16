require "test_helper"
require "support/check_practices_fixtures"

# Exercises `rails thecore:check_practices`'s Scaffold Files + Models checks
# (thecore_generators#13) end-to-end - see check_practices_actions_test.rb
# for the Actions check + --fix (thecore_generators#14). See
# support/check_practices_fixtures.rb for the shared fixture/invocation
# helpers both files use.
class Thecore::CheckPracticesTaskTest < ActiveSupport::TestCase
  include CheckPracticesFixtures

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
end
