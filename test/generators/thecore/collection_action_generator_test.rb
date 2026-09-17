require "test_helper"
require "generators/thecore/collection_action/collection_action_generator"
require "support/atom_fixture"

class Thecore::Generators::CollectionActionGeneratorTest < Rails::Generators::TestCase
  include AtomFixture

  tests Thecore::Generators::CollectionActionGenerator
  destination File.expand_path("../../../tmp/generator_test/collection_action", __dir__)

  setup :prepare_destination

  test "rails generate thecore:collection_action from a host-app destination_root places the action under config/collection_actions with a full-path require" do
    run_generator ["my_action"]

    assert_file "config/collection_actions/my_action.rb" do |content|
      assert_match(/RailsAdmin::Config::Actions\.add_action "my_action", :base, :collection/, content)
      assert_match(/topic: :my_action/, content)
    end
    assert_no_file "lib/collection_actions/my_action.rb"

    assert_file "app/views/rails_admin/main/my_action.html.erb" do |content|
      assert_match(/<%= stylesheet_link_tag 'rails_admin\/actions\/my_action' %>/, content)
      assert_match(/<%= rails_admin\.my_action_path %>/, content)
    end
    assert_file "app/assets/javascripts/rails_admin/actions/my_action.js" do |content|
      assert_match(/myActionCable/, content)
      assert_match(/myActionFunction/, content)
    end
    assert_file "app/assets/stylesheets/rails_admin/actions/my_action.scss", /#my_action-response/

    assert_file "config/initializers/after_initialize.rb" do |content|
      assert_match(/require Rails\.root\.join\('config', 'collection_actions', 'my_action'\)\.to_s/, content)
    end
    assert_file "config/initializers/assets.rb" do |content|
      assert_match(/rails_admin\/actions\/my_action\.js rails_admin\/actions\/my_action\.css/, content)
    end

    assert_file "config/locales/en.yml" do |content|
      data = YAML.safe_load(content)
      entry = data["en"]["admin"]["actions"]["my_action"]
      assert_equal "My Action", entry["menu"]
      assert_equal "My Action", entry["title"]
      assert_equal "My Action", entry["breadcrumb"]
    end
    assert_file "config/locales/it.yml" do |content|
      data = YAML.safe_load(content)
      assert_equal "My Action", data["it"]["admin"]["actions"]["my_action"]["menu"]
    end
  end

  test "cwd inside an ATOM directory places the action under lib/collection_actions with a require by relative path" do
    build_atom_fixture!

    Dir.chdir(atom_dir) { run_generator ["bar_action"] }

    assert_file File.join(atom_dir, "lib/collection_actions/bar_action.rb")
    assert_no_file File.join(atom_dir, "config/collection_actions/bar_action.rb")
    assert_file File.join(atom_dir, "config/initializers/after_initialize.rb"),
      /require 'collection_actions\/bar_action'/
    assert_file File.join(atom_dir, "app/views/rails_admin/main/bar_action.html.erb")

    # Nothing leaked into the host-app destination_root.
    assert_no_file "lib/collection_actions/bar_action.rb"
    assert_no_file "config/collection_actions/bar_action.rb"
  end

  test "--atom=NAME overrides placement into that ATOM independent of cwd" do
    build_atom_fixture!

    run_generator ["baz_action", "--atom=#{AtomFixture::ATOM_NAME}"]

    assert_file File.join(atom_dir, "lib/collection_actions/baz_action.rb")
    assert_no_file "config/collection_actions/baz_action.rb"
    assert_no_file "lib/collection_actions/baz_action.rb"
  end

  test "an invalid (non snake_case) action name raises instead of generating anything" do
    error = assert_raises(Thor::Error) do
      run_generator ["MyAction"], debug: true
    end
    assert_match(/not a valid collection action name/, error.message)
    assert_no_file "config/collection_actions/my_action.rb"
  end

  test "a leading-digit action name raises instead of generating a file with an invalid Ruby symbol" do
    error = assert_raises(Thor::Error) do
      run_generator ["1action"], debug: true
    end
    assert_match(/not a valid collection action name/, error.message)
    assert_no_file "config/collection_actions/1action.rb"
  end

  test "re-running against the same name does not duplicate the require line, the precompile line, or the locale entry" do
    run_generator ["my_action"]
    run_generator ["my_action"]

    assert_file "config/initializers/after_initialize.rb" do |content|
      assert_equal 1, content.scan("require Rails.root.join('config', 'collection_actions', 'my_action').to_s").size
    end
    assert_file "config/initializers/assets.rb" do |content|
      assert_equal 1, content.scan("rails_admin/actions/my_action.js rails_admin/actions/my_action.css").size
    end
    assert_file "config/locales/en.yml" do |content|
      data = YAML.safe_load(content)
      assert_equal ["my_action"], data["en"]["admin"]["actions"].keys
    end
  end
end
