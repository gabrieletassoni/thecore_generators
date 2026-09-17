module Thecore
  module Generators
    # A caller with no real TTY behind stdin/stdout (CI, a shelled-out child
    # process) can never answer an interactive prompt. Shared by
    # AssociationWiring's own inverse-association cardinality prompt and
    # AtomGenerator's metadata/dependency prompts, extracted after the two
    # independently implemented the identical condition (caught in review,
    # thecore_generators#20) - a single source of truth means a future
    # refinement to this detection (e.g. an ENV["CI"] check) can't silently
    # apply to one generator's prompts and not the other's.
    module TtyDetection
      module_function

      def real_tty?
        $stdin.tty? && $stdout.tty?
      end
    end
  end
end
