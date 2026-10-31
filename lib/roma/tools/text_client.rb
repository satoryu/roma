require 'socket'
require 'timeout'
require 'roma/tcp_fast_fallback'
require 'roma/tools/error'

module Roma
  module Tools
    # A client of the memcached text protocol for the benchmarks and the
    # tests, instead of the RomaClient of roma-client. A node forwards a
    # request to the nodes that have the key, so one node is enough.
    class TextClient
      # Connects to the first node of +node_ids+, and to the next one after
      # an error. +timeout+ is how long to wait for a reply, in seconds.
      def initialize(node_ids, timeout: 5)
        @node_ids = Array(node_ids)
        raise Error, 'No node is given.' if @node_ids.empty?
        @timeout = timeout
        @next = 0
        @con = nil
      end

      # Returns the reply, STORED or NOT_STORED. Raises Error for another
      # reply, such as SERVER_ERROR, after which the node may read the value
      # as a command, so the connection is closed.
      def set(key, value, expt = 0)
        value = value.to_s.b
        request("set #{key} 0 #{expt} #{value.bytesize}\r\n#{value}\r\n") { |con| reply(con, "set #{key}", %w(STORED NOT_STORED)) }
      end

      # Returns the value, or nil if there is none.
      def get(key)
        request("get #{key}\r\n") do |con|
          res = line(con)
          next nil if res == 'END'
          raise Error, "get #{key}: #{res}" unless res =~ /\AVALUE \S+ \d+ (\d+)/
          value = con.read($1.to_i + 2)
          raise Error, "get #{key}: closed" unless value
          last = line(con)
          raise Error, "get #{key}: #{last}" unless last == 'END'
          value.chomp("\r\n")
        end
      end

      # Returns the reply, DELETED or NOT_FOUND. Raises Error for another.
      def delete(key)
        request("delete #{key}\r\n") { |con| reply(con, "delete #{key}", %w(DELETED NOT_FOUND)) }
      end

      def close
        @con&.close
        @con = nil
      end

      private

      # Raises Error, after which the next node is used.
      def request(data)
        Timeout.timeout(@timeout) do
          con = connection
          con.write(data)
          yield con
        end
      rescue SystemCallError, SocketError, IOError, Timeout::Error, Error => e
        nid = @node_ids[(@next - 1) % @node_ids.size]
        close
        raise e if e.is_a?(Error)
        raise Error, "#{nid}: #{e.message}"
      end

      def connection
        return @con if @con
        nid = @node_ids[@next % @node_ids.size]
        @next += 1
        host, port = nid.split(/[:_]/)
        @con = TCPSocket.new(host, port)
      end

      def reply(con, cmd, expected)
        res = line(con)
        raise Error, "#{cmd}: #{res}" unless expected.include?(res)
        res
      end

      def line(con)
        res = con.gets
        raise Error, 'The connection was closed.' unless res
        res.chomp
      end
    end
  end
end
