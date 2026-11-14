require 'eventmachine'
require 'roma/logging/rlogger'

module Roma
  module Event
    module EMConnection
      attr_writer :fiber
      attr_reader :connected
      attr_accessor :ap, :last_access

      def post_init
        @read_buffer = ''
        @connected = true
        @last_access = Time.now
      end

      def receive_data(data)
        @read_buffer << data
        @fiber.resume
      rescue StandardError => e
        Roma::Logging::RLogger.instance.error("#{__FILE__}:#{__LINE__}:#{e.inspect} #{$@}")
      end

      def unbind
        @connected = nil
        @fiber.resume
      rescue FiberError
      rescue StandardError => e
        Roma::Logging::RLogger.instance.warn("#{__FILE__}:#{__LINE__}:#{e.inspect} #{$@}")
      end

      # Sends +data+ to the node, like IO#write of the connections of
      # Messaging::ConnectionPool.
      def write(data)
        send_data(data)
      end

      def pop(size)
        return unless @read_buffer.size >= size

        r = @read_buffer[0..size - 1]
        @read_buffer = @read_buffer[size..-1]
        r
      end

      def read_bytes(size)
        while @connected
          d = pop(size)
          return d if d

          remain = size - @read_buffer.size
          Fiber.yield(remain)

        end
        nil
      end

      def gets
        while @connected
          idx = @read_buffer.index("\n")
          return pop(idx + 1) if idx

          Fiber.yield(@read_buffer.size)

        end
        nil
      end
    end
  end
end
