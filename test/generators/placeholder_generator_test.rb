require "test_helper"
require "support/placeholder_generator"

class PlaceholderGeneratorTest < Rails::Generators::TestCase
  tests ThecoreGenerators::Test::PlaceholderGenerator
  destination File.expand_path("../../tmp/generator_test", __dir__)

  setup :prepare_destination

  test "the Rails::Generators::TestCase harness can run a generator without raising" do
    assert_nothing_raised { run_generator }
  end
end
