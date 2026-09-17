require "test_helper"
require "open3"
require "tmpdir"

# The App application template (thecore_generators#17/#18, ADR 0005 in the thecore repo)
# is a Rails application template, not a Thor::Group generator — its only real entry
# point is `rails new -m`, so this is the one seam it's tested through: a real `rails
# new` subprocess against a scratch tmp directory, asserting on the resulting file tree.
# A real subprocess (not an in-process Rails::Generators::AppGenerator.start call) is
# used deliberately — this test suite already boots a full Rails::Application
# (test/dummy) in-process for the generator tests elsewhere in this file list, and a
# second, unrelated `rails new` run sharing that same process is an unnecessary risk
# to court for no benefit.
#
# Kept offline and deterministic (thecore_generators#17's own acceptance criteria):
# `--skip-bundle` stops Rails' own automatic bundle of the gems this template adds,
# and answering "no" to the template's own interactive installer-chain prompt (fed via
# stdin) stops it from calling `bundle install`/`rails generate ...` itself either —
# both are required together, independently, to avoid any live network call.
class AppTemplateTest < Minitest::Test
  TEMPLATE_PATH = File.expand_path("../../lib/templates/app_template.rb", __dir__)
  GEM_ROOT = File.expand_path("../..", __dir__)
  # thecore_generators#18's asset-source override point, pinned at a fixture checked
  # into this gem's own test folder rather than thecore's real samples/ (which this
  # gem doesn't own and shouldn't duplicate a live copy of) — keeps the whole suite
  # offline and deterministic, no live HTTP calls to raw.githubusercontent.com.
  SAMPLES_FIXTURE_DIR = File.expand_path("../fixtures/thecore_samples", __dir__)

  def test_core_scaffolding_matches_thecore_generators_17_acceptance_criteria
    Dir.mktmpdir do |dir|
      app_path = File.join(dir, "sample_app")

      stdout, stderr, status = spawn_rails_new(app_path, chdir: dir)
      assert status.success?, "`rails new -m app_template.rb` failed:\n#{stdout}\n#{stderr}"

      gemfile = File.read(File.join(app_path, "Gemfile"))

      %w[devise cancancan rails_admin sassc-rails].each do |gem_name|
        assert_match(/^\s*gem ["']#{Regexp.escape(gem_name)}["']/, gemfile,
          "expected the core Gemfile stack to include an active `#{gem_name}` line")
      end

      # ADR 0001 (thecore repo) requires these two specific floors for the
      # DefaultModuleRegistry default-concern behavior -- pinned exactly, not loosely,
      # so a future edit that weakens either floor below the documented minimum fails
      # this test rather than passing silently.
      assert_match(/^\s*gem ["']model_driven_api["'],\s*["']~>\s*3\.9["']/, gemfile,
        "expected model_driven_api to meet the ADR 0001 DefaultModuleRegistry floor (~> 3.9)")
      assert_match(/^\s*gem ["']thecore_ui_rails_admin["'],\s*["']~>\s*3\.8["']/, gemfile,
        "expected thecore_ui_rails_admin to meet the ADR 0001 DefaultModuleRegistry floor (~> 3.8)")

      # Matched loosely (any 3.x, not a hardcoded minor) since this is this gem's own,
      # self-referential version constraint -- it will legitimately move on every
      # future release of thecore_generators itself, unlike the external ADR 0001
      # floors above, which only change deliberately and rarely.
      assert_match(/^\s*gem ["']thecore_generators["'],\s*["']~>\s*3\.\d+["'],\s*group:\s*:development/, gemfile,
        "expected thecore_generators to be added as a :development-only dependency")

      %w[
        thecore_auth_commons thecore_settings thecore_print_commons thecore_background_jobs
        thecore_ui_commons thecore_tcp_debug thecore_download_documents thecore_dataentry_commons
        thecore_connectors
      ].each do |gem_name|
        assert_match(/^\s*#\s*gem ["']#{Regexp.escape(gem_name)}["'].*#.+/, gemfile,
          "expected `#{gem_name}` to be listed commented-out with a purpose comment, discoverable but off by default")
      end

      %w[submodules external].each do |placeholder_dir|
        keep_file = File.join("vendor", placeholder_dir, ".keep")
        assert File.file?(File.join(app_path, keep_file)),
          "expected an empty, git-trackable vendor/#{placeholder_dir}/ placeholder"
        assert_equal [keep_file],
          Dir.glob("vendor/#{placeholder_dir}/**/*", base: app_path, flags: File::FNM_DOTMATCH)
            .reject { |p| p.end_with?("/.", "/..") },
          "vendor/#{placeholder_dir}/ should contain nothing but the placeholder — no pre-wired content"
      end

      # thecore_generators#18: devcontainer/CI/CLAUDE.md assets fetched from thecore's
      # samples (the fixture above, via THECORE_SAMPLES_SOURCE), overwriting whatever
      # the bootstrap "Setup Devcontainer" step would have created. Asserting byte-exact
      # equality against the fixture (not just "a file exists" / a content pattern)
      # proves the fetch round-trip actually pulled from the intended source — a
      # pattern-only check could pass even if the wrong file got fetched, as long as it
      # coincidentally matched; equality can't.
      %w[
        devcontainer.json docker-compose.yml Dockerfile create-db-user.sql
        link-host-home.sh check-plugins.sh
      ].each do |file|
        destination = File.join(app_path, ".devcontainer", file)
        assert File.file?(destination), "expected .devcontainer/#{file} to be fetched from thecore's samples"
        assert_equal File.read(File.join(SAMPLES_FIXTURE_DIR, "devcontainer", file)), File.read(destination),
          "expected the fetched .devcontainer/#{file} to match the fixture byte-for-byte"
      end
      %w[link-host-home.sh check-plugins.sh].each do |script|
        mode = File.stat(File.join(app_path, ".devcontainer", script)).mode
        assert (mode & 0o111).positive?, "expected .devcontainer/#{script} to be executable"
      end

      # The fixture's devcontainer.json (unlike the real thecore/samples one, kept
      # deliberately minimal — see SAMPLES_FIXTURE_DIR's comment) still carries the
      # commented gh/glab mounts specifically, since that's the one piece of content
      # this ticket's acceptance criteria calls out by name.
      devcontainer_json = File.read(File.join(app_path, ".devcontainer", "devcontainer.json"))
      %w[gh glab].each do |cli|
        assert_match(/^\s*\/\/\s*"source=.*#{cli}/, devcontainer_json,
          "expected the #{cli} CLI config mount to be present but commented out")
      end

      %w[.gitlab-ci.yml CLAUDE.md].each do |file|
        destination = File.join(app_path, file)
        assert File.file?(destination), "expected #{file} to be fetched from thecore's samples"
        assert_equal File.read(File.join(SAMPLES_FIXTURE_DIR, file)), File.read(destination),
          "expected the fetched #{file} to match the fixture byte-for-byte"
      end

      claude_md = File.read(File.join(app_path, "CLAUDE.md"))
      assert_match(/mattpocock-skills/, claude_md, "expected the universal skill-plugin section")
      assert_match(/ask-matt/, claude_md, "expected the universal required-skill-sequence section")
      assert_match(/TODO/, claude_md, "expected project-specific sections left as TODO placeholders")
    end
  end

  private

  # Extracted so thecore_generators#18 (which extends this same test with
  # devcontainer/CI/CLAUDE.md asset assertions against the same generated app, per its
  # own acceptance criteria) can reuse this exact invocation rather than re-deriving
  # the `chdir`/`BUNDLE_GEMFILE`/stdin dance below a second time.
  def spawn_rails_new(app_path, chdir:, stdin: "no\n")
    # `chdir` is deliberately the scratch tmp dir, NOT this gem's own root: plain
    # `rails` (railties' exe/rails, via Rails::AppLoader.exec_app) walks *up* the
    # directory tree from cwd looking for a `bin/rails` to delegate to before it
    # ever runs as the `rails new` generator (see this gem's own CLAUDE.md,
    # "Dir.pwd cannot be trusted..."). thecore_generators lives nested under this
    # host backend repo, which has its own `bin/rails` a few directories up — cwd'd
    # there, that walk-up would silently exec the *host app's* bin/rails instead of
    # generating a new app. `BUNDLE_GEMFILE` (rather than cwd) is what tells
    # Bundler which bundle's `rails` gem to resolve.
    env = {
      "BUNDLE_GEMFILE" => File.join(GEM_ROOT, "Gemfile"),
      # thecore_generators#18: points the template's asset-fetch step at the local
      # fixture above instead of the real raw GitHub URL it defaults to.
      "THECORE_SAMPLES_SOURCE" => SAMPLES_FIXTURE_DIR
    }

    Open3.capture3(
      env,
      "bundle", "exec", "rails", "new", app_path,
      "--database=postgresql", "--asset-pipeline=sprockets",
      "--skip-bundle", "--skip-git", "--quiet",
      "-m", TEMPLATE_PATH,
      stdin_data: stdin,
      chdir: chdir
    )
  end
end
