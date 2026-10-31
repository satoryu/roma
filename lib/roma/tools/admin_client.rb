require 'io/wait'
require 'socket'
require 'timeout'
require 'roma/tcp_fast_fallback'
require 'roma/routing/routing_data'
require 'roma/tools/error'

module Roma
  module Tools
    # Sends admin commands to nodes. The tools use it instead of the Sender
    # of roma-client, so that ROMA doesn't depend on its client.
    class AdminClient
      # +timeout+ is how long to wait for a node, in seconds.
      def initialize(timeout: 5)
        @timeout = timeout
      end

      # Gets the routing data of the node +nid+. Raises Error if it can't.
      def routing_data(nid)
        connect(nid) do |con|
          Timeout.timeout(@timeout) do
            con.write("routingdump\r\n")
            len = con.gets.to_i
            raise Error, "#{nid} has no routing data." if len <= 0
            dump = con.read(len)
            raise Error, "#{nid} closed the connection." unless dump && dump.bytesize == len
            Marshal.load(dump)
          end
        end
      end

      # Sends +cmd+ to the node +nid+, and returns the lines of the reply
      # without "\r\n". Commands end their replies in different ways, so the
      # reply ends when no line comes for +idle+ seconds. Raises Error if
      # nothing comes.
      def command(nid, cmd, idle: 0.1)
        connect(nid) do |con|
          con.write("#{cmd}\r\n")
          lines = []
          wait = @timeout
          while con.wait_readable(wait) && (line = con.gets)
            lines << line.chomp
            wait = idle
          end
          raise Error, "#{nid} didn't reply to #{cmd}." if lines.empty?
          lines
        end
      end

      private

      def connect(nid)
        host, port = nid.split(/[:_]/)
        con = Timeout.timeout(@timeout) { TCPSocket.new(host, port) }
        yield con
      rescue SystemCallError, SocketError, IOError, Timeout::Error => e
        raise Error, "#{nid}: #{e.message}"
      ensure
        con.close if con
      end
    end
  end
end
