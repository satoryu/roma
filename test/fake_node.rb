require 'socket'

# A fake node that receives vnodes pushed by romad (pushv and spushv)
# and keeps them by vnode id.
class FakeNode
  attr_reader :nid, :dat
  # Every command line received, without "\r\n".
  attr_reader :commands
  # Replies to use instead of the usual ones: 'reqpushv' (PUSHED), 'spushv'
  # (READY; the stream isn't read then) and 'spushv result' (STORED). Other
  # commands are answered by their name; a Proc is called with the line, and
  # :close closes the connection.
  attr_reader :replies

  def initialize
    @dat = {}
    @commands = []
    @replies = {}
    @server = TCPServer.new(0)
    @nid = "localhost_#{@server.addr[1]}"
    @thread = Thread.new { accept_loop }
  end

  def close
    @thread.kill
    @server.close
  end

  private

  def accept_loop
    loop do
      Thread.new(@server.accept) { |s| serve(s) }
    end
  end

  def serve(s)
    while res = s.gets
      @commands << res.chomp
      if res.start_with?('reqpushv')
        s.write(@replies['reqpushv'] || "PUSHED\r\n")
      elsif res.start_with?('pushv')
        ss = res.split(' ')
        s.write("READY\r\n")
        len = s.gets.chomp
        @dat[ss[2].to_i] = receive_dump(s, len.to_i)
        s.write("STORED\r\n")
      elsif res.start_with?('spushv')
        ss = res.split(' ')
        if @replies['spushv']
          s.write(@replies['spushv'])
          next
        end
        s.write("READY\r\n")
        @dat[ss[2].to_i] = receive_stream_dump(s)
        s.write(@replies['spushv result'] || "STORED\r\n")
      elsif (reply = @replies[res.split(' ').first])
        break if reply == :close
        s.write(reply.respond_to?(:call) ? reply.call(res) : reply)
      elsif res.start_with?('whoami')
        s.write("ROMA\r\n")
      elsif res.start_with?('rbalse')
        s.write("BYE\r\n")
        break
      else
        s.write("STORED\r\n")
      end
    end
  rescue => e
    p e
    p $ERROR_POSITION
  ensure
    s.close if s
  end

  def receive_stream_dump(sok)
    ret = {}
    v = nil
    loop do
      context_bin = sok.read(20)
      vn, last, clk, expt, klen = context_bin.unpack('NNNNN')

      break if klen == 0 # end of dump ?
      k = sok.read(klen)
      vlen_bin = sok.read(4)
      vlen, =  vlen_bin.unpack('N')
      if vlen != 0
        v = sok.read(vlen)
      end
      ret[k] = [vn, last, clk, expt, v].pack('NNNNa*')
    end
    ret
  end

  def receive_dump(sok, len)
    dmp = String.new
    while (dmp.length != len.to_i)
      dmp = dmp + sok.read(len.to_i - dmp.length)
    end
    sok.read(2)
    if sok.gets == "END\r\n"
      return Marshal.load(dmp)
    else
      return nil
    end
  end
end
