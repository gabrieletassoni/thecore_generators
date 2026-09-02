require "test_helper"
require "generators/thecore/migration/migration_generator"
require "generators/thecore/model/model_generator"
require "support/redirected_db_migrate_path"
require "fileutils"

# Covers ADR 0003 in the thecore repo
# (docs/adr/0003-migration-driven-inverse-association-wiring.md):
# `references`/`add_reference` columns detected on the migration being
# generated get their missing inverse (`has_many`/`has_one`) side written
# into the target model's canonical per-model concern.
#
# Deliberately does not use `tests`/`run_generator` (both TestCase-class-wide,
# one generator class only) since this file exercises both
# Thecore::Generators::MigrationGenerator (standalone) and
# Thecore::Generators::ModelGenerator (delegates migration creation to a
# *different* inherited `create_migration_file`) — generator instances are
# built directly instead, the same underlying mechanism `run_generator` uses.
class Thecore::Generators::AssociationWiringTest < Rails::Generators::TestCase
  include RedirectedDbMigratePath

  destination File.expand_path("../../../tmp/generator_test/association_wiring", __dir__)

  setup :prepare_destination

  def build_migration_generator(args, config = {})
    Thecore::Generators::MigrationGenerator.new(args, [], config.reverse_merge(destination_root: destination_root))
  end

  def build_model_generator(args, config = {})
    Thecore::Generators::ModelGenerator.new(args, [], config.reverse_merge(destination_root: destination_root))
  end

  def stub_interactive_answer!(generator, answer)
    generator.define_singleton_method(:interactive_association_prompt?) { true }
    generator.define_singleton_method(:ask) { |*_args| answer }
  end

  def stub_non_interactive!(generator)
    generator.define_singleton_method(:interactive_association_prompt?) { false }
    generator.define_singleton_method(:ask) { |*_args| flunk("ask must not be called in non-interactive mode") }
  end

  def invoke!(generator)
    capture(:stdout) { generator.invoke_all }
  end

  def concern_path(target_class_name)
    "config/initializers/concern_#{target_class_name}.rb"
  end

  # ---------------------------------------------------------------------
  # Interactive prompt
  # ---------------------------------------------------------------------

  test "interactive run: accepting the has_many default writes has_many on the target model" do
    gen = build_migration_generator(["AddPostRefToComments", "post:references"])
    stub_interactive_answer!(gen, "has_many")

    invoke!(gen)

    assert_file concern_path("post") do |content|
      assert_match(/has_many :comments/, content)
    end
  end

  test "interactive run: has_one answer writes has_one on the target model" do
    gen = build_migration_generator(["AddPostRefToComments", "post:references"])
    stub_interactive_answer!(gen, "has_one")

    invoke!(gen)

    assert_file concern_path("post") do |content|
      assert_match(/has_one :comment/, content)
      refute_match(/has_many/, content)
    end
  end

  test "interactive run: skip answer writes no association and no concern file" do
    gen = build_migration_generator(["AddPostRefToComments", "post:references"])
    stub_interactive_answer!(gen, "skip")

    invoke!(gen)

    assert_no_file concern_path("post")
  end

  test "interactive run: the header comment marks the concern file as generator-maintained" do
    gen = build_migration_generator(["AddPostRefToComments", "post:references"])
    stub_interactive_answer!(gen, "has_many")

    invoke!(gen)

    assert_file concern_path("post") do |content|
      assert_match(/maintained by thecore_generators/, content)
      assert_match(/do not hand-edit/i, content)
    end
  end

  # ---------------------------------------------------------------------
  # Non-interactive default
  # ---------------------------------------------------------------------

  test "non-interactive (no TTY): defaults straight to has_many, never prompting" do
    gen = build_migration_generator(["AddPostRefToComments", "post:references"])
    stub_non_interactive!(gen)

    invoke!(gen)

    assert_file concern_path("post"), /has_many :comments/
  end

  test "--non-interactive flag forces the has_many default even when stdin/stdout look like a real TTY" do
    gen = build_migration_generator(["AddPostRefToComments", "post:references", "--non-interactive"])
    gen.define_singleton_method(:ask) { |*_args| flunk("ask must not be called with --non-interactive") }

    original_stdin_tty = $stdin.method(:tty?)
    original_stdout_tty = $stdout.method(:tty?)
    $stdin.define_singleton_method(:tty?) { true }
    $stdout.define_singleton_method(:tty?) { true }
    begin
      invoke!(gen)
    ensure
      $stdin.define_singleton_method(:tty?, original_stdin_tty)
      $stdout.define_singleton_method(:tty?, original_stdout_tty)
    end

    assert_file concern_path("post"), /has_many :comments/
  end

  # ---------------------------------------------------------------------
  # Idempotency
  # ---------------------------------------------------------------------

  test "re-running the same migration twice does not duplicate the association" do
    2.times do
      gen = build_migration_generator(["AddPostRefToComments", "post:references"])
      stub_non_interactive!(gen)
      invoke!(gen)
    end

    assert_file concern_path("post") do |content|
      assert_equal 1, content.scan(/has_many :comments/).size
    end
  end

  test "re-running the same migration twice does not duplicate the after_initialize registration" do
    2.times do
      gen = build_migration_generator(["AddPostRefToComments", "post:references"])
      stub_non_interactive!(gen)
      invoke!(gen)
    end

    assert_file "config/initializers/after_initialize.rb" do |content|
      assert_equal 1, content.scan(/Post\.send\(:include, ConcernPost\)/).size
    end
  end

  test "a second, different reference to the same target model appends into the same concern file" do
    gen1 = build_migration_generator(["AddPostRefToComments", "post:references"])
    stub_non_interactive!(gen1)
    invoke!(gen1)

    gen2 = build_migration_generator(["AddPostRefToLikes", "post:references"])
    stub_non_interactive!(gen2)
    invoke!(gen2)

    assert_file concern_path("post") do |content|
      assert_match(/has_many :comments/, content)
      assert_match(/has_many :likes/, content)
    end

    # Still a single file, single module, single after_initialize entry.
    assert_equal 1, Dir.glob(File.join(destination_root, "config/initializers/concern_post.rb")).size
    assert_file "config/initializers/after_initialize.rb" do |content|
      assert_equal 1, content.scan(/Post\.send\(:include, ConcernPost\)/).size
    end
  end

  # ---------------------------------------------------------------------
  # rails generate model delegates migration creation to the same machinery
  # ---------------------------------------------------------------------

  test "rails generate model wires the inverse association through its own create_migration_file" do
    gen = build_model_generator(["Comment", "post:references"])
    stub_non_interactive!(gen)

    invoke!(gen)

    assert_file concern_path("post"), /has_many :comments/
  end

  # ---------------------------------------------------------------------
  # Cross-boundary (target model lives in a different ATOM)
  # ---------------------------------------------------------------------

  test "cross-boundary: concern and after_initialize are still written into the invoking ATOM, with the dependency only logged" do
    atom_a = File.join(destination_root, "vendor", "submodules", "atom_a")
    atom_b = File.join(destination_root, "vendor", "submodules", "atom_b")
    FileUtils.mkdir_p(atom_a)
    FileUtils.touch(File.join(atom_a, "atom_a.gemspec"))
    FileUtils.mkdir_p(File.join(atom_b, "app", "models"))
    FileUtils.touch(File.join(atom_b, "atom_b.gemspec"))
    FileUtils.touch(File.join(atom_b, "app", "models", "post.rb"))

    gen = Dir.chdir(atom_a) { build_migration_generator(["AddPostRefToComments", "post:references"]) }
    stub_non_interactive!(gen)

    output = Dir.chdir(atom_a) { invoke!(gen) }

    assert_file File.join(atom_a, "config/initializers/concern_post.rb"), /has_many :comments/
    assert_file File.join(atom_a, "config/initializers/after_initialize.rb"), /Post\.send\(:include, ConcernPost\)/

    # Never written into the target's own ATOM.
    assert_no_file File.join(atom_b, "config/initializers/concern_post.rb")
    assert_no_file File.join(atom_b, "config/initializers/after_initialize.rb")

    assert_match(/Cross-boundary/, output)
    assert_match(/atom_b/, output)
    assert_match(/add_dependency "atom_b"/, output)
  end

  test "same-boundary (target model not found anywhere) does not log a cross-boundary dependency" do
    gen = build_migration_generator(["AddPostRefToComments", "post:references"])
    stub_non_interactive!(gen)

    output = invoke!(gen)

    refute_match(/Cross-boundary/, output)
  end
end
