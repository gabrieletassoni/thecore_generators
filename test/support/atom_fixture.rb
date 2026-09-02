require "fileutils"

module AtomFixture
  ATOM_NAME = "sample_atom"

  # Absolute path to a simulated ATOM directory nested under the TestCase's
  # own (auto-cleaned) destination_root, mimicking vendor/submodules/<atom>/
  # in a real host app. Living under destination_root means
  # Rails::Generators::TestCase's own `prepare_destination` setup callback
  # (rm_rf + mkdir_p) wipes it clean before every test, same as everything
  # else the test writes — build_atom_fixture! recreates it fresh each time.
  def atom_dir
    File.join(destination_root, "vendor", "submodules", ATOM_NAME)
  end

  # A gemspec's mere presence is what thecore_code_extension's hasGemspec
  # (and our Ruby port of it) checks for — content is irrelevant.
  def build_atom_fixture!
    FileUtils.mkdir_p(atom_dir)
    FileUtils.touch(File.join(atom_dir, "#{ATOM_NAME}.gemspec"))
  end
end
