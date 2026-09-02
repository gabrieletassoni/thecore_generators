require_relative "boot"

require "rails/all"

# Stub config.assets -- sprockets/propshaft is not in this gem's bundle, but
# thecore_backend_commons's config/initializers/application_config.rb (a
# temporary test-only dependency, see ../../Gemfile -- thecore_generators#4)
# unconditionally sets `config.assets.prefix` at boot. Mirrors the identical
# stub in thecore_backend_commons's/thecore_ui_rails_admin's own
# test/dummy/config/application.rb.
stub_class = Class.new do
  def method_missing(name, *args, &block)
    name_s = name.to_s
    return false if name_s.end_with?("?")
    return nil   if name_s.end_with?("=") || args.any? || block

    ivar = :"@_s_#{name_s.gsub(/\W/, "_")}"
    instance_variable_get(ivar) || instance_variable_set(ivar, self.class.new)
  end

  def respond_to_missing?(name, *) = name.to_s != "to_ary"
end

Rails::Application::Configuration.prepend(Module.new do
  define_method(:assets) { @_stub_assets ||= stub_class.new }
end)

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# `Ability` needs `CanCan::Ability`, defined by the `cancancan` gem
# (transitive, via thecore_auth_commons) -- must be required after
# Bundler.require above.
require File.expand_path("../app/models/ability", __dir__)

# `User` must be required from inside an `ActiveSupport.on_load(:active_record)`
# callback registered here -- i.e. *after* Bundler.require has already loaded
# Devise, which registers its own `:active_record` callback extending
# `Devise::Models` on to `ActiveRecord::Base` -- rather than eagerly up
# front: `on_load` callbacks run in registration order once the load event
# actually fires, so this guarantees `ActiveRecord::Base.devise` exists by
# the time `User`'s class body calls it. Mirrors thecore_ui_rails_admin's own
# test/dummy/config/application.rb, which has the identical ordering need.
ActiveSupport.on_load(:active_record) do
  require "devise/orm/active_record"

  require File.expand_path("../app/models/application_record", __dir__)
  require File.expand_path("../app/models/user", __dir__)
end

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f

    # For compatibility with applications that use this config
    config.action_controller.include_all_helpers = false

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
