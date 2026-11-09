require "test_helper"
require "open3"
require "tmpdir"
require "json"

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
  # Seam S1 of thecore_devcontainer#5: a local checkout of thecore's REAL samples/
  # directory (e.g. `<thecore checkout>/samples`). Unset = the real-samples test skips,
  # so the suite stays offline by default; point it at any thecore checkout (a worktree
  # included) to test that checkout's samples through this template.
  REAL_SAMPLES_ENV = "THECORE_REAL_SAMPLES_DIR"

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
        link-host-home.sh check-plugins.sh heal-stale-containers.sh
      ].each do |file|
        destination = File.join(app_path, ".devcontainer", file)
        assert File.file?(destination), "expected .devcontainer/#{file} to be fetched from thecore's samples"
        assert_equal File.read(File.join(SAMPLES_FIXTURE_DIR, "devcontainer", file)), File.read(destination),
          "expected the fetched .devcontainer/#{file} to match the fixture byte-for-byte"
      end
      %w[link-host-home.sh check-plugins.sh heal-stale-containers.sh].each do |script|
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

      %w[
        .gitlab-ci.yml .github/workflows/ci.yml CLAUDE.md AGENTS.md
        docs/agents/issue-tracker.md docs/agents/triage-labels.md docs/agents/domain.md
      ].each do |file|
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

  # Seam S1 (thecore_devcontainer#5): the app a developer actually gets from the REAL
  # thecore samples, not the minimal fixture above. Every app-side practice the pilot
  # (mytask-imas) has is asserted here, one `assert_*_practices` helper per area --
  # later tickets add their own helper and call it from this one method, so the
  # expensive `rails new` runs once.
  def test_app_generated_from_real_thecore_samples_carries_pilot_practices
    samples_dir = real_samples_dir
    Dir.mktmpdir do |dir|
      app_path = File.join(dir, "sample_app")

      stdout, stderr, status = spawn_rails_new(
        app_path, chdir: dir, extra_env: { "THECORE_SAMPLES_SOURCE" => samples_dir }
      )
      assert status.success?, "`rails new -m app_template.rb` on #{samples_dir} failed:\n#{stdout}\n#{stderr}"

      assert_devcontainer_practices(app_path)
      assert_agent_docs_practices(app_path)
    end
  end

  # thecore_generators#23: non-interactive mode, installer chain declined. Fed empty
  # stdin (not "no\n") specifically to prove the template never reads from stdin at all
  # on this path -- if it fell through to the interactive `yes?` call despite the env
  # vars, this would hang (Open3.capture3 has no timeout) rather than fail cleanly, so
  # an empty-stdin run is a meaningfully stronger assertion than merely checking the
  # exit status afterward.
  #
  # THECORE_APP_TEMPLATE_RUN_INSTALLERS=true is deliberately NOT covered here: that
  # path performs a real `bundle install` plus several `rails generate`/`rails_command`
  # network-touching steps, the same "known non-blocking limitation" already documented
  # for the interactive "yes" path when thecore_generators#17 shipped (see this file's
  # own git history / CLAUDE.md) -- kept as a manual-verification-only path for the same
  # reason, not an oversight.
  def test_non_interactive_mode_skips_installer_chain_when_run_installers_is_false
    Dir.mktmpdir do |dir|
      app_path = File.join(dir, "sample_app")

      stdout, stderr, status = spawn_rails_new(
        app_path, chdir: dir, stdin: "",
        extra_env: {
          "THECORE_APP_TEMPLATE_NON_INTERACTIVE" => "1",
          "THECORE_APP_TEMPLATE_RUN_INSTALLERS" => "false"
        }
      )
      assert status.success?, "expected a clean run with no stdin needed:\n#{stdout}\n#{stderr}"

      # An empty-stdin `yes?` call would itself resolve to "no" (matching this test's
      # own expected end-state) even without any non-interactive handling at all --
      # so the interactive prompt text's absence, not just the installer chain's, is
      # the one signal that actually distinguishes "the env vars were honored" from
      # "the old interactive path happened to land on the same answer by accident".
      refute_match(/Run `bundle install` and the standard installer generators/, stdout,
        "expected the interactive prompt never printed when THECORE_APP_TEMPLATE_NON_INTERACTIVE is set")

      # devise:install/rails_admin:install/active_storage:install are the installer
      # chain's own first steps -- their absence is the observable proof the chain
      # never ran, since none of the core Gemfile-stack code above this section creates
      # this file on its own.
      refute File.file?(File.join(app_path, "config/initializers/devise.rb")),
        "expected the installer chain to be skipped when THECORE_APP_TEMPLATE_RUN_INSTALLERS=false"
    end
  end

  def test_non_interactive_mode_aborts_when_run_installers_is_unset
    Dir.mktmpdir do |dir|
      app_path = File.join(dir, "sample_app")

      stdout, stderr, status = spawn_rails_new(
        app_path, chdir: dir, stdin: "",
        extra_env: { "THECORE_APP_TEMPLATE_NON_INTERACTIVE" => "1" }
      )
      refute status.success?, "expected the template to abort when the installer-chain choice is unspecified"
      assert_match(/THECORE_APP_TEMPLATE_RUN_INSTALLERS/, stdout + stderr,
        "expected the abort message to name the missing env var")
    end
  end

  def test_non_interactive_mode_aborts_when_run_installers_is_invalid
    Dir.mktmpdir do |dir|
      app_path = File.join(dir, "sample_app")

      stdout, stderr, status = spawn_rails_new(
        app_path, chdir: dir, stdin: "",
        extra_env: {
          "THECORE_APP_TEMPLATE_NON_INTERACTIVE" => "1",
          "THECORE_APP_TEMPLATE_RUN_INSTALLERS" => "please"
        }
      )
      refute status.success?, "expected the template to abort on an unrecognized value"
      assert_match(/THECORE_APP_TEMPLATE_RUN_INSTALLERS/, stdout + stderr,
        "expected the abort message to name the offending env var")
    end
  end

  private

  # THECORE_REAL_SAMPLES_DIR: unset/blank skips (offline default); set but not a
  # thecore samples directory fails, so a typo never turns into a silent skip.
  def real_samples_dir
    dir = ENV[REAL_SAMPLES_ENV].to_s.strip
    skip "#{REAL_SAMPLES_ENV} not set: point it at a thecore checkout's samples/ to run S1" if dir.empty?
    dir = File.expand_path(dir)
    assert File.file?(File.join(dir, "devcontainer", "devcontainer.json")),
      "#{REAL_SAMPLES_ENV}=#{dir} is not a thecore samples/ directory (no devcontainer/devcontainer.json)"
    dir
  end

  # The pilot's devcontainer practices: stale containers healed on the host before
  # compose starts, the host home aliased for Claude Code's plugin paths, and the
  # plugin check -- each a script the container can run, wired where the pilot wires it.
  def assert_devcontainer_practices(app_path)
    %w[heal-stale-containers.sh link-host-home.sh check-plugins.sh].each do |script|
      path = File.join(app_path, ".devcontainer", script)
      assert File.file?(path), "expected .devcontainer/#{script} in the generated app"
      assert File.executable?(path), "expected .devcontainer/#{script} to be executable"
    end

    devcontainer = parse_jsonc(File.read(File.join(app_path, ".devcontainer", "devcontainer.json")))
    assert_match(%r{\Abash \.devcontainer/heal-stale-containers\.sh '\$\{localWorkspaceFolder\}'\z},
      devcontainer["initializeCommand"].to_s,
      "expected initializeCommand to run the heal script on the workspace folder")
  end

  AGENT_DOCS = %w[issue-tracker.md triage-labels.md domain.md].freeze
  TRIAGE_LABELS = %w[needs-triage needs-info ready-for-agent ready-for-human wontfix].freeze
  # Customer-specific practices of the pilot that must never reach a generic app.
  CUSTOMER_SPECIFIC = /Odoo|Odooly|VPN|MS ?SQL|SQL Server|tiny_?tds|IMAS|Gamma|Bancolini/i

  # The pilot's agent docs (thecore_devcontainer#13): docs/agents/ telling skills where
  # tickets go, an AGENTS.md that only points to CLAUDE.md, and a CLAUDE.md stating the
  # rules the pilot learned -- with none of the pilot's customer-specific content.
  def assert_agent_docs_practices(app_path)
    AGENT_DOCS.each do |doc|
      assert File.file?(File.join(app_path, "docs", "agents", doc)), "expected docs/agents/#{doc} in the generated app"
    end

    tracker = File.read(File.join(app_path, "docs", "agents", "issue-tracker.md"))
    assert_match(/git remote get-url origin/, tracker, "expected the issue tracker to be chosen from the git remote")
    assert_match(/GitHub Issues/, tracker, "expected GitHub Issues as the tracker for a github.com remote")
    assert_match(/GitLab Issues/, tracker, "expected GitLab Issues as the tracker for a GitLab remote")
    assert_match(/`gh issue create/, tracker, "expected the gh commands for GitHub Issues")
    assert_match(/`glab issue create/, tracker, "expected the glab commands for GitLab Issues")

    labels = File.read(File.join(app_path, "docs", "agents", "triage-labels.md"))
    TRIAGE_LABELS.each { |label| assert_includes labels, "`#{label}`", "expected the #{label} triage label" }

    agents_md_path = File.join(app_path, "AGENTS.md")
    assert File.file?(agents_md_path), "expected AGENTS.md in the generated app"
    agents_md = File.read(agents_md_path)
    assert_match(/CLAUDE\.md/, agents_md, "expected AGENTS.md to point to CLAUDE.md")
    assert_operator agents_md.lines.count { |l| !l.strip.empty? }, :<=, 10,
      "expected AGENTS.md to only point to CLAUDE.md, not duplicate it"

    claude_md = File.read(File.join(app_path, "CLAUDE.md"))
    atom = markdown_section(claude_md, "## Changing an ATOM")
    ["vendor/submodules/", "git submodule add -b release/3", "release/3", "--conservative", "Gemfile.lock"].each do |step|
      assert_includes atom, step, "expected \"Changing an ATOM\" to cover #{step}"
    end

    skills = markdown_section(claude_md, "## Agent skills")
    %w[issue-tracker triage-labels domain].each do |doc|
      assert_includes skills, "docs/agents/#{doc}.md", "expected \"Agent skills\" to point to docs/agents/#{doc}.md"
    end

    conventions = markdown_section(claude_md, "## Code conventions")
    assert_match(/retr(y|ied)/i, conventions, "expected the no-job-retries rule")
    assert_match(/serializable/i, conventions, "expected the serializable job arguments rule")
    assert_match(/Base64/, conventions, "expected the Base64-for-binary job arguments rule")
    assert_match(/Arel\.sql/, conventions, "expected the Arel.sql rule")
    assert_match(/ThecoreSettings::Setting\.find_by/, conventions, "expected the settings-read-at-runtime rule")
    assert_match(%r{vendor/deploytargets/.*SECRET_KEY_BASE|SECRET_KEY_BASE.*vendor/deploytargets/}m, claude_md,
      "expected the no-secrets-in-vendor/deploytargets/ rule")

    plugin = markdown_section(claude_md, "## Claude Code skills")
    assert_match(/User-invoked only/, plugin, "expected the user-invoked skills listed")
    assert_match(/Model-invocable/, plugin, "expected the model-invocable skills listed")

    commands = markdown_section(claude_md, "## Common commands")
    assert_includes commands, "thecore:atom", "expected thecore:atom among the common commands"
    assert_includes commands, "thecore:collection_action", "expected thecore:collection_action among the common commands"

    (["CLAUDE.md", "AGENTS.md"] + AGENT_DOCS.map { |d| "docs/agents/#{d}" }).each do |file|
      refute_match CUSTOMER_SPECIFIC, File.read(File.join(app_path, file)), "#{file} carries customer-specific content"
    end
  end

  # The text under a Markdown heading, up to the next heading of the same or higher level
  # (a `#` line inside a fenced code block is a shell comment, not a heading).
  def markdown_section(text, heading)
    level = heading[/\A#+/].size
    lines = text.lines
    start = lines.index { |l| l.chomp == heading }
    assert start, "expected a \"#{heading}\" section"
    in_fence = false
    section = [lines[start]]
    lines[(start + 1)..].each do |line|
      in_fence = !in_fence if line.start_with?("```")
      break if !in_fence && line.match?(/\A\#{1,#{level}} /)

      section << line
    end
    section.join
  end

  # devcontainer.json is JSONC: drops // and /* */ comments outside strings and
  # trailing commas, then parses it as JSON.
  def parse_jsonc(text)
    out = +""
    i = 0
    in_string = false
    while i < text.length
      c = text[i]
      if in_string
        out << c
        if c == "\\"
          out << text[i + 1].to_s
          i += 1
        elsif c == '"'
          in_string = false
        end
      elsif c == '"'
        in_string = true
        out << c
      elsif text[i, 2] == "//"
        i += 1 until i >= text.length || text[i] == "\n"
        next
      elsif text[i, 2] == "/*"
        i = (text.index("*/", i + 2) || text.length - 2) + 2
        next
      else
        out << c
      end
      i += 1
    end
    JSON.parse(out.gsub(/,(\s*[}\]])/, "\\1"))
  end

  # Extracted so thecore_generators#18 (which extends this same test with
  # devcontainer/CI/CLAUDE.md asset assertions against the same generated app, per its
  # own acceptance criteria) can reuse this exact invocation rather than re-deriving
  # the `chdir`/`BUNDLE_GEMFILE`/stdin dance below a second time. `extra_env:` was added
  # for thecore_generators#23's non-interactive-mode tests, merged over the base env
  # below so callers can override `THECORE_APP_TEMPLATE_NON_INTERACTIVE`/
  # `THECORE_APP_TEMPLATE_RUN_INSTALLERS` without needing to know the base env exists.
  def spawn_rails_new(app_path, chdir:, stdin: "no\n", extra_env: {})
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
    }.merge(extra_env)

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
