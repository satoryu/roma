require 'roma/logging/rlogger'

module Roma
  module Logging
    class StderrWrapper < IO

      def initialize
        @log = RLogger.instance
      end

      def write(s)
        @log.error("STDERR:#{s}")
      end

      def flush; end

    end # class StderrWrapper < IO
  end # module Logging
end # module Roma
