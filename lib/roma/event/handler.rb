#
# File: handler.rb
#
require 'eventmachine'
require 'roma/event/em_connection_pool'
require 'roma/event/distance'
require 'roma/logging/rlogger'
require 'roma/stats'
require 'roma/storage/basic_storage'
require 'socket'
require 'roma/configuration'

module Roma
  module Event
    class Handler < EventMachine::Connection
      @@event_list = {}
      def self.event_list = @@event_list
      @@system_commands = {}
      def self.system_commands = @@system_commands

      @@continuous_limit_start = 200
      @@continuous_limit_rate = 30
      @@continuous_limit_full = 300

      def self.continuous_limit
        "#{@@continuous_limit_start}:#{@@continuous_limit_rate}:#{@@continuous_limit_full}"
      end

      def self.update_continuous_limit(continuous_limit)
        if continuous_limit =~ /^(\d+):(\d+):(\d+)$/
          s = ::Regexp.last_match(1).to_i
          r = ::Regexp.last_match(2).to_i
          f = ::Regexp.last_match(3).to_i
          return false if s < 0 || f < 0 || r < 0 || r > 100 || s > f

          @@continuous_limit_start = s
          @@continuous_limit_rate = r
          @@continuous_limit_full = f
          true
        else
          false
        end
      end

      @@connections = {}
      def self.connections = @@connections

      @@connection_expire_time = 60
      def self.connection_expire_time=(t)
        @@connection_expire_time = t
      end

      def self.connection_expire_time
        @@connection_expire_time
      end

      @@timeout = 10
      def self.timeout=(n)
        @@timeout = n
      end

      def self.timeout
        @@timeout
      end

      attr_reader :connected, :lastcmd, :last_access, :addr, :port

      def initialize(storages, routing_table)
        @read_buffer = ''
        unless has_event?
          public_methods.each do |m|
            add_event(m.to_s[3..-1], m) if m.to_s.start_with?('ev_')
          end
        end
        @th1 = 100
        @close_rate = 70
        @th2 = 200

        @storages = storages
        @routing_table = routing_table
        @log = Roma::Logging::RLogger.instance
        @last_access = Time.now
      end

      def post_init
        @port, @addr = Socket.unpack_sockaddr_in(get_peername)
        @log.info("Connected from #{@addr}:#{@port}. I have #{EM.connection_count} connections.")
        @connected = true
        @last_access = Time.now
        @@connections[self] = @last_access
        @fiber = Fiber.new { dispatcher }
      rescue Exception => e
        @log.error("#{__FILE__}:#{__LINE__}:#{e.inspect} #{$@}")
      end

      def receive_data(data)
        @read_buffer << data
        @last_access = Time.now
        @fiber.resume
      rescue Exception => e
        @log.error("#{__FILE__}:#{__LINE__}:#{@addr}:#{@port} #{e.inspect} #{$@}")
      end

      def unbind
        @connected = false
        begin
          @fiber.resume
        rescue FiberError
        end
        EventMachine.stop_event_loop if @stop_event_loop
        @@connections.delete(self)
        if @enter_time
          # hilatency check
          ps = monotonic_time - @enter_time
          @log.warn("#{@lastcmd} has incompleted, passage of #{ps} seconds") if ps > @stats.hilatency_warn_time
        end
        @log.info("Disconnected from #{@addr}:#{@port}")
      rescue Exception => e
        @log.warn("#{__FILE__}:#{__LINE__}:#{@addr}:#{@port} #{e.inspect} #{$@}")
      end

      protected

      def has_event?
        @@event_list.length != 0
      end

      def add_event(c, m)
        @@event_list[c] = m
      end

      def exit
        EventMachine.stop_event_loop
      end

      private

      def checkout_connection(ap)
        con = Roma::Event::EMConnectionPool.instance.checkout(ap)
        con.fiber = @fiber
        con
      end

      def checkin_connection(ap, con)
        Roma::Event::EMConnectionPool.instance.checkin(ap, con)
      end

      def dispatcher
        @stats = Roma::Stats.instance
        # @log.debug("Roma::Event::Handler.dipatcher called")
        while @connected
          @enter_time = nil
          next unless s = gets

          @enter_time = monotonic_time
          s = s.chomp.split(/ /)
          cmd = s[0]&.downcase
          # check whether comand was send or not? and check this command listed on ROMA?
          if cmd && @@event_list.key?(cmd)
            send(@@event_list[cmd], s)
            @lastcmd = s
            next if @@system_commands.key?(cmd)
          elsif s.length == 0
            next
          elsif s[0] == '!!'
            send(@@event_list[@lastcmd[0].downcase], @lastcmd)
            next if @@system_commands.key?(@lastcmd[0].downcase)
          else
            distance, similar_cmd = Roma::Event::Distance.check_distance(s[0], @@event_list)
            if distance < 0.2
              send_data("\r\nERROR: '#{s[0]}' is not roma command.\r\nDid you mean this?\r\n\t#{similar_cmd}\r\n")
              next
            else
              @log.warn("command error:#{s}")
              send_data("ERROR: '#{s[0]}' is not roma command. Please check command.\r\n(closing telnet connection command is 'quit')\r\n")
              next
            end
          end

          # hilatency check
          ps = monotonic_time - @enter_time
          @log.warn("hilatency occurred in #{@lastcmd} put in a #{ps} seconds") if ps > @stats.hilatency_warn_time
          # check latency average
          @stats.record_latency(@lastcmd[0], ps) if @stats.latency_log && @stats.latency_check_cmd.include?(@lastcmd[0])

          d = EM.connection_count - @@continuous_limit_start
          next unless d > 0 &&
                      rand(100) < @@continuous_limit_rate + ((100 - @@continuous_limit_rate) * d / (@@continuous_limit_full - @@continuous_limit_start))

          send_data("ERROR\r\n")
          close_connection_after_writing
          @log.warn("Connection count > #{@@continuous_limit_start}:closed")
        end
      rescue Storage::StorageException => e
        @log.error("#{e.inspect} #{s} #{$@}")
        send_data("SERVER_ERROR #{e} in storage engine\r\n")
        close_connection_after_writing
        if Roma.config.storage.exception_action == :shutdown
          @log.error('The server will stop')
          @stop_event_loop = true
        end
      rescue Exception => e
        @log.warn("#{__FILE__}:#{__LINE__}:#{@addr}:#{@port} #{e} #{$@}")
        close_connection
      end

      # Takes +size+ bytes from the read buffer and drops +skip+ bytes after
      # them, or returns nil if it doesn't have them yet.
      def pop(size, skip = 0)
        return if size < 0
        return unless @read_buffer.bytesize >= size + skip
        return @read_buffer.slice!(0, size) if @read_buffer.bytesize == size

        # Faster than slice!, which also makes a string for the rest. []=
        # counts characters, but EventMachine gives binary data, so the
        # buffer is binary or ASCII and they are bytes.
        data = @read_buffer.byteslice(0, size)
        @read_buffer[0, size + skip] = ''.freeze
        data
      end

      def read_bytes(size, mult = 1, skip: 0)
        t = monotonic_time
        while @connected
          d = pop(size, skip)
          return d if d

          remain = size + skip - @read_buffer.bytesize
          Fiber.yield(remain)
          next unless monotonic_time - t > @@timeout * mult

          @log.warn("#{__FILE__}:#{__LINE__}:#{@addr}:#{@port} read_bytes time out")
          close_connection
          return nil

        end
        nil
      end

      # Reads a value of +size+ bytes and the CRLF after it, and returns the
      # value.
      def read_value(size, mult = 1)
        read_bytes(size, mult, skip: 2)
      end

      def gets
        while @connected
          idx = @read_buffer.index("\n")
          return pop(idx + 1) if idx

          Fiber.yield(@read_buffer.size)

        end
        nil
      end

      # Seconds as a Float, which unlike Time.now allocates no object.
      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def detach_socket
        @connected = false
        Socket.for_fd(detach)
      end

      def connection_stat
        ret = {}
        ret['connection.count'] = EM.connection_count
        ret['connection.descriptor_table_size'] = EM.set_descriptor_table_size
        ret['connection.continuous_limit'] = Handler.continuous_limit
        ret['connection.accepted_connection_expire_time'] = Handler.connection_expire_time
        ret['connection.handler_instance_count'] = Handler.connections.length
        ret['connection.pool_maxlength'] = Messaging::ConnectionPool.instance.maxlength
        ret['connection.pool_expire_time'] = Messaging::ConnectionPool.instance.expire_time
        ret['connection.EMpool_maxlength'] = Event::EMConnectionPool.instance.maxlength
        ret['connection.EMpool_expire_time'] = Event::EMConnectionPool.instance.expire_time
        ret
      end
    end # class Handler < EventMachine::Connection
  end # module Event
end # module Roma
