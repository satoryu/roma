require 'test_helper'
require 'zlib'
require 'roma/write_behind'
require 'roma/plugin/plugin_storage'
require 'plugin_test_harness'

# Unit tests for the paths of PluginStorage that StorageCommandTests doesn't
# take: forwarding to the node that has the key, the f* commands that a
# node receives forwarded, other hashes, write-behind and replication.
module StorageCommandForwardHelper
  NID = PluginTestHarness::NID
  OWNER_NID = PluginTestHarness::REPLICA_NID
  # The other node of the vnodes; not this one.
  OTHER_NID = 'localhost_11213'
  HARNESS = PluginTestHarness.for(Roma::CommandPlugin::PluginStorage)

  # Stands in for a node that can't be reached.
  class DownNode
    def dispatch(_line, _rest)
      raise Errno::ECONNREFUSED
    end
  end

  def teardown
    Roma::WriteBehindProcess.class_variable_get(:@@wb_queue).clear
    Roma::AsyncProcess.queue.clear
  end

  # What was pushed to the write-behind queue.
  def write_behind
    queue = Roma::WriteBehindProcess.class_variable_get(:@@wb_queue)
    Array.new(queue.size) { queue.pop }
  end
end

# Every key belongs to the owner and another node, so this node forwards
# commands to the owner.
class StorageCommandForwardTest < Test::Unit::TestCase
  include StorageCommandForwardHelper

  def setup
    @owner = HARNESS.new(nid: OWNER_NID, nodes: [OWNER_NID, OTHER_NID])
    @conn = HARNESS.new(nodes: [OWNER_NID, OTHER_NID]).forward_to(@owner)
  end

  def stored(key)
    @owner.storage.get(0, key, 0)
  end

  data('set' => ['set', nil, 'value'],
       'add' => ['add', nil, 'value'],
       'replace' => ['replace', 'old', 'value'],
       'append' => ['append', 'old', 'oldvalue'],
       'prepend' => ['prepend', 'old', 'valueold'])
  def test_store(data)
    command, old, expected = data
    @owner.request('set key1 0 0 3', old) if old
    assert_equal "STORED\r\n", @conn.request("#{command} key1 0 0 5", 'value')
    assert_equal expected, stored('key1')
    # The owner sends it to the other node.
    assert_equal [OTHER_NID], @owner.redundant_calls.last[:nodes]
  end

  def test_get
    @owner.request('set key1 0 0 5', 'value')
    assert_equal "VALUE key1 0 5\r\nvalue\r\nEND\r\n", @conn.request('get key1')
    assert_equal "END\r\n", @conn.request('get key2')
  end

  def test_gets
    @owner.request('set key1 0 0 2', 'v1')
    assert_match(/\AVALUE key1 0 2 \d+\r\nv1\r\nEND\r\n\z/, @conn.request('gets key1 key2'))
  end

  def test_delete
    @owner.request('set key1 0 0 5', 'value')
    assert_equal "DELETED\r\n", @conn.request('delete key1')
    assert_nil stored('key1')
    assert_equal "NOT_FOUND\r\n", @conn.request('delete key1')
  end

  def test_cas
    @owner.request('set key1 0 0 5', 'value')
    clk = @conn.request('gets key1')[/VALUE key1 0 5 (\d+)/, 1]
    assert_equal "STORED\r\n", @conn.request("cas key1 0 0 3 #{clk}", 'new')
    assert_equal 'new', stored('key1')
    assert_equal "EXISTS\r\n", @conn.request("cas key1 0 0 3 #{clk}", 'old')
  end

  def test_incr_decr
    @owner.request('set key1 0 0 2', '10')
    assert_equal "15\r\n", @conn.request('incr key1 5')
    assert_equal "12\r\n", @conn.request('decr key1 3')
    assert_equal "NOT_FOUND\r\n", @conn.request('incr key2 1')
  end

  def test_set_expt
    @owner.request('set key1 0 0 5', 'value')
    assert_equal "STORED\r\n", @conn.request('set_expt key1 100')
    assert_in_delta Time.now.to_i + 100, @owner.storage.get_raw(0, 'key1', 0)[3], 2
    assert_equal "NOT_STORED\r\n", @conn.request('set_expt key2 100')
  end

  def test_get_expt
    @owner.request('set key1 0 1735700000 5', 'value')
    assert_equal "1735700000\r\nEND\r\n", @conn.request('get_expt key1 unix')
    assert_equal "END\r\n", @conn.request('get_expt key2 unix')
  end

  # The connection is closed before END.
  def test_get_expt_from_a_node_that_closes_the_connection
    closing = Object.new
    def closing.dispatch(_line, _rest) = ''
    @conn.forward_to(closing)
    assert_equal "SERVER_ERROR Message forward failed.\r\n", @conn.request('get_expt key1')
  end

  # The owner can't be reached.
  data do
    { 'get' => ['get key1', nil], 'gets' => ['gets key1', nil], 'set' => ['set key1 0 0 5', 'value'],
      'delete' => ['delete key1', nil], 'cas' => ['cas key1 0 0 5 1', 'value'],
      'incr' => ['incr key1 1', nil], 'set_expt' => ['set_expt key1 1', nil],
      'get_expt' => ['get_expt key1', nil] }
  end
  def test_forward_failed(data)
    line, value = data
    @conn.forward_to(DownNode.new)
    if line.start_with?('gets')
      # It leaves out the keys it couldn't get.
      assert_equal "END\r\n", @conn.request(line, value)
    else
      assert_equal "SERVER_ERROR Message forward failed.\r\n", @conn.request(line, value)
    end
  end
end

# A node gets f* commands only for keys it has; otherwise the routing tables
# of the nodes differ.
class StorageCommandForwardedTest < Test::Unit::TestCase
  include StorageCommandForwardHelper

  def setup
    # This node isn't in the vnode.
    @conn = HARNESS.new(nodes: [OWNER_NID, OTHER_NID])
  end

  data('fget' => ['fget key1', nil], 'fdelete' => ['fdelete key1', nil],
       'fset' => ['fset key1 0 0 5', 'value'], 'fcas' => ['fcas key1 0 0 5 1', 'value'],
       'fincr' => ['fincr key1 0 1', nil], 'fset_expt' => ['fset_expt key1 1', nil])
  def test_routing_table_is_inconsistent(data)
    line, value = data
    assert_equal "SERVER_ERROR Routing table is inconsistent.\r\n", @conn.request(line, value)
  end

  def test_forwarded_commands
    @conn = HARNESS.new(nodes: [NID, OWNER_NID])
    assert_equal "STORED\r\n", @conn.request('fset key1 0 0 2', '10')
    assert_equal "VALUE key1 0 2\r\n10\r\nEND\r\n", @conn.request('fget key1')
    assert_equal "11\r\n", @conn.request('fincr key1 0 1')
    assert_equal "10\r\n", @conn.request('fdecr key1 0 1')
    assert_equal "STORED\r\n", @conn.request('fset_expt key1 100')
    assert_equal "DELETED\r\n", @conn.request('fdelete key1')
    assert_equal "END\r\n", @conn.request('fget key1')
  end
end

class StorageCommandHashTest < Test::Unit::TestCase
  include StorageCommandForwardHelper

  def setup
    @conn = HARNESS.new
  end

  data do
    { 'get' => ['get key1\enohash', nil], 'set' => ['set key1\enohash 0 0 1', 'v'],
      'delete' => ['delete key1\enohash', nil], 'cas' => ['cas key1\enohash 0 0 1 1', 'v'],
      'incr' => ['incr key1\enohash 1', nil], 'set_expt' => ['set_expt key1\enohash 1', nil],
      'get_expt' => ['get_expt key1\enohash', nil], 'fget' => ['fget key1\enohash', nil],
      'fdelete' => ['fdelete key1\enohash', nil], 'fset_expt' => ['fset_expt key1\enohash 1', nil] }.transform_values do |line, value|
      [line.gsub('\e', "\e"), value]
    end
  end
  def test_unknown_hash(data)
    line, value = data
    assert_equal "SERVER_ERROR nohash does not exists.\r\n", @conn.request(line, value)
  end

  def test_get_expt
    @conn.request('set key1 0 1735700000 5', 'value')
    assert_equal "1735700000\r\nEND\r\n", @conn.request('get_expt key1 unix')
    assert_equal "#{Time.at(1735700000)}\r\nEND\r\n", @conn.request('get_expt key1')
    assert_equal "END\r\n", @conn.request('get_expt key2')
    assert_equal "CLIENT_ERROR Wrong format of arguments.\r\n", @conn.request('get_expt key1 utc')
    assert_equal "CLIENT_ERROR Wrong number of arguments.\r\n", @conn.request('get_expt')
  end

  def test_set_size_of_zredundant
    broadcasts = []
    @conn.define_singleton_method(:broadcast_cmd) { |cmd| broadcasts << cmd; { OWNER_NID => 'STORED' } }
    assert_equal "#{{ OWNER_NID => 'STORED', NID => 'STORED' }}\r\n", @conn.request('set_size_of_zredundant 100')
    assert_equal ["rset_size_of_zredundant 100\r\n"], broadcasts
    assert_equal 100, @conn.stats.size_of_zredundant
    assert_equal "STORED\r\n", @conn.request('rset_size_of_zredundant 200')
    assert_equal 200, @conn.stats.size_of_zredundant
  end

  data('set' => 'set_size_of_zredundant', 'rset' => 'rset_size_of_zredundant')
  def test_set_size_of_zredundant_usage(command)
    assert_equal "usage:#{command} <n>\r\n", @conn.request("#{command} 0")
  end
end

class StorageCommandWriteBehindTest < Test::Unit::TestCase
  include StorageCommandForwardHelper

  def setup
    @conn = HARNESS.new
    @conn.storages['other'] = Roma::Storage::RubyHashStorage.new.tap do |st|
      st.vn_list = [0]
      st.opendb
    end
  end

  def test_write_behind
    @conn.stats.wb_command_map = { set: 1, set__prev: 2, delete: 3, delete__prev: 4, incr: 5, incr__prev: 6,
                                   cas: 7, cas__prev: 8, set_expt: 9, set_expt__prev: 10 }
    @conn.request('set key1 0 0 1', '1')
    @conn.request('set key1 0 0 1', '2')
    @conn.request('incr key1 1')
    clk = @conn.request('gets key1')[/VALUE key1 0 1 (\d+)/, 1]
    @conn.request("cas key1 0 0 1 #{clk}", '5')
    @conn.request('set_expt key1 100')
    @conn.request('delete key1')
    pushed = write_behind.map { |_hname, cmd, _key, value| [cmd, value] }
    # set_expt's value is the time the key expires.
    assert_in_delta Time.now.to_i + 100, pushed[8][1].to_i, 2
    pushed[8][1] = 'expt'
    # An expiry of 0 is stored as 0x7fffffff.
    assert_equal [[1, '1'], [2, '1'], [1, '2'], [6, '2'], [5, '3'], [8, '3'], [7, '5'],
                  [10, '2147483647'], [9, 'expt'], [4, '5'], [3, '5']], pushed
  end

  # With cluster replication, every change is also queued for the replica
  # cluster.
  def test_cluster_replication
    @conn.instance_variable_get(:@romad).cr_writer.run_replication = true
    @conn.request('set key1 0 0 1', '1')
    @conn.request('incr key1 1')
    clk = @conn.request('gets key1')[/VALUE key1 0 1 (\d+)/, 1]
    @conn.request("cas key1 0 0 1 #{clk}", '5')
    @conn.request('set_expt key1 100')
    @conn.request('delete key1')
    pushed = write_behind.map { |_hname, cmd, _key, _value| cmd }
    assert_in_delta Time.now.to_i + 100, pushed[3][/set_expt key1 (\d+)/, 1].to_i, 2
    pushed[3] = pushed[3].sub(/ \d+/, ' expt')
    assert_equal ["set key1 1 2147483647 1 \r\n1\r\n", "incr key1 1\r\n", "set key1 0 2147483647 1 \r\n5\r\n",
                  "set_expt key1 expt\r\n", "delete key1\r\n"], pushed
  end

  def test_cluster_replication_of_another_hash
    @conn.instance_variable_get(:@romad).cr_writer.run_replication = true
    @conn.request("set key1\eother 0 0 1", '1')
    @conn.request("incr key1\eother 1")
    # gets replies the key without the hash name.
    clk = @conn.request("gets key1\eother")[/VALUE key1 0 1 (\d+)/, 1]
    assert_equal "STORED\r\n", @conn.request("cas key1\eother 0 0 1 #{clk}", '5')
    assert_equal ["set key1\eother 1 2147483647 1 \r\n1\r\n", "incr key1\eother 1\r\n",
                  "set key1\eother 0 2147483647 1 \r\n5\r\n"],
                 write_behind.map { |_hname, cmd, _key, _value| cmd }
    # The other node gets the key without the hash name.
    assert_equal %w(key1 key1 key1), @conn.redundant_calls.map { |call| call[:key] }
  end
end

# PluginStorage#redundant, which the harness stubs elsewhere.
class StorageCommandRedundantTest < Test::Unit::TestCase
  include StorageCommandForwardHelper

  # The other node: answers rset and rzset, and records them.
  class Node
    attr_reader :received
    attr_accessor :reply

    def initialize
      @received = []
      @reply = "STORED\r\n"
    end

    def dispatch(line, rest)
      @received << [line, rest]
      @reply
    end
  end

  def setup
    @conn = HARNESS.new
    @node = Node.new
    @conn.forward_to(@node)
    # Call the real one.
    redundant = Roma::CommandPlugin::PluginStorage.instance_method(:redundant)
    @conn.define_singleton_method(:redundant) { |*args| redundant.bind(self).call(*args) }
  end

  def test_redundant
    @conn.request('set key1 0 0 5', 'value')
    line, rest = @node.received.last
    assert_match(/\Arset key1\eroma \d+ \d+ \d+ 5\z/, line)
    assert_equal "value\r\n", rest
  end

  def test_zredundant
    @conn.stats.size_of_zredundant = 3
    @conn.request('set key1 0 0 5', 'value')
    line, rest = @node.received.last
    assert_match(/\Arzset key1\eroma /, line)
    assert_equal 'value', Zlib::Inflate.inflate(rest.chomp)
  end

  data('redundant' => [0, 'redundant'], 'zredundant' => [3, 'zredundant'])
  def test_failed(data)
    size, event = data
    @conn.stats.size_of_zredundant = size
    @node.reply = "ERROR\r\n"
    @conn.request('set key1 0 0 5', 'value')
    # Retried later.
    assert_equal event, Roma::AsyncProcess.queue.pop.event
  end
end
