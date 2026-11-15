require 'test_helper'
require 'socket'
require 'roma/logging/rlogger'
require 'roma/messaging/connection_pool'
require 'auth_node'

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

  SECRET = 'a secret of the cluster'.freeze

  # A new connection is authenticated by the secret.
  def test_authenticated_connection
    node = AuthNode.new(SECRET)
    @pool.secret = SECRET
    con = @pool.checkout(node.node_id)
    con.write("whoami\r\n")
    assert_equal "AUTHENTICATED\r\n", con.gets
  ensure
    con&.close
    node&.close
  end

  # A node with another secret, such as one of the replica cluster, still
  # takes the commands without it.
  def test_connection_rejected_by_the_node
    node = AuthNode.new('another secret of a cluster')
    @pool.secret = SECRET
    con = @pool.checkout(node.node_id)
    con.write("whoami\r\n")
    assert_equal "UNAUTHENTICATED\r\n", con.gets
  ensure
    con&.close
    node&.close
  end

  # The node that never answers gives no connection.
  def test_authentication_times_out
    @pool.secret = SECRET
    assert_nil @pool.checkout(@node_id)
  end
end
