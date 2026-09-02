module ThecoreGenerators
  # Boot-time hook point for this gem. Intentionally empty for now: no
  # generator behaviour ships in this release. A future ticket will add
  #
  #   config.app_generators.orm :thecore, migration: true, timestamps: true
  #
  # here, following the same mechanism ActiveRecord's own Railtie and
  # Mongoid both use to hook `rails generate model`/`migration` (see
  # docs/adr/0002-thecore-generators-gem-and-generator-hook-mechanism.md in
  # the thecore repo).
  class Railtie < ::Rails::Railtie
  end
end
