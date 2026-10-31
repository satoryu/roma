require 'test_helper'
require 'roma/plugin/plugin_alist'
require 'roma/plugin/plugin_storage'
require 'plugin_test_harness'

# Unit tests for the paths of PluginAshiatoList that ListPluginTests doesn't
# take: errors, writes the storage refuses, ranges and forwarding.
class ListPluginCommandTest < Test::Unit::TestCase
  HARNESS = PluginTestHarness.for(Roma::CommandPlugin::PluginStorage, Roma::CommandPlugin::PluginAshiatoList)
  NID = PluginTestHarness::NID
  OWNER_NID = PluginTestHarness::REPLICA_NID

  # Every command, with its value if it takes one.
  COMMANDS = {
    'alist_at' => ['alist_at key1 0'],
    'alist_clear' => ['alist_clear key1'],
    'alist_delete' => ['alist_delete key1 1', 'a'],
    'alist_delete_at' => ['alist_delete_at key1 0'],
    'alist_empty?' => ['alist_empty? key1'],
    'alist_first' => ['alist_first key1'],
    'alist_gets' => ['alist_gets key1'],
    'alist_gets_with_time' => ['alist_gets_with_time key1'],
    'alist_include?' => ['alist_include? key1 1', 'a'],
    'alist_index' => ['alist_index key1 1', 'a'],
    'alist_insert' => ['alist_insert key1 0 1', 'a'],
    'alist_sized_insert' => ['alist_sized_insert key1 5 1', 'a'],
    'alist_swap_and_insert' => ['alist_swap_and_insert key1 1', 'a'],
    'alist_swap_and_sized_insert' => ['alist_swap_and_sized_insert key1 5 1', 'a'],
    'alist_expired_swap_and_insert' => ['alist_expired_swap_and_insert key1 10 1', 'a'],
    'alist_expired_swap_and_sized_insert' => ['alist_expired_swap_and_sized_insert key1 10 5 1', 'a'],
    'alist_join_with_time' => ['alist_join_with_time key1 1', ','],
    'alist_join' => ['alist_join key1 1', ','],
    'alist_to_json' => ['alist_to_json key1'],
    'alist_last' => ['alist_last key1'],
    'alist_length' => ['alist_length key1'],
    'alist_pop' => ['alist_pop key1'],
    'alist_push' => ['alist_push key1 1', 'a'],
    'alist_sized_push' => ['alist_sized_push key1 5 1', 'a'],
    'alist_swap_and_push' => ['alist_swap_and_push key1 1', 'a'],
    'alist_swap_and_sized_push' => ['alist_swap_and_sized_push key1 5 1', 'a'],
    'alist_expired_swap_and_push' => ['alist_expired_swap_and_push key1 10 1', 'a'],
    'alist_expired_swap_and_sized_push' => ['alist_expired_swap_and_sized_push key1 10 5 1', 'a'],
    'alist_update_at' => ['alist_update_at key1 0 1', 'a'],
    'alist_shift' => ['alist_shift key1'],
    'alist_to_s' => ['alist_to_s key1']
  }.freeze

  # The commands that change the list, and what they reply when the storage
  # refuses the change.
  WRITES = {
    'alist_clear' => 'NOT_CLEARED', 'alist_delete' => 'NOT_DELETED', 'alist_delete_at' => 'NOT_DELETED',
    'alist_insert' => 'NOT_STORED', 'alist_sized_insert' => 'NOT_STORED',
    'alist_swap_and_insert' => 'NOT_STORED', 'alist_swap_and_sized_insert' => 'NOT_STORED',
    'alist_expired_swap_and_insert' => 'NOT_STORED', 'alist_expired_swap_and_sized_insert' => 'NOT_STORED',
    'alist_pop' => 'NOT_STORED', 'alist_push' => 'NOT_STORED', 'alist_sized_push' => 'NOT_STORED',
    'alist_swap_and_push' => 'NOT_STORED', 'alist_swap_and_sized_push' => 'NOT_STORED',
    'alist_expired_swap_and_push' => 'NOT_STORED', 'alist_expired_swap_and_sized_push' => 'NOT_STORED',
    'alist_update_at' => 'NOT_STORED', 'alist_shift' => 'NOT_STORED'
  }.freeze

  def setup
    @conn = HARNESS.new
  end

  def request(name, key: 'key1')
    line, value = COMMANDS[name]
    @conn.request(line.sub('key1', key), value)
  end

  def push(*values)
    values.each { |v| @conn.request("alist_push key1 #{v.bytesize}", v) }
  end

  # An unknown hash makes every command fail, and the error is replied.
  data(COMMANDS.keys.to_h { |name| [name, name] })
  def test_error(name)
    assert_match(/\ASERVER_ERROR /, request(name, key: "key1\enohash"))
  end

  data(WRITES.keys.to_h { |name| [name, name] })
  def test_storage_refuses(name)
    push('a', 'b')
    def (@conn.storage).set(*) = nil
    def (@conn.storage).delete(*) = nil
    assert_equal "#{WRITES[name]}\r\n", request(name)
  end

  # Data stored by set is not a list. The expired_swap commands check it;
  # the others fail to read it. (alist_clear deletes it anyway.)
  data((WRITES.keys - ['alist_clear']).to_h { |name| [name, name] })
  def test_not_a_list(name)
    @conn.request('set key1 0 0 5', 'value')
    if name.include?('expired_swap')
      assert_equal "SERVER_ERROR data other than alist's format already exist.\r\n", request(name)
    else
      assert_match(/\ASERVER_ERROR /, request(name))
    end
  end

  data('alist_expired_swap_and_insert' => 'alist_expired_swap_and_insert key1 x 1',
       'alist_expired_swap_and_sized_insert' => 'alist_expired_swap_and_sized_insert key1 x 5 1',
       'alist_expired_swap_and_push' => 'alist_expired_swap_and_push key1 x 1',
       'alist_expired_swap_and_sized_push' => 'alist_expired_swap_and_sized_push key1 x 5 1')
  def test_invalid_expire_time(line)
    assert_equal "SERVER_ERROR format error in expire-time.\r\n", @conn.request(line, 'a')
  end

  # The first value is the length of the list.
  def test_gets_with_an_index
    push('a', 'b')
    assert_equal "VALUE key1 0 1\r\n2\r\nVALUE key1 0 1\r\nb\r\nEND\r\n", @conn.request('alist_gets key1 1')
    assert_equal "END\r\n", @conn.request('alist_gets key1 2')
  end

  # Each value is followed by the time it was added.
  def test_gets_with_time_with_an_index
    push('a', 'b')
    assert_match(/\AVALUE key1 0 1\r\n2\r\nVALUE key1 0 1\r\nb\r\nVALUE key1 0 \d+\r\n\d+\r\nEND\r\n\z/,
                 @conn.request('alist_gets_with_time key1 1'))
    assert_equal "END\r\n", @conn.request('alist_gets_with_time key1 2')
    assert_match(/\AVALUE key1 0 1\r\n2\r\nVALUE key1 0 1\r\na\r\nVALUE key1 0 \d+\r\n\d+\r\nVALUE key1 0 1\r\nb\r\n/,
                 @conn.request('alist_gets_with_time key1 0..1'))
  end

  def test_join_with_time_with_an_index
    push('a', 'b')
    assert_match(/\AVALUE key1 0 1\r\n2\r\nVALUE key1 0 1\r\nb\r\nVALUE key1 0 \d+\r\n\d+\r\nEND\r\n\z/,
                 @conn.request('alist_join_with_time key1 1 1', ','))
    assert_equal "END\r\n", @conn.request('alist_join_with_time key1 1 2', ',')
  end

  def test_with_time_of_a_missing_key
    assert_equal "END\r\n", @conn.request('alist_gets_with_time key2')
    assert_equal "END\r\n", @conn.request('alist_join_with_time key2 1', ',')
  end
end

# Every key belongs to the owner, so this node forwards commands to it.
class ListPluginForwardTest < Test::Unit::TestCase
  HARNESS = ListPluginCommandTest::HARNESS
  OWNER_NID = PluginTestHarness::REPLICA_NID
  OTHER_NID = 'localhost_11213'

  def setup
    @owner = HARNESS.new(nid: OWNER_NID, nodes: [OWNER_NID, OTHER_NID])
    @conn = HARNESS.new(nodes: [OWNER_NID, OTHER_NID]).forward_to(@owner)
  end

  def test_forward
    assert_equal "STORED\r\n", @conn.request('alist_push key1 1', 'a')
    assert_equal "STORED\r\n", @conn.request('alist_push key1 1', 'b')
    assert_equal "2\r\n", @conn.request('alist_length key1')
    assert_equal "VALUE key1 0 1\r\n2\r\nVALUE key1 0 1\r\na\r\nEND\r\n", @conn.request('alist_gets key1 0')
    assert_equal "END\r\n", @conn.request('alist_gets key2')
  end

  # A command forwarded to this node, though it doesn't have the key.
  def test_forwarded_to_the_wrong_node
    assert_equal "SERVER_ERROR Routing table is inconsistent.\r\n", @conn.request('alist_length key1 forward')
    assert_equal "SERVER_ERROR Routing table is inconsistent.\r\n", @conn.request('alist_push key1 1 forward', 'a')
  end

  # Stands in for a node that replies ERROR, or can't be reached.
  class Node
    def initialize(reply)
      @reply = reply
    end

    def dispatch(_line, _rest)
      raise Errno::ECONNREFUSED unless @reply
      @reply
    end
  end

  data('error' => "ERROR\r\n", 'down' => nil)
  def test_forward_failed(reply)
    @conn.forward_to(Node.new(reply))
    assert_equal "SERVER_ERROR Message forward failed.\r\n", @conn.request('alist_length key1')
    assert_equal "SERVER_ERROR Message forward failed.\r\n", @conn.request('alist_push key1 1', 'a')
  end
end
