require 'test_helper'
require 'roma/event/em_connection_pool'

class EMConnectionPoolTest < Test::Unit::TestCase
  # A node that accepts connections and never answers.
  module SilentNode; end

  def setup
    @pool = Roma::Event::EMConnectionPool.send(:new)
    @pool.timeout = 0.2
  end

  # A fiber that waits for a node that hangs gets nil after the timeout,
  # and the connection is closed.
  def test_answer_times_out
    reply = :none
    started = nil
    EM.run do
      server = EM.start_server('127.0.0.1', 0, SilentNode)
      port = Socket.unpack_sockaddr_in(EM.get_sockname(server))[0]
      Fiber.new do
        con = @pool.checkout("127.0.0.1_#{port}")
        con.fiber = Fiber.current
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        con.write("whoami\r\n")
        reply = con.gets
        EM.stop
      end.resume
      EM.add_timer(5) { EM.stop }
    end
    assert_nil reply
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
  end

  # A connection in the pool isn't closed for waiting.
  def test_checkin_clears_the_timeout
    timeouts = []
    EM.run do
      server = EM.start_server('127.0.0.1', 0, SilentNode)
      port = Socket.unpack_sockaddr_in(EM.get_sockname(server))[0]
      ap = "127.0.0.1_#{port}"
      con = @pool.checkout(ap)
      timeouts << con.comm_inactivity_timeout
      @pool.checkin(ap, con)
      timeouts << con.comm_inactivity_timeout
      EM.stop
    end
    assert_equal([0.2, 0], timeouts.map { |t| t.round(1) })
  end
end
