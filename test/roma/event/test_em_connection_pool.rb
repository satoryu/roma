require 'test_helper'
require 'roma/event/em_connection_pool'
require 'auth_node'
require 'logger'
require 'stringio'

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

  SECRET = 'a secret of the cluster'.freeze

  # Sends whoami to +node+ by a connection that is authenticated, and
  # returns the reply.
  def whoami_after_authentication(node)
    reply = :none
    EM.run do
      Fiber.new do
        con = @pool.checkout(node.node_id)
        @connection_logger = con.logger
        con.fiber = Fiber.current
        @pool.authenticate(con)
        con.write("whoami\r\n")
        reply = con.gets
        EM.stop
      end.resume
      EM.add_timer(5) { EM.stop }
    end
    reply
  end

  def test_authenticate
    node = AuthNode.new(SECRET)
    @pool.secret = SECRET
    assert_equal "AUTHENTICATED\r\n", whoami_after_authentication(node)
  ensure
    node&.close
  end

  # A node with another secret still takes the commands without it.
  def test_authenticate_rejected_by_the_node
    node = AuthNode.new('another secret of a cluster')
    @pool.secret = SECRET
    @pool.logger = Logger.new(log = StringIO.new)
    assert_equal "UNAUTHENTICATED\r\n", whoami_after_authentication(node)
    assert_match(/WARN -- : #{node.node_id} rejected the secret of the cluster/, log.string)
    # The connections log where the pool does.
    assert_same @pool.logger, @connection_logger
  ensure
    node&.close
  end

  # Without the secret, nothing is sent for it.
  def test_authenticate_without_the_secret
    node = AuthNode.new(SECRET)
    assert_equal "UNAUTHENTICATED\r\n", whoami_after_authentication(node)
  ensure
    node&.close
  end

  # A node that hangs makes the authentication fail, and the connection is
  # closed.
  def test_authenticate_times_out
    @pool.secret = SECRET
    error = con = nil
    EM.run do
      server = EM.start_server('127.0.0.1', 0, SilentNode)
      port = Socket.unpack_sockaddr_in(EM.get_sockname(server))[0]
      Fiber.new do
        con = @pool.checkout("127.0.0.1_#{port}")
        con.fiber = Fiber.current
        begin
          @pool.authenticate(con)
        rescue Roma::PeerAuth::Error => e
          error = e
        end
        EM.next_tick { EM.stop }
      end.resume
      EM.add_timer(5) { EM.stop }
    end
    assert_kind_of Roma::PeerAuth::Error, error
    assert_not_equal true, con.connected
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
