require 'socket'
require 'singleton'
require 'logger'
require 'roma/dns_cache'
require 'roma/peer_auth'

module Roma
  module Messaging
    class ConnectionPool
      include Singleton

      attr_accessor :maxlength, :expire_time
      # Seconds to wait for a node to connect, and for each read or write,
      # so that a node that hangs can't take a thread for ever.
      attr_accessor :timeout
      # The secret of the cluster, by which a new connection is
      # authenticated, or nil. See PeerAuth.
      attr_accessor :secret
      # Where it logs. The server sets its logger; before it, nowhere.
      attr_accessor :logger

      def initialize(maxlength = 10, expire_time = 30)
        @logger = Logger.new(nil)
        @pool = {}
        @maxlength = maxlength
        @expire_time = expire_time
        @timeout = 10
        @lock = Mutex.new
      end

      def checkout(ap)
        ret, last = @pool[ap].shift if @pool.key?(ap) && @pool[ap].length > 0
        if ret && @expire_time != 0 && last < Time.now - @expire_time
          ret.close
          ret = nil
          @logger.info("connection expired at #{ap},remains #{@pool[ap].length}")
        end
        return create_connection(ap) unless ret

        ret
      rescue StandardError => e
        @logger.error("#{__FILE__}:#{__LINE__}:#{e}")
        nil
      end

      def check_connection(ap)
        unless @pool.key?(ap)
          host, port = ap.split(/[:_]/)
          addr = DNSCache.instance.resolve_name(host)
          sock = TCPSocket.open(addr, port, connect_timeout: @timeout)
          sock.close
        end
        true
      rescue Errno::ECONNREFUSED
        false
      rescue StandardError => e
        @logger.error("#{__FILE__}:#{__LINE__}:#{e}")
      end

      def checkin(ap, con)
        if select([con], nil, nil, 0.0001)
          con.gets
          con.close
          return
        end

        if @pool.key?(ap) && @pool[ap].length > 0
          if @pool[ap].length > @maxlength
            con.close
          else
            @pool[ap] << [con, Time.now]
          end
        else
          @pool[ap] = [[con, Time.now]]
        end
      rescue StandardError => e
        @logger.error("#{__FILE__}:#{__LINE__}:#{e}")
      end

      def create_connection(ap)
        host, port = ap.split(/[:_]/)
        addr = DNSCache.instance.resolve_name(host)
        sock = TCPSocket.new(addr, port, connect_timeout: @timeout)
        sock.timeout = @timeout
        authenticate(ap, sock) if @secret
        sock
      end

      # A node that rejects the secret, such as one of another cluster for
      # the cluster replication, still takes the commands without it.
      def authenticate(ap, sock)
        return if PeerAuth.authenticate(sock, @secret)

        @logger.warn("#{ap} rejected the secret of the cluster")
      rescue StandardError
        sock.close
        raise
      end

      def delete_connection(ap)
        @pool.delete(ap)
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
              @pool[ap].shift[0].close
            rescue StandardError => e
              @logger.error("#{__FILE__}:#{__LINE__}:#{e}")
            end
          end
          @pool.delete(ap)
        end
      end
    end
  end
end
