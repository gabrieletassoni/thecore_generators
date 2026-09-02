require_relative "lib/thecore_generators/version"

Gem::Specification.new do |spec|
  spec.name        = "thecore_generators"
  spec.version     = ThecoreGenerators::VERSION
  spec.authors     = ["Gabriele Tassoni"]
  spec.email       = ["g.tassoni@bancolini.com"]
  spec.homepage    = "https://github.com/gabrieletassoni/thecore_generators"
  spec.summary     = "Rails-native generators for the Thecore 3 scaffolding framework."
  spec.description = "Hooks Rails' own generator commands (model, migration) and adds " \
    "thecore:*-namespaced generators plus a check_practices rake task, replacing " \
    "scaffolding logic previously duplicated in the Thecore VS Code extension. " \
    "See docs/adr/0002-thecore-generators-gem-and-generator-hook-mechanism.md in the " \
    "thecore repo for the design rationale."
  spec.license     = "MIT"

  # Prevent pushing this gem to RubyGems.org. To allow pushes either set the "allowed_push_host"
  # to allow pushing to a single host or delete this section to allow pushing to any host.
  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/gabrieletassoni/thecore_generators"
  spec.metadata["changelog_uri"] = "https://github.com/gabrieletassoni/thecore_generators/blob/release/3/CHANGELOG.md"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.required_ruby_version = ">= 3.1"

  # This gem hooks Rails' generator machinery only — it does not need the
  # full `rails` gem at runtime, just railties (Rails::Railtie,
  # Rails::Generators). Pinned to the Rails 7.2 line this branch targets;
  # release/4 will bump this for Rails 8.
  spec.add_dependency "railties", "~> 7.2"
end
