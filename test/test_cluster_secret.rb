require 'test_helper'
require 'roma/tools/admin_client'

# The nodes of a cluster with config.cluster_secret, which authenticate the
# connections between them, and need it for the commands between them.
class ClusterSecretTest < Test::Unit::TestCase
  include RomaTestUtils

  SECRET = 'the secret of the test cluster'.freeze
  CONFIG = 'config4secret.rb'.freeze
  JOIN_NODE = 'localhost_11213'.freeze

  def setup
    start_roma(CONFIG)
    # The connections of the test, such as those that stop the nodes.
    Roma::Messaging::ConnectionPool.instance.secret = SECRET
    @rc = RomaTestClient.new(DEFAULT_NODES)
  end

  def teardown
    stop_roma
    wait_until_down([JOIN_NODE])
  ensure
    Roma::Messaging::ConnectionPool.instance.secret = nil
  end

  # Sends +line+ to +node+ by a connection without the secret, and returns
  # the reply.
  def request(node, line)
    host, port = node.split('_')
    TCPSocket.open(host, port) do |con|
      con.write("#{line}\r\n")
      con.gets
    end
  end

  # The data is replicated to the other node by rset and rdelete.
  def test_replication
    assert_equal 'STORED', @rc.set('key1', 'value1')
    DEFAULT_NODES.each do |node|
      # The client stores the value by Marshal.
      assert_eventually_equal(true) { request(node, 'fget key1').start_with?('VALUE key1 0 ') }
    end

    assert_equal 'DELETED', @rc.delete('key1')
    DEFAULT_NODES.each do |node|
      assert_eventually_equal("END\r\n") { request(node, 'fget key1') }
    end
  end

  data('rset' => 'rset key1 0 0 1 1', 'rdelete' => 'rdelete key1 1', 'spushv' => 'spushv roma 0',
       'out' => 'out key1 0', 'reqpushv' => "reqpushv 0 #{DEFAULT_NODES[1]} true", 'rbalse' => 'rbalse',
       'rcreatehash' => 'rcreatehash hash1', 'join' => 'join localhost_11299',
       'balse' => 'balse', 'shutdown_self' => 'shutdown_self', 'release' => 'release',
       'createhash' => 'createhash hash1', 'set_log_level' => 'set_log_level debug',
       'gather_logs' => 'gather_logs 2000-01-01T00:00:00')
  def test_commands_without_the_secret(line)
    assert_equal "CLIENT_ERROR authentication required\r\n", request(DEFAULT_NODES[0], line)
    assert_equal "#{DEFAULT_NODES.join(' ')}\r\n", request(DEFAULT_NODES[0], 'nodelist')
  end

  def test_admin_command_with_the_secret
    client = Roma::Tools::AdminClient.new(secret: SECRET)
    assert_equal({ DEFAULT_NODES[1] => 'STORED', DEFAULT_NODES[0] => 'STORED' }.to_s,
                 client.request(DEFAULT_NODES[0], 'set_log_shift_size 4096'))
    assert_equal "stats.log_shift_size 4096\r\n", request(DEFAULT_NODES[1], 'stat log_shift_size')
  end

  # The node joins, and the vnodes are pushed to it by reqpushv and spushv.
  def test_join
    10.times { |i| assert_equal 'STORED', @rc.set("key#{i}", "value#{i}") }
    join_roma(JOIN_NODE, CONFIG)
    wait_join(JOIN_NODE)

    assert_equal "#{[*DEFAULT_NODES, JOIN_NODE].join(' ')}\r\n", request(DEFAULT_NODES[0], 'nodelist')
    # wait_join may return before the join process starts on a slow node.
    assert_eventually_equal(true) do
      stats = @rc.stats(node: JOIN_NODE)
      stats['routing.primary'].to_i.positive? && stats['stats.run_join'] == 'false'
    end
    @rc.update_rttable
    10.times { |i| assert_equal "value#{i}", @rc.get("key#{i}") }
  end

  def test_join_without_the_secret
    assert_false join_roma(JOIN_NODE)
    assert_equal "#{DEFAULT_NODES.join(' ')}\r\n", request(DEFAULT_NODES[0], 'nodelist')
  end
end
