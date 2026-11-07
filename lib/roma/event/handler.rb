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
          ps = Time.now - @enter_time
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

          @enter_time = Time.now
          s = s.chomp.split(/ /)
          # check whether comand was send or not? and check this command listed on ROMA?
          if s[0] && @@event_list.key?(s[0].downcase)
            send(@@event_list[s[0].downcase], s)
            @lastcmd = s
            next if @@system_commands.key?(s[0].downcase)
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
          ps = Time.now - @enter_time
          @log.warn("hilatency occurred in #{@lastcmd} put in a #{ps} seconds") if ps > @stats.hilatency_warn_time
          # check latency average
          if @stats.latency_check_cmd.include?(@lastcmd[0])
            Roma::AsyncEvent.queue_latency.push(Roma::AsyncMessage.new('calc_latency_average', [ps, @lastcmd[0]]))
          end

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

      def pop(size)
        if size == 0
          return ''
        elsif size < 0
          return nil
        end

        return unless @read_buffer.size >= size

        r = @read_buffer[0..size - 1]
        @read_buffer = @read_buffer[size..-1]
        r
      end

      def read_bytes(size, mult = 1)
        t = Time.now.to_i
        while @connected
          d = pop(size)
          return d if d

          remain = size - @read_buffer.size
          Fiber.yield(remain)
          next unless Time.now.to_i - t > @@timeout * mult

          @log.warn("#{__FILE__}:#{__LINE__}:#{@addr}:#{@port} read_bytes time out")
          close_connection
          return nil

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
