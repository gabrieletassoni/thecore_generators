require "rails/generators"

module ThecoreGenerators
  module Test
    # A no-op generator that exists purely to prove the
    # Rails::Generators::TestCase harness works end-to-end (destination
    # setup, invocation, assertions) before any real thecore_generators
    # generator ships. Not part of this gem's public API — see
    # test/generators/placeholder_generator_test.rb.
    class PlaceholderGenerator < Rails::Generators::Base
      def do_nothing
      end
    end
  end
end
