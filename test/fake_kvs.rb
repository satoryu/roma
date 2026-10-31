require 'socket'

# A fake node that keeps the data of set, and answers get and delete, as
# the memcached text protocol.
class FakeKVS
  attr_reader :nid, :data
  # Every command line received, without "\r\n".
  attr_reader :commands
  # Replies to use instead, by the command name. :close closes the
  # connection.
  attr_reader :replies

  def initialize
    @data = {}
    @commands = []
    @replies = {}
    @server = TCPServer.new(0)
    @nid = "localhost_#{@server.addr[1]}"
    @thread = Thread.new { loop { Thread.new(@server.accept) { |s| serve(s) } } }
  end

  def close
    @thread.kill
    @server.close
  end

  private

  def serve(s)
    while (line = s.gets)
      @commands << line.chomp
      name, key, *args = line.split
      if (reply = @replies[name])
        break if reply == :close
        s.read(args[2].to_i + 2) if name == 'set'
        s.write(reply)
        next
      end
      case name
      when 'set'
        @data[key] = s.read(args[2].to_i + 2).chomp("\r\n")
        s.write("STORED\r\n")
      when 'get'
        s.write("VALUE #{key} 0 #{@data[key].bytesize}\r\n#{@data[key]}\r\n") if @data.key?(key)
        s.write("END\r\n")
      when 'delete'
        s.write(@data.delete(key) ? "DELETED\r\n" : "NOT_FOUND\r\n")
      else
        s.write("ERROR\r\n")
      end
    end
  rescue IOError, SystemCallError
    nil
  ensure
    s.close
  end
end
