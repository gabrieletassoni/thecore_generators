require "test_helper"
require "generators/thecore/migration/migration_generator"
require "support/atom_fixture"
require "support/redirected_db_migrate_path"

class Thecore::Generators::MigrationGeneratorTest < Rails::Generators::TestCase
  include AtomFixture
  include RedirectedDbMigratePath

  tests Thecore::Generators::MigrationGenerator
  destination File.expand_path("../../../tmp/generator_test/migration", __dir__)

  setup :prepare_destination

  test "rails generate migration standalone, from a host-app destination_root, places the migration in the app" do
    run_generator ["AddBarToFoo", "bar:string"]

    assert_migration "db/migrate/add_bar_to_foo.rb", /add_column :foos, :bar, :string/
  end

  test "cwd inside an ATOM directory places the standalone migration inside that ATOM" do
    build_atom_fixture!

    Dir.chdir(atom_dir) { run_generator ["AddBarToFoo", "bar:string"] }

    assert_migration File.join(atom_dir, "db/migrate/add_bar_to_foo.rb"), /add_column :foos, :bar, :string/
    assert_no_migration "db/migrate/add_bar_to_foo.rb"
  end

  test "--atom=NAME overrides standalone migration placement independent of cwd" do
    build_atom_fixture!

    run_generator ["AddBarToFoo", "bar:string", "--atom=#{AtomFixture::ATOM_NAME}"]

    assert_migration File.join(atom_dir, "db/migrate/add_bar_to_foo.rb")
    assert_no_migration "db/migrate/add_bar_to_foo.rb"
  end

  test "rails generate active_record:migration still works directly and is unaffected by the thecore hook" do
    require "rails/generators/active_record/migration/migration_generator"

    capture(:stdout) do
      ActiveRecord::Generators::MigrationGenerator.start(
        ["AddBarToFoo", "bar:string"], destination_root: destination_root
      )
    end

    assert_migration "db/migrate/add_bar_to_foo.rb", /add_column :foos, :bar, :string/
  end
end
