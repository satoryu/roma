require 'roma/logging/rlogger'

module Roma
  module Logging
    class StderrWrapper < IO
      def initialize
        @logger = RLogger.instance
      end

      def write(s)
        @logger.error("STDERR:#{s}")
      end

      def flush; end
    end
  end
end
