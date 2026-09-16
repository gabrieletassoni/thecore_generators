require "optparse"
require "thecore_generators/check_practices"

namespace :thecore do
  desc "Audit Thecore scaffolding conventions (Scaffold Files, Models, Actions). " \
    "Usage: rails thecore:check_practices -- [--json] [--atom=NAME] [--fix]"
  task check_practices: :environment do
    # Rake's own option parser only understands its own flags (--trace, -T,
    # ...) - anything meant for the task itself must follow a literal `--`
    # separator, which Rake then leaves untouched at the front of ARGV (see
    # https://ruby.github.io/rake/doc/rakefile_rdoc.html#label-Task+Arguments,
    # the standard convention for passing CLI-style flags to a rake task).
    extra_argv = ARGV.drop_while { |arg| arg != "--" }
    extra_argv.shift

    options = { json: false, atom: nil, fix: false }
    OptionParser.new do |parser|
      parser.on("--json", "Emit structured JSON instead of human-readable text") { options[:json] = true }
      parser.on("--atom=NAME", "Scope the audit to a single ATOM under vendor/submodules/") { |value| options[:atom] = value }
      parser.on("--fix", "Apply every fixable violation in one pass, no confirmation") { options[:fix] = true }
    end.parse!(extra_argv)

    begin
      violations = Thecore::CheckPractices.run(app_root: Rails.root, atom_name: options[:atom], fix: options[:fix])
    rescue Thor::Error => e
      abort(e.message)
    end

    puts(options[:json] ? Thecore::CheckPractices::Reporter.json(violations) : Thecore::CheckPractices::Reporter.text(violations))

    exit(1) unless violations.empty?
  end
end
