module RedirectedDbMigratePath
  # ActiveRecord::Generators::Migration#db_migrate_path (used, via `super`,
  # whenever Thecore::Generators::AtomAware finds no ATOM to redirect into)
  # resolves from Rails.application.config.paths["db/migrate"] — i.e. always
  # the real Rails.root, completely independent of a generator's own
  # `destination_root`. For a real `rails generate` invocation the two
  # coincide (destination_root starts out as Rails::Command.root), but
  # Rails::Generators::TestCase deliberately configures its own tmp
  # destination_root instead, precisely so tests never touch test/dummy's
  # real files. Redirecting the dummy app's own db/migrate config path to
  # that tmp destination_root for the duration of each test reconciles the
  # two without writing into test/dummy itself, and exercises the exact
  # mechanism a real host-app invocation relies on.
  def self.included(base)
    base.setup :redirect_db_migrate_path_to_destination_root
    base.teardown :restore_db_migrate_path
  end

  def redirect_db_migrate_path_to_destination_root
    @original_db_migrate_paths = Rails.application.config.paths["db/migrate"].to_ary.dup
    Rails.application.config.paths["db/migrate"] = File.join(destination_root, "db", "migrate")
  end

  def restore_db_migrate_path
    Rails.application.config.paths["db/migrate"] = @original_db_migrate_paths
  end
end
