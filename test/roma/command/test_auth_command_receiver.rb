require 'test_helper'
require 'command_test_harness'
require 'roma/peer_auth'

# Unit tests for the authentication by config.cluster_secret
# (Roma::Command::AuthCommandReceiver), and the commands that need it.
class AuthCommandReceiverTest < Test::Unit::TestCase
  NODE_ID = CommandTestHarness::NODE_ID
  OTHER_NODE_ID = CommandTestHarness::OTHER_NODE_ID
  SECRET = 'a secret of the cluster'.freeze
  REQUIRED = "CLIENT_ERROR authentication required\r\n".freeze

  def setup
    Roma.config.cluster_secret = SECRET
    @conn = CommandTestHarness.new
    @routing_table = @conn.routing_table
    @routing_table.enabled_failover = true
  end

  def teardown
    @conn.close
    Roma.reset_config
  end

  # Authenticates the connection by +secret+, and returns the reply to auth.
  def authenticate(secret = SECRET)
    nonce = @conn.request('auth_nonce').chomp
    @conn.request("auth #{Roma::PeerAuth.digest(secret, nonce)}")
  end

  def test_authenticate
    assert_equal "AUTHENTICATED\r\n", authenticate
    assert_equal "ADDED\r\n", @conn.request('join localhost_11213')
  end

  def test_authenticate_by_another_secret
    assert_equal "CLIENT_ERROR authentication failed\r\n", authenticate('another secret of a cluster')
    assert_equal REQUIRED, @conn.request('join localhost_11213')
  end

  # A nonce is for one try, so a reply can't be used again.
  def test_nonce_is_for_one_try
    nonce = @conn.request('auth_nonce').chomp
    digest = Roma::PeerAuth.digest(SECRET, nonce)
    assert_equal "AUTHENTICATED\r\n", @conn.request("auth #{digest}")

    conn = CommandTestHarness.new
    assert_equal "CLIENT_ERROR authentication failed\r\n", conn.request("auth #{digest}")
    conn.request('auth_nonce')
    assert_equal "CLIENT_ERROR authentication failed\r\n", conn.request("auth #{digest}")
  ensure
    conn&.close
  end

  def test_auth_without_a_nonce
    assert_equal "CLIENT_ERROR authentication failed\r\n", @conn.request('auth')
  end

  # Without the secret, any connection is authenticated.
  def test_without_the_secret
    Roma.config.cluster_secret = nil
    assert_equal "ADDED\r\n", @conn.request('join localhost_11213')
    assert_equal "AUTHENTICATED\r\n", @conn.request('auth whatever')
  end

  def test_join
    assert_equal REQUIRED, @conn.request('join localhost_11213')
    assert_equal [NODE_ID, OTHER_NODE_ID], @routing_table.nodes
  end

  def test_leave
    assert_equal REQUIRED, @conn.request("leave #{OTHER_NODE_ID}")
    assert_equal [NODE_ID, OTHER_NODE_ID], @routing_table.nodes

    authenticate
    assert_equal "DELETED\r\n", @conn.request("leave #{OTHER_NODE_ID}")
    assert_equal [NODE_ID], @routing_table.nodes
  end

  # setroute would add a node that the routing table doesn't have.
  def test_setroute
    assert_equal REQUIRED, @conn.request('setroute 0 0 localhost_11213')
    assert_equal [NODE_ID, OTHER_NODE_ID], @routing_table.nodes

    authenticate
    assert_equal "STORED\r\n", @conn.request('setroute 0 0 localhost_11213')
    assert_equal [NODE_ID, OTHER_NODE_ID, 'localhost_11213'], @routing_table.nodes
  end

  data('switch_replication' => 'switch_replication true localhost_21211',
       'rswitch_replication' => 'rswitch_replication true localhost_21211')
  def test_switch_replication(line)
    assert_equal REQUIRED, @conn.request(line)
    assert_false @conn.server.cluster_replication_writer.run_replication
    assert_empty @conn.broadcasts

    authenticate
    assert_match(/ACTIVATED/, @conn.request(line))
    assert_true @conn.server.cluster_replication_writer.run_replication
  end

  # The commands that read are taken without the authentication.
  def test_nodelist
    assert_equal "#{NODE_ID} #{OTHER_NODE_ID}\r\n", @conn.request('nodelist')
  end
end
