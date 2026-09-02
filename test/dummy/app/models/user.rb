class User < ApplicationRecord
  # Minimal Devise setup -- just enough for thecore_auth_commons/
  # thecore_backend_commons's after_initialize hooks (which `include`
  # concerns into `User` unconditionally) and thecore_ui_commons's
  # `devise_for :users` route mapping to find a configured `devise` method.
  # This dummy app never actually exercises authentication -- see
  # test/integration/default_concern_behavior_test.rb, the only suite that
  # boots this fuller engine chain.
  devise :database_authenticatable

  has_many :push_subscribers, dependent: :destroy
end
