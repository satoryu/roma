#
# File: em_connection_pool.rb
#
require 'singleton'
require 'socket'
require 'eventmachine'
require 'roma/logging/rlogger'
require 'roma/dns_cache'
require 'roma/event/em_connection'

module Roma
  module Event
    class EMConnectionPool
      include Singleton

      attr_reader :pool
      attr_accessor :maxlength, :expire_time
      # Seconds to wait for a node to connect, or to answer while a
      # connection is checked out. EventMachine closes the connection then,
      # and a fiber waiting for the answer gets nil.
      attr_accessor :timeout

      def initialize
        @pool = {}
        @maxlength = 30
        @expire_time = 30
        @timeout = 10
        @lock = Mutex.new
      end

      def checkout(ap)
        ret = @pool[ap].shift if @pool.key?(ap) && @pool[ap].length > 0
        if ret && @expire_time != 0 && ret.last_access < Time.now - @expire_time
          ret.close_connection if ret.connected
          ret = nil
          Logging::RLogger.instance.info("EM connection expired at #{ap},remains #{@pool[ap].length}")
        end
        ret = create_connection(ap) if ret.nil? || ret.connected != true
        ret.comm_inactivity_timeout = @timeout
        ret
      end

      def checkin(ap, con)
        return if con.connected == false

        # A connection in the pool waits for nothing.
        con.comm_inactivity_timeout = 0
        con.last_access = Time.now
        if @pool.key?(ap) && @pool[ap].length > 0
          if @pool[ap].length > @maxlength
            con.close_connection
          else
            @pool[ap] << con
          end
        else
          @pool[ap] = [con]
        end
      end

      def create_connection(ap)
        host, port = ap.split(/[:_]/)
        addr = DNSCache.instance.resolve_name(host)
        # The server listens on an IPv4 address, so resolve to one.
        # EventMachine 1.2 may pick IPv6 (e.g. ::1 for localhost) otherwise.
        addr = Addrinfo.getaddrinfo(addr, port, :INET, :STREAM).first.ip_address
        con = EventMachine.connect(addr, port, Roma::Event::EMConnection)
        con.pending_connect_timeout = @timeout
        con.ap = ap
        con
      end

      def close_all
        @pool.each_key { |ap| close_at(ap) }
      end

      def close_same_host(ap)
        host, _port = ap.split(/[:_]/)
        @pool.each_key do |eap|
          close_at(eap) if eap.split(/[:_]/)[0] == host
        end
      end

      def close_at(ap)
        return unless @pool.key?(ap)

        @lock.synchronize do
          while @pool[ap].length > 0
            begin
              @pool[ap].shift.close_connection
            rescue StandardError => e
              Roma::Logging::RLogger.instance.error("#{__FILE__}:#{__LINE__}:#{e.inspect}")
            end
          end
          @pool.delete(ap)
        end
      end
    end
  end
end
