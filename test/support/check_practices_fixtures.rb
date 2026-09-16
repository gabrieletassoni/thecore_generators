# Shared fixture-management helpers for tests that invoke
# `Rake::Task["thecore:check_practices"]` in-process against fixtures
# written directly into test/dummy (the only booted Rails app available to
# this gem's test suite). Used by both check_practices_task_test.rb
# (thecore_generators#13: Scaffold Files + Models) and
# check_practices_actions_test.rb (thecore_generators#14: Actions + --fix).
#
# Every fixture written via `write_fixture` is created fresh (verified
# against test/dummy's own tracked-in-git baseline via `register_cleanup_for`,
# which walks up from the fixture's path to the first already-existing
# ancestor directory and removes only what the test itself created) and torn
# down after each test. `snapshot_existing_file!` covers the other case: a
# fix that rewrites a file test/dummy already ships (config/locales/en.yml,
# rewritten in place by write_action_locale_entries! rather than created
# fresh) - snapshotted before the test runs and restored verbatim after.
module CheckPracticesFixtures
  def self.included(base)
    base.const_set(:DUMMY_ROOT, Rails.root) unless base.const_defined?(:DUMMY_ROOT)

    base.setup do
      @created_paths = []
      @file_snapshots = {}
      Rake::Task["thecore:check_practices"].reenable
    end

    base.teardown do
      restore_file_snapshots!
      @created_paths.reverse_each { |path| FileUtils.rm_rf(path) }
    end
  end

  def with_valid_scaffold_files!
    write_fixture("config/initializers/after_initialize.rb", "Rails.application.configure do\n  config.after_initialize do\n  end\nend\n")
    write_fixture("config/initializers/assets.rb", "Rails.application.config.assets.precompile += %w( foo.js )\n")
  end

  def build_atom_fixture!(name)
    write_fixture("vendor/submodules/#{name}/#{name}.gemspec", "")
  end

  def write_fixture(relative_path, content)
    full_path = File.join(self.class::DUMMY_ROOT, relative_path)
    register_cleanup_for(full_path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, content)
    full_path
  end

  def register_cleanup_for(full_path)
    candidate = full_path
    candidate = File.dirname(candidate) until File.exist?(File.dirname(candidate))
    @created_paths << candidate unless @created_paths.include?(candidate)
  end

  def snapshot_existing_file!(relative_path)
    full_path = File.join(self.class::DUMMY_ROOT, relative_path)
    @file_snapshots[full_path] ||= File.read(full_path)
    full_path
  end

  # `--fix` applies *every* fixable violation in one pass, not just the one
  # a given test is focused on - a test exercising, say, the require-line
  # fix for an action with no companions yet will also have its companions
  # silently fixed as a side effect. Call this once, upfront, in any test
  # that writes an action file and later invokes `--fix`, so every possible
  # side-effect path is tracked for cleanup regardless of which specific
  # violation(s) that test's own fixture triggers.
  def register_action_fix_cleanup!
    %w[
      app/views/rails_admin
      app/assets/javascripts/rails_admin
      app/assets/stylesheets/rails_admin
    ].each { |rel| register_cleanup_for(File.join(self.class::DUMMY_ROOT, rel)) }
    snapshot_existing_file!("config/locales/en.yml")
  end

  def restore_file_snapshots!
    @file_snapshots.each { |path, content| File.write(path, content) }
  end

  # Most fixtures in these files deliberately produce at least one
  # violation, which makes the task call `exit(1)`. Minitest treats
  # SystemExit as a pass-through exception (by design, so a genuine `exit`
  # inside a test process isn't silently swallowed) - left unrescued here,
  # it would escape the test method entirely and kill the whole test
  # process instead of failing just one test. Callers that need to assert
  # on the exit itself use `invoke_with_argv` directly, wrapped in
  # `assert_raises(SystemExit)`.
  def invoke_task(*cli_args)
    capture_io do
      begin
        invoke_with_argv(cli_args)
      rescue SystemExit
        nil
      end
    end.first
  end

  def invoke_with_argv(cli_args)
    original_argv = ARGV.dup
    ARGV.replace(cli_args.empty? ? [] : ["--", *cli_args])
    Rake::Task["thecore:check_practices"].invoke
  ensure
    ARGV.replace(original_argv)
    Rake::Task["thecore:check_practices"].reenable
  end
end
