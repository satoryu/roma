require 'test_helper'
require 'socket'
require 'roma/logging/rlogger'
require 'roma/messaging/connection_pool'

class ConnectionPoolTest < Test::Unit::TestCase
  def setup
    @pool = Roma::Messaging::ConnectionPool.send(:new)
    @pool.timeout = 0.2
    # A node that accepts connections and never answers.
    @server = TCPServer.new('127.0.0.1', 0)
    @accepted = []
    @thread = Thread.new { loop { @accepted << @server.accept } }
    @node_id = "127.0.0.1_#{@server.addr[1]}"
  end

  def teardown
    @thread.kill
    @accepted.each(&:close)
    @server.close
  end

  # A read from a node that hangs gives up after the timeout.
  def test_read_times_out
    con = @pool.checkout(@node_id)
    con.write("whoami\r\n")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raise(IO::TimeoutError) { con.gets }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
  ensure
    con&.close
  end

  def test_check_connection
    assert_true @pool.check_connection(@node_id)
  end
end
