require 'test_helper'
require 'roma/plugin/plugin_map'
require 'plugin_test_harness'

# Forwarding of the commands defined with Roma::Command::Definition, through
# the map plugin: every key belongs to the owner and another node, so this
# node forwards commands to the owner.
class MapPluginForwardTest < Test::Unit::TestCase
  HARNESS = PluginTestHarness.for(Roma::CommandPlugin::PluginMap)
  NID = PluginTestHarness::NID
  OWNER_NID = PluginTestHarness::REPLICA_NID
  OTHER_NID = 'localhost_11213'

  # Stands in for a node: replies +reply+, closes the connection (nil), or
  # can't be reached (:down).
  class Node
    def initialize(reply)
      @reply = reply
    end

    def dispatch(_line, _rest)
      raise Errno::ECONNREFUSED if @reply == :down
      @reply.to_s
    end
  end

  def setup
    @owner = HARNESS.new(nid: OWNER_NID, nodes: [OWNER_NID, OTHER_NID])
    @conn = HARNESS.new(nodes: [OWNER_NID, OTHER_NID]).forward_to(@owner)
  end

  def map_set(conn, key, mapkey, value)
    conn.request("map_set #{key} #{mapkey} 0 0 #{value.bytesize}", value)
  end

  def test_forward
    # A write with a value, replied in one line.
    assert_equal "STORED\r\n", map_set(@conn, 'key1', 'mapkey1', 'value1')
    assert_equal({ 'mapkey1' => 'value1' }, Marshal.load(@owner.storage.get(0, 'key1', 0)))
    # Reads replied in several lines, or one.
    assert_equal "VALUE key1 0 6\r\nvalue1\r\nEND\r\n", @conn.request('map_get key1 mapkey1')
    assert_equal "1\r\n", @conn.request('map_size key1')
    assert_equal "true\r\n", @conn.request('map_value? key1 6', 'value1')
    # A write without a value.
    assert_equal "DELETED\r\n", @conn.request('map_delete key1 mapkey1')
    assert_equal "END\r\n", @conn.request('map_get key1 mapkey1')
  end

  # The node it forwards to thinks another node has the key. It doesn't
  # forward the command again.
  data('one line' => ['map_size key1', nil], 'multi line' => ['map_get key1 mapkey1', nil],
       'with a value' => ['map_set key1 mapkey1 0 0 1', 'v'])
  def test_forwarded_to_the_wrong_node(data)
    line, value = data
    wrong = HARNESS.new(nid: OWNER_NID, nodes: [OTHER_NID, NID]).forward_to(@owner)
    @conn.forward_to(wrong)
    assert_equal "SERVER_ERROR Routing table is inconsistent.\r\n", @conn.request(line, value)
  end

  data do
    { 'error' => "ERROR\r\n", 'closed' => nil, 'down' => :down }.each_with_object({}) do |(name, reply), h|
      h["one line, #{name}"] = ['map_size key1', nil, reply]
      h["multi line, #{name}"] = ['map_get key1 mapkey1', nil, reply]
      h["with a value, #{name}"] = ['map_set key1 mapkey1 0 0 1', 'v', reply]
    end
  end
  def test_forward_failed(data)
    line, value, reply = data
    @conn.forward_to(Node.new(reply))
    assert_equal "SERVER_ERROR Message forward failed.\r\n", @conn.request(line, value)
  end

  # A multi-line read whose reply isn't a value, such as an error.
  def test_forward_of_a_multi_line_read_replied_in_one_line
    @conn.forward_to(Node.new("SERVER_ERROR busy\r\n"))
    assert_equal "SERVER_ERROR busy\r\n", @conn.request('map_get key1 mapkey1')
  end
end
