require "test_helper"
require "support/check_practices_fixtures"

# Exercises `rails thecore:check_practices`'s Actions check + `--fix`
# (thecore_generators#14): root_actions/member_actions/collection_actions in
# both ATOM and host-app context. See check_practices_task_test.rb for the
# Scaffold Files + Models checks (thecore_generators#13) and
# support/check_practices_fixtures.rb for the shared helpers both use.
#
# Every test that writes an action file and later calls `--fix` starts with
# `register_action_fix_cleanup!` - `--fix` applies *every* fixable
# violation in one pass (not just the one the test is focused on), so an
# action fixture with incomplete companions has those fixed as a side
# effect of any `--fix` call, not just the ones targeting them directly.
class Thecore::CheckPracticesActionsTest < ActiveSupport::TestCase
  include CheckPracticesFixtures

  test "reports missing action-file markers without offering a fix" do
    with_valid_scaffold_files!
    write_fixture("config/root_actions/broken_action.rb", "# not even a RailsAdmin action\n")

    out = invoke_task("--json")
    data = JSON.parse(out)
    violations = data["violations"].select { |v| v["message"].include?("broken_action") && v["code"] == "action_file_missing_marker" }

    assert_equal 2, violations.size
    assert violations.all? { |v| v["fixable"] == false }
  end

  test "reports a missing companion view/JS/SCSS for a root action and --fix regenerates them via RootActionGenerator" do
    with_valid_scaffold_files!
    register_action_fix_cleanup!
    write_fixture("config/root_actions/my_action.rb", <<~RUBY)
      RailsAdmin::Config::Actions.add_action "my_action", :base, :root do
          http_methods [:get]
      end
    RUBY

    out = invoke_task("--json")
    data = JSON.parse(out)
    my_action_violations = data["violations"].select { |v| v["message"].include?("my_action") }
    codes = my_action_violations.map { |v| v["code"] }
    assert_includes codes, "missing_companion_view"
    assert_includes codes, "missing_companion_js"
    assert_includes codes, "missing_companion_scss"
    assert my_action_violations.select { |v| v["code"].start_with?("missing_companion") }.all? { |v| v["fixable"] }

    invoke_task("--fix")

    view_path = File.join(DUMMY_ROOT, "app/views/rails_admin/main/my_action.html.erb")
    js_path = File.join(DUMMY_ROOT, "app/assets/javascripts/rails_admin/actions/my_action.js")
    scss_path = File.join(DUMMY_ROOT, "app/assets/stylesheets/rails_admin/actions/my_action.scss")
    assert File.exist?(view_path)
    assert File.exist?(js_path)
    assert File.exist?(scss_path)
    # It's specifically Root's own template (fetch, not member's XHR) that was used.
    assert_match(/fetch\(url/, File.read(js_path))

    out_after = invoke_task
    refute_match(/my_action/, out_after)
  end

  test "a companion view that exists but lost its markers is reported and left untouched by --fix" do
    with_valid_scaffold_files!
    register_action_fix_cleanup!
    write_fixture("config/root_actions/my_action.rb", <<~RUBY)
      RailsAdmin::Config::Actions.add_action "my_action", :base, :root do
          http_methods [:get]
      end
    RUBY
    custom_view = "<p>hand-written, no markers here</p>\n"
    write_fixture("app/views/rails_admin/main/my_action.html.erb", custom_view)
    write_fixture("app/assets/javascripts/rails_admin/actions/my_action.js", "// hand-written\n")
    write_fixture("app/assets/stylesheets/rails_admin/actions/my_action.scss", "// hand-written\n")

    out = invoke_task
    assert_match(/my_action: companion view missing 'stylesheet_link_tag' marker/, out)

    invoke_task("--fix")

    assert_equal custom_view, File.read(File.join(DUMMY_ROOT, "app/views/rails_admin/main/my_action.html.erb"))
  end

  test "member action companion fix uses MemberActionGenerator's own XHR template, not Root's" do
    with_valid_scaffold_files!
    register_action_fix_cleanup!
    write_fixture("config/member_actions/my_member_action.rb", <<~RUBY)
      RailsAdmin::Config::Actions.add_action "my_member_action", :base, :member do
          http_methods [:get, :patch]
      end
    RUBY

    invoke_task("--fix")

    js_path = File.join(DUMMY_ROOT, "app/assets/javascripts/rails_admin/actions/my_member_action.js")
    assert File.exist?(js_path)
    assert_match(/XMLHttpRequest/, File.read(js_path))
    refute_match(/fetch\(url/, File.read(js_path))
  end

  test "reports and fixes a missing after_initialize.rb require line for an action" do
    with_valid_scaffold_files!
    register_action_fix_cleanup!
    write_fixture("config/root_actions/my_action.rb", <<~RUBY)
      RailsAdmin::Config::Actions.add_action "my_action", :base, :root do
          http_methods [:get]
      end
    RUBY

    out = invoke_task
    assert_match(/my_action: missing require line in after_initialize\.rb/, out)

    invoke_task("--fix")

    content = File.read(File.join(DUMMY_ROOT, "config/initializers/after_initialize.rb"))
    assert_match(/require Rails\.root\.join\('config', 'root_actions', 'my_action'\)\.to_s/, content)
  end

  test "reports and fixes a missing locale entry for an action, across every existing *.yml" do
    with_valid_scaffold_files!
    register_action_fix_cleanup!
    write_fixture("config/root_actions/my_action.rb", <<~RUBY)
      RailsAdmin::Config::Actions.add_action "my_action", :base, :root do
          http_methods [:get]
      end
    RUBY
    write_fixture("config/locales/fr.yml", "fr:\n")

    out = invoke_task
    assert_match(/my_action: missing locale entry in en\.yml/, out)
    assert_match(/my_action: missing locale entry in fr\.yml/, out)

    invoke_task("--fix")

    en_data = YAML.safe_load(File.read(File.join(DUMMY_ROOT, "config/locales/en.yml")))
    fr_data = YAML.safe_load(File.read(File.join(DUMMY_ROOT, "config/locales/fr.yml")))
    assert_equal "My Action", en_data.dig("en", "admin", "actions", "my_action", "menu")
    assert_equal "My Action", fr_data.dig("fr", "admin", "actions", "my_action", "menu")
  end

  test "lib/collection_actions is scanned with the same rules, and --fix regenerates missing companions via CollectionActionGenerator (thecore_generators#21)" do
    # Collection's companion templates are deliberately byte-identical to Root's (see
    # CollectionActionGenerator's own CLAUDE.md section) - generated *content* can't prove which
    # generator rendered them, so the dispatch itself is asserted directly instead.
    assert_equal Thecore::Generators::CollectionActionGenerator,
      Thecore::CheckPractices::Runner::ACTION_GENERATOR_CLASSES["collection_action"]

    with_valid_scaffold_files!
    register_action_fix_cleanup!
    write_fixture("config/collection_actions/bulk_thing.rb", <<~RUBY)
      RailsAdmin::Config::Actions.add_action "bulk_thing", :base, :collection do
          http_methods [:get]
      end
    RUBY

    out = invoke_task("--json")
    data = JSON.parse(out)
    companions = data["violations"].select { |v| v["message"].include?("bulk_thing") && v["code"].start_with?("missing_companion") }

    assert_equal 3, companions.size
    assert companions.all? { |v| v["fixable"] }

    invoke_task("--fix")

    view_path = File.join(DUMMY_ROOT, "app/views/rails_admin/main/bulk_thing.html.erb")
    js_path = File.join(DUMMY_ROOT, "app/assets/javascripts/rails_admin/actions/bulk_thing.js")
    scss_path = File.join(DUMMY_ROOT, "app/assets/stylesheets/rails_admin/actions/bulk_thing.scss")
    assert File.exist?(view_path)
    assert File.exist?(js_path)
    assert File.exist?(scss_path)

    out_after = invoke_task
    refute_match(/bulk_thing/, out_after)
  end

  test "--atom=NAME scopes the Actions check to that ATOM, and a fix lands inside it, not the host app" do
    build_atom_fixture!("sample_atom")
    write_fixture("vendor/submodules/sample_atom/config/initializers/after_initialize.rb", "Rails.application.configure do\n  config.after_initialize do\n  end\nend\n")
    write_fixture("vendor/submodules/sample_atom/config/initializers/assets.rb", "Rails.application.config.assets.precompile += %w( foo.js )\n")
    write_fixture("vendor/submodules/sample_atom/lib/root_actions/atom_action.rb", <<~RUBY)
      RailsAdmin::Config::Actions.add_action "atom_action", :base, :root do
          http_methods [:get]
      end
    RUBY

    out = invoke_task("--atom=sample_atom")
    assert_match(/atom_action: missing companion/, out)

    invoke_task("--atom=sample_atom", "--fix")

    atom_dir = File.join(DUMMY_ROOT, "vendor/submodules/sample_atom")
    assert File.exist?(File.join(atom_dir, "app/views/rails_admin/main/atom_action.html.erb"))
    refute File.exist?(File.join(DUMMY_ROOT, "app/views/rails_admin/main/atom_action.html.erb"))
  end

  # Regression test: `--atom=NAME` explicitly bypasses cwd-based ATOM
  # detection (see the test above), but a bare `--fix` (no `--atom`) covering
  # a host-app violation used to leave that bypass to
  # Thecore::Generators::AtomAware's own `atom_dir` fallback, which resolves
  # an unset `--atom` by falling back to cwd-based detection rather than
  # forcing host-app placement. If the check_practices process's own
  # `Dir.pwd` happened to sit inside a `vendor/submodules/<atom>/` tree at
  # fix time (e.g. invoked via an explicit `bin/rails` path from inside an
  # ATOM - see this gem's CLAUDE.md, WorkspaceContext's `Dir.pwd`-reset
  # gotcha), the fix for a *host-app* violation would silently land inside
  # that unrelated ATOM instead.
  test "a host-app fix lands in the host app even when the process's own Dir.pwd sits inside an unrelated ATOM" do
    with_valid_scaffold_files!
    register_action_fix_cleanup!
    write_fixture("config/root_actions/my_action.rb", <<~RUBY)
      RailsAdmin::Config::Actions.add_action "my_action", :base, :root do
          http_methods [:get]
      end
    RUBY
    build_atom_fixture!("sample_atom")

    atom_dir = File.join(DUMMY_ROOT, "vendor/submodules/sample_atom")
    original_pwd = Dir.pwd
    begin
      Dir.chdir(atom_dir)
      invoke_task("--fix")
    ensure
      Dir.chdir(original_pwd)
    end

    assert File.exist?(File.join(DUMMY_ROOT, "app/views/rails_admin/main/my_action.html.erb"))
    refute File.exist?(File.join(atom_dir, "app/views/rails_admin/main/my_action.html.erb"))
  end

  # Regression test: the companion rel_path (app/views/rails_admin/main/...,
  # etc.) is kind-agnostic, so a root_action and a member_action sharing the
  # same action name produce two independent "missing companion" violations
  # against the identical file. Applying both fixes in the same --fix pass
  # used to call the real generator's `template` a second time against a
  # file the first fix had just created - since the two kinds' templates
  # render different content, that trips Thor's interactive file-collision
  # menu, which would hang (or misbehave) in a non-interactive --fix run.
  # check_companion's fix now re-checks File.exist? immediately before
  # rendering, so the second fix is a safe no-op.
  test "a companion shared by two action kinds with the same name is fixed once, without a collision" do
    with_valid_scaffold_files!
    register_action_fix_cleanup!
    write_fixture("config/root_actions/dup_action.rb", <<~RUBY)
      RailsAdmin::Config::Actions.add_action "dup_action", :base, :root do
          http_methods [:get]
      end
    RUBY
    write_fixture("config/member_actions/dup_action.rb", <<~RUBY)
      RailsAdmin::Config::Actions.add_action "dup_action", :base, :member do
          http_methods [:get, :patch]
      end
    RUBY

    invoke_task("--fix")

    assert File.exist?(File.join(DUMMY_ROOT, "app/views/rails_admin/main/dup_action.html.erb"))

    out_after = invoke_task
    refute_match(/dup_action: missing companion/, out_after)
  end
end
