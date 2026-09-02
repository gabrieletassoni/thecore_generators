require "test_helper"
require "generators/thecore/workspace_context"
require "tmpdir"
require "fileutils"

class Thecore::Generators::WorkspaceContextTest < ActiveSupport::TestCase
  WC = Thecore::Generators::WorkspaceContext

  setup do
    @tmp = Dir.mktmpdir
    @app_root = File.join(@tmp, "host_app")
    @atom_dir = File.join(@app_root, "vendor", "submodules", "sample_atom")
    FileUtils.mkdir_p(File.join(@atom_dir, "app", "models"))
    FileUtils.touch(File.join(@atom_dir, "sample_atom.gemspec"))
  end

  teardown do
    FileUtils.remove_entry(@tmp)
  end

  test "atom_root_of resolves the ATOM root from a cwd nested inside it" do
    nested = File.join(@atom_dir, "app", "models")
    assert_equal @atom_dir, WC.atom_root_of(nested)
  end

  test "atom_root_of resolves the ATOM root from cwd at the ATOM root itself" do
    assert_equal @atom_dir, WC.atom_root_of(@atom_dir)
  end

  test "atom_root_of returns nil for a cwd not under vendor/submodules" do
    assert_nil WC.atom_root_of(@app_root)
  end

  test "atom_root_of returns nil for cwd sitting directly at vendor/submodules (no specific ATOM)" do
    assert_nil WC.atom_root_of(File.join(@app_root, "vendor", "submodules"))
  end

  test "gemspec_path_for finds the dash-to-underscore variant" do
    dashed_dir = File.join(@app_root, "vendor", "submodules", "my-atom")
    FileUtils.mkdir_p(dashed_dir)
    FileUtils.touch(File.join(dashed_dir, "my_atom.gemspec"))

    assert_equal File.join(dashed_dir, "my_atom.gemspec"), WC.gemspec_path_for(dashed_dir)
  end

  test "valid_atom_dir? is false when the directory has no gemspec" do
    no_gemspec_dir = File.join(@app_root, "vendor", "submodules", "incomplete_atom")
    FileUtils.mkdir_p(no_gemspec_dir)

    refute WC.valid_atom_dir?(no_gemspec_dir)
  end

  test "atom_dir_for returns nil (host-app context) when cwd is not under vendor/submodules" do
    assert_nil WC.atom_dir_for(cwd: @app_root, app_root: @app_root)
  end

  test "atom_dir_for resolves the ATOM directory from cwd" do
    nested = File.join(@atom_dir, "app", "models")
    assert_equal @atom_dir, WC.atom_dir_for(cwd: nested, app_root: @app_root)
  end

  test "atom_dir_for raises when cwd is under vendor/submodules but the ATOM has no gemspec" do
    incomplete = File.join(@app_root, "vendor", "submodules", "incomplete_atom")
    FileUtils.mkdir_p(incomplete)

    assert_raises(Thor::Error) { WC.atom_dir_for(cwd: incomplete, app_root: @app_root) }
  end

  test "atom_dir_for with atom_name overrides cwd-based detection" do
    assert_equal @atom_dir, WC.atom_dir_for(cwd: @app_root, app_root: @app_root, atom_name: "sample_atom")
  end

  test "atom_dir_for with an unknown atom_name raises Thor::Error" do
    assert_raises(Thor::Error) do
      WC.atom_dir_for(cwd: @app_root, app_root: @app_root, atom_name: "does_not_exist")
    end
  end

  test "atom_dir_for treats a blank atom_name the same as no override" do
    assert_nil WC.atom_dir_for(cwd: @app_root, app_root: @app_root, atom_name: "")
  end
end
