module Thecore
  module Generators
    # Fetches one asset from thecore's own samples/ directory, via one overridable
    # point: ENV["THECORE_SAMPLES_SOURCE"], resolved fresh on every call (never
    # memoized), defaulting to the real raw GitHub URL for thecore's samples/ on
    # `master` (thecore's own default branch). An http(s) value is fetched over the
    # network via Thor's `get`; anything else is treated as a local directory and
    # read directly with `File.read` (this gem's own tests point it at a fixture,
    # so the suite runs offline and deterministically). Blank-string-safe
    # (`nil? || empty?`, not `||` alone — `ENV["X"] || default` would treat
    # THECORE_SAMPLES_SOURCE="" as a real override). Always writes `force: true` —
    # a clean overwrite, no interactive Thor conflict prompt. Fails fast, naming
    # the file/source/underlying error, rather than letting a raw
    # OpenURI::HTTPError propagate and leave the caller half-scaffolded.
    #
    # A plain module function, not a mixin — `get`/`create_file` are public
    # Thor::Actions instance methods (verified directly against Thor's own
    # source), so they're callable on any `actor` passed in. `abort` (Kernel's) is
    # private, so it's invoked via `actor.send(:abort, ...)` rather than a direct
    # call — the one place this differs from calling it bare on `self`.
    #
    # A trailing slash on THECORE_SAMPLES_SOURCE is tolerated (`.chomp("/")`) before
    # building the http(s) URL - a natural way to write/copy a base URL, and one
    # `lib/templates/app_template.rb`'s own independent copy does not guard against
    # (its own plain string interpolation would request a double-slashed path,
    # 404ing against most static hosts/CDNs); caught here during review and not
    # backported there, since that copy is intentionally left untouched (see below).
    #
    # AtomGenerator uses this module directly (`require`d normally, like any other
    # file in this gem). The App application template's own `fetch_thecore_sample`
    # (lib/templates/app_template.rb) is a *separate*, deliberately self-contained
    # copy, NOT switched to call this module — that generator's initial version
    # of this comment claimed the reason was instance_eval/mixin incompatibility,
    # which review correctly identified as wrong (a module function needs no
    # inheritance/mixin relationship to its caller; TtyDetection is proof this
    # already works the same way from an instance_eval'd context). The real
    # reason is deployment, not syntax: the App template's primary real-world
    # invocation is `rails new myapp -m https://raw.githubusercontent.com/.../app_template.rb`
    # — Thor's `apply`/`instance_eval` fetches and evaluates *that one URL's
    # content only*, with no mechanism to also pull in a sibling file from this
    # gem's own repo the way a normal `require` would. At the moment that command
    # runs there is no app yet, so nothing has installed `thecore_generators` as a
    # dependency either — a `require "generators/thecore/sample_fetcher"` inside
    # the template would only work by accident (a global gem install happening to
    # already be on the load path), not by design. So the App template keeps its
    # own independent copy, and this module is not a hard requirement it could
    # `require` — extracting it here still removes the duplication between this
    # module and AtomGenerator, `thecore_generators`' own second, in-gem consumer.
    module SampleFetcher
      module_function

      def fetch_thecore_sample(actor, relative_path, destination, label:)
        source = ENV["THECORE_SAMPLES_SOURCE"]
        source = "https://raw.githubusercontent.com/gabrieletassoni/thecore/master/samples" if source.nil? || source.empty?

        if source.start_with?("http://", "https://")
          actor.get("#{source.chomp("/")}/#{relative_path}", destination, force: true)
        else
          actor.create_file(destination, File.read(File.join(source, relative_path)), force: true)
        end
      rescue StandardError => e
        actor.send(:abort, "Failed to fetch #{relative_path} from #{source} (#{e.class}: #{e.message}) " \
          "-- aborting #{label}. Set THECORE_SAMPLES_SOURCE to override the source. If this left " \
          "a partially-generated directory behind, remove it before retrying.")
      end
    end
  end
end
