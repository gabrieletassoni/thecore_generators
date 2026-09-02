require "test_helper"
require "generators/thecore/model/model_generator"

# Integration-level companion to model_generator_test.rb (thecore_generators#4
# / ADR 0001 in the thecore repo): that file proves "no concern file gets
# written" by asserting file absence; this file proves the model still
# *works* once generated -- it actually boots the default `json_attrs` /
# `navigation_label` / `navigation_icon` modules that model_driven_api and
# thecore_ui_rails_admin register into
# ThecoreBackendCommons::DefaultModuleRegistry, and exercises them against a
# freshly generated model class, not a hand-rolled test double.
#
# This is only possible because ../../../Gemfile pulls in real, release/3
# checkouts of model_driven_api and thecore_ui_rails_admin (temporary, see
# that Gemfile's comment -- neither is published to RubyGems with this code
# yet) as test-only dependencies, and test/dummy/config/application.rb boots
# them for real.
class Thecore::Generators::ModelGeneratorDefaultConcernBehaviorTest < Rails::Generators::TestCase
  tests Thecore::Generators::ModelGenerator
  destination File.expand_path("../../../tmp/generator_test/model", __dir__)

  setup :prepare_destination

  test "a model generated with no concern flags still gets a working default json_attrs and RailsAdmin navigation" do
    run_generator ["NoConcernFixture", "name:string"]

    model_file = File.join(destination_root, "app/models/no_concern_fixture.rb")
    assert_file model_file do |content|
      refute_match(/include Api::/, content)
      refute_match(/include RailsAdmin::/, content)
    end

    # A real table -- RailsAdmin's AbstractModel needs actual columns to
    # introspect; a table-less model raises inside its construction. Content
    # mirrors the migration this same run_generator call produced.
    ActiveRecord::Base.connection.create_table(:no_concern_fixtures, force: true) do |t|
      t.string :name
    end

    require model_file

    # The generic default from model_driven_api (gabrieletassoni/model_driven_api#5).
    assert NoConcernFixture.include?(ModelDrivenApiDefaultJsonAttrs),
      "expected the generic default json_attrs module to be included via " \
      "ThecoreBackendCommons::DefaultModuleRegistry"
    assert_equal({except: []}, NoConcernFixture.json_attrs)
    # cattr_accessor inside `included do` must land json_attrs as an *own*
    # method -- model_driven_api's /info/schema and /info/dsl introspection
    # depend on this (see ADR 0001's consequences section).
    assert_includes NoConcernFixture.instance_methods(false), :json_attrs

    # The generic default from thecore_ui_rails_admin (gabrieletassoni/thecore_ui_rails_admin#7).
    config = RailsAdmin.config(NoConcernFixture)
    assert_equal I18n.t("admin.registries.label"), config.navigation_label
    assert_equal ThecoreUiRailsAdminDefaultNavigationConcern::DEFAULT_ICON, config.navigation_icon
  end

  test "--with-api-concern --with-admin-concern still yields a working, included concern file exactly as before this ticket (regression)" do
    run_generator ["WithConcernFixture", "name:string", "--with-api-concern", "--with-admin-concern"]

    api_concern_file = File.join(destination_root, "app/models/concerns/api/with_concern_fixture.rb")
    admin_concern_file = File.join(destination_root, "app/models/concerns/rails_admin/with_concern_fixture.rb")
    model_file = File.join(destination_root, "app/models/with_concern_fixture.rb")

    ActiveRecord::Base.connection.create_table(:with_concern_fixtures, force: true) do |t|
      t.string :name
    end

    # Dependency order matters for a plain `require` (unlike Zeitwerk
    # autoloading): the model file's own class body does
    # `include Api::WithConcernFixture` / `include RailsAdmin::WithConcernFixture`,
    # so both concern modules must already be defined first.
    require api_concern_file
    require admin_concern_file
    require model_file

    assert WithConcernFixture.include?(Api::WithConcernFixture)
    assert WithConcernFixture.include?(RailsAdmin::WithConcernFixture)

    # Still includes the generic defaults (the registry applies
    # unconditionally, see ADR 0001) -- but the model's own explicit concern,
    # `include`d after the default from the class body, wins on every
    # setting it actually customizes.
    assert WithConcernFixture.include?(ModelDrivenApiDefaultJsonAttrs)
    assert WithConcernFixture.include?(ThecoreUiRailsAdminDefaultNavigationConcern)

    config = RailsAdmin.config(WithConcernFixture)
    assert_equal I18n.t("admin.registries.label"), config.navigation_label
    # The concern template's own hardcoded icon (see
    # templates/rails_admin_concern.rb.tt) -- distinct from
    # ThecoreUiRailsAdminDefaultNavigationConcern::DEFAULT_ICON ('fa fa-table'),
    # proving the explicit concern's last-registered `rails_admin do ... end`
    # block still wins over the earlier-registered default.
    assert_equal "fa fa-file", config.navigation_icon
  end
end
