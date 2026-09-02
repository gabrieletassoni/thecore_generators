require "test_helper"
require "generators/thecore/model/model_generator"
require "support/atom_fixture"
require "support/redirected_db_migrate_path"

class Thecore::Generators::ModelGeneratorTest < Rails::Generators::TestCase
  include AtomFixture
  include RedirectedDbMigratePath

  tests Thecore::Generators::ModelGenerator
  destination File.expand_path("../../../tmp/generator_test/model", __dir__)

  setup :prepare_destination

  test "rails generate model Foo from a host-app destination_root places files in the app, with a real test file, but no default concerns and no Endpoints" do
    run_generator ["Foo", "name:string"]

    assert_file "app/models/foo.rb" do |content|
      assert_match(/class Foo < ApplicationRecord/, content)
      refute_match(/include Api::Foo/, content)
      refute_match(/include RailsAdmin::Foo/, content)
    end

    # thecore_generators#4 / ADR 0001: no concern files by default — the
    # no-customization case relies entirely on the default json_attrs /
    # navigation_label / navigation_icon modules that model_driven_api and
    # thecore_ui_rails_admin `include` into every ApplicationRecord subclass
    # automatically (see test/integration/default_concern_behavior_test.rb
    # for the runtime proof, not just this file-absence check).
    assert_no_file "app/models/concerns/api/foo.rb"
    assert_no_file "app/models/concerns/rails_admin/foo.rb"
    assert_no_file "app/models/concerns/endpoints/foo.rb"

    assert_migration "db/migrate/create_foos.rb", /create_table :foos/

    # Test file generation is not suppressed (no --skip-test-framework
    # equivalent): a real Minitest file is generated, matching Rails' own
    # active_record:model default.
    assert_file "test/models/foo_test.rb", /class FooTest < ActiveSupport::TestCase/
  end

  test "cwd inside an ATOM directory places the model, migration and test file inside that ATOM, with no default concerns" do
    build_atom_fixture!

    Dir.chdir(atom_dir) { run_generator ["Bar", "name:string"] }

    assert_file File.join(atom_dir, "app/models/bar.rb") do |content|
      refute_match(/include Api::Bar/, content)
      refute_match(/include RailsAdmin::Bar/, content)
    end
    assert_no_file File.join(atom_dir, "app/models/concerns/api/bar.rb")
    assert_no_file File.join(atom_dir, "app/models/concerns/rails_admin/bar.rb")
    assert_migration File.join(atom_dir, "db/migrate/create_bars.rb")
    assert_file File.join(atom_dir, "test/models/bar_test.rb")

    # Nothing leaked into the host-app destination_root.
    assert_no_file "app/models/bar.rb"
    assert_no_migration "db/migrate/create_bars.rb"
  end

  test "--with-api-concern --with-admin-concern scaffolds starter concern files identical in shape to pre-#4 default output (regression)" do
    run_generator ["Foo", "name:string", "--with-api-concern", "--with-admin-concern"]

    assert_file "app/models/foo.rb" do |content|
      assert_match(/class Foo < ApplicationRecord/, content)
      assert_match(/include Api::Foo/, content)
      assert_match(/include RailsAdmin::Foo/, content)
    end

    assert_file "app/models/concerns/api/foo.rb", /module Api::Foo/
    assert_file "app/models/concerns/rails_admin/foo.rb", /module RailsAdmin::Foo/
    assert_no_file "app/models/concerns/endpoints/foo.rb"

    assert_migration "db/migrate/create_foos.rb", /create_table :foos/
    assert_file "test/models/foo_test.rb", /class FooTest < ActiveSupport::TestCase/
  end

  test "--with-api-concern alone scaffolds only the Api:: concern" do
    run_generator ["Foo", "name:string", "--with-api-concern"]

    assert_file "app/models/foo.rb" do |content|
      assert_match(/include Api::Foo/, content)
      refute_match(/include RailsAdmin::Foo/, content)
    end
    assert_file "app/models/concerns/api/foo.rb", /module Api::Foo/
    assert_no_file "app/models/concerns/rails_admin/foo.rb"
  end

  test "--with-admin-concern alone scaffolds only the RailsAdmin:: concern" do
    run_generator ["Foo", "name:string", "--with-admin-concern"]

    assert_file "app/models/foo.rb" do |content|
      refute_match(/include Api::Foo/, content)
      assert_match(/include RailsAdmin::Foo/, content)
    end
    assert_no_file "app/models/concerns/api/foo.rb"
    assert_file "app/models/concerns/rails_admin/foo.rb", /module RailsAdmin::Foo/
  end

  test "--atom=NAME overrides placement into that ATOM independent of cwd" do
    build_atom_fixture!

    # Deliberately not chdir'd into the ATOM: proves the override works from
    # a plain host-app cwd, per this ticket's acceptance criteria.
    run_generator ["Baz", "name:string", "--atom=#{AtomFixture::ATOM_NAME}"]

    assert_file File.join(atom_dir, "app/models/baz.rb")
    assert_migration File.join(atom_dir, "db/migrate/create_bazs.rb")
    assert_file File.join(atom_dir, "test/models/baz_test.rb")

    assert_no_file "app/models/baz.rb"
    assert_no_migration "db/migrate/create_bazs.rb"
  end

  test "--atom=NAME pointing at a non-existent ATOM raises instead of silently falling back to host-app placement" do
    # Thor::Base#start rescues Thor::Error and prints its message instead of
    # re-raising, unless `debug: true` is passed through — forcing that here
    # is what makes the failure observable as a raised error in the test,
    # rather than the swallowed default a bare `run_generator` call would give.
    error = assert_raises(Thor::Error) do
      run_generator ["Foo", "name:string", "--atom=does_not_exist"], debug: true
    end
    assert_match(/does_not_exist/, error.message)
  end

  test "rails generate active_record:model still works directly and is unaffected by the thecore hook" do
    require "rails/generators/active_record/model/model_generator"

    # Bypasses run_generator (which is bound to this TestCase's configured
    # `tests Thecore::Generators::ModelGenerator`) to invoke AR's own
    # generator directly, exactly as `rails generate active_record:model`
    # would resolve it — the escape hatch this ticket must not disturb.
    capture(:stdout) do
      ActiveRecord::Generators::ModelGenerator.start(["Qux", "name:string"], destination_root: destination_root)
    end

    assert_file "app/models/qux.rb" do |content|
      refute_match(/include Api::/, content)
      refute_match(/include RailsAdmin::/, content)
    end
    assert_no_file "app/models/concerns/api/qux.rb"
    assert_migration "db/migrate/create_quxes.rb"
  end
end
