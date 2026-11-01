require 'eventmachine'
require 'roma/logging/rlogger'

module Roma
  module Event
    module EMConnection
      attr_writer :fiber
      attr_reader :connected
      attr_accessor :ap
      attr_accessor :last_access

      def post_init
        @rbuf = ''
        @connected = true
        @last_access = Time.now
      end
      
      def receive_data(data)
        @rbuf << data
        @fiber.resume
      rescue =>e
        Roma::Logging::RLogger.instance.error("#{__FILE__}:#{__LINE__}:#{e.inspect} #{$@}")
      end

      def unbind
        @connected = nil
        @fiber.resume
      rescue FiberError
      rescue =>e
        Roma::Logging::RLogger.instance.warn("#{__FILE__}:#{__LINE__}:#{e.inspect} #{$@}")
      end

      def send(data)
        send_data(data)
      end

      def pop(size)
        if @rbuf.size >= size
          r = @rbuf[0..size-1]
          @rbuf = @rbuf[size..-1]
          r
        else
          nil
        end
      end

      def read_bytes(size)
        while(@connected) do
          d = pop(size)
          if d
            return d
          else
            remain = size - @rbuf.size
            Fiber.yield(remain)
          end
        end
        nil
      end

      def gets
        while(@connected) do
          if idx = @rbuf.index("\n")
            return pop(idx+1)
          else
            Fiber.yield(@rbuf.size)
          end
        end
        nil
      end

    end # module EMConnection
  end # module Event
end # module Roma
