require 'test/unit'
require 'plugin_test_harness'
require 'roma/plugin/plugin_map'

# Unit tests for the map plugin commands. They run in-process, so no romad is
# started. Forwarding between nodes is covered by test_mapplugin.rb.
class MapPluginCommandTest < Test::Unit::TestCase
  def setup
    @conn = PluginTestHarness.for(Roma::CommandPlugin::PluginMap).new
  end

  def map_set(key, mapkey, value, expt = 0)
    @conn.request("map_set #{key} #{mapkey} 0 #{expt} #{value.bytesize}", value)
  end

  def mk_data(n = 3)
    n.times { |i| map_set('key1', "mapkey#{i}", "value#{i}") }
  end

  def stored_map(key)
    Marshal.load(@conn.storage.get(0, key, 0))
  end

  def test_map_set
    assert_equal "STORED\r\n", map_set('key1', 'mapkey1', 'value1')
    assert_equal({ 'mapkey1' => 'value1' }, stored_map('key1'))
  end

  def test_map_set_overwrites_mapkey
    map_set('key1', 'mapkey1', 'value1')
    map_set('key1', 'mapkey2', 'value2')
    map_set('key1', 'mapkey1', 'value3')
    assert_equal({ 'mapkey1' => 'value3', 'mapkey2' => 'value2' }, stored_map('key1'))
  end

  def test_map_set_counts_and_replicates
    map_set('key1', 'mapkey1', 'value1')
    assert_equal 1, @conn.stats.write_count
    assert_equal 1, @conn.redundant_calls.length
    call = @conn.redundant_calls.first
    assert_equal [PluginTestHarness::REPLICA_NID], call[:nodes]
    assert_equal 'key1', call[:key]
    assert_equal({ 'mapkey1' => 'value1' }, Marshal.load(call[:value]))
  end

  def test_map_set_with_expired_time
    # An absolute time in the past makes the key expire immediately.
    map_set('key1', 'mapkey1', 'value1', Time.now.to_i - 1)
    assert_equal "END\r\n", @conn.request('map_get key1 mapkey1')
  end

  def test_map_get
    map_set('key1', 'mapkey1', 'value1')
    assert_equal "VALUE key1 0 6\r\nvalue1\r\nEND\r\n", @conn.request('map_get key1 mapkey1')
    assert_equal 1, @conn.stats.read_count
  end

  def test_map_get_missing
    assert_equal "END\r\n", @conn.request('map_get key1 mapkey1')
    map_set('key1', 'mapkey1', 'value1')
    assert_equal "END\r\n", @conn.request('map_get key1 mapkey2')
  end

  def test_map_delete
    mk_data
    assert_equal "DELETED\r\n", @conn.request('map_delete key1 mapkey1')
    assert_equal({ 'mapkey0' => 'value0', 'mapkey2' => 'value2' }, stored_map('key1'))
    assert_equal 1, @conn.stats.delete_count
  end

  def test_map_delete_missing
    assert_equal "NOT_FOUND\r\n", @conn.request('map_delete key1 mapkey1')
    mk_data
    assert_equal "NOT_DELETED\r\n", @conn.request('map_delete key1 key1')
  end

  def test_map_clear
    assert_equal "NOT_FOUND\r\n", @conn.request('map_clear key1')
    mk_data
    assert_equal "CLEARED\r\n", @conn.request('map_clear key1')
    assert_equal({}, stored_map('key1'))
  end

  def test_map_size
    assert_equal "NOT_FOUND\r\n", @conn.request('map_size key1')
    mk_data
    assert_equal "3\r\n", @conn.request('map_size key1')
  end

  def test_map_key?
    assert_equal "NOT_FOUND\r\n", @conn.request('map_key? key1 mapkey1')
    mk_data
    assert_equal "true\r\n", @conn.request('map_key? key1 mapkey1')
    assert_equal "false\r\n", @conn.request('map_key? key1 key1')
  end

  def test_map_value?
    assert_equal "NOT_FOUND\r\n", @conn.request('map_value? key1 6', 'value1')
    mk_data
    assert_equal "true\r\n", @conn.request('map_value? key1 6', 'value1')
    assert_equal "false\r\n", @conn.request('map_value? key1 4', 'key1')
  end

  def test_map_empty?
    assert_equal "NOT_FOUND\r\n", @conn.request('map_empty? key1')
    mk_data
    assert_equal "false\r\n", @conn.request('map_empty? key1')
    @conn.request('map_clear key1')
    assert_equal "true\r\n", @conn.request('map_empty? key1')
  end

  def test_map_keys
    assert_equal "END\r\n", @conn.request('map_keys key1')
    mk_data
    expected = "VALUE key1 0 1\r\n3\r\n" \
               "VALUE key1 0 7\r\nmapkey0\r\n" \
               "VALUE key1 0 7\r\nmapkey1\r\n" \
               "VALUE key1 0 7\r\nmapkey2\r\n" \
               "END\r\n"
    assert_equal expected, @conn.request('map_keys key1')
  end

  def test_map_values
    assert_equal "END\r\n", @conn.request('map_values key1')
    mk_data
    expected = "VALUE key1 0 1\r\n3\r\n" \
               "VALUE key1 0 6\r\nvalue0\r\n" \
               "VALUE key1 0 6\r\nvalue1\r\n" \
               "VALUE key1 0 6\r\nvalue2\r\n" \
               "END\r\n"
    assert_equal expected, @conn.request('map_values key1')
  end

  def test_map_to_s
    assert_equal "END\r\n", @conn.request('map_to_s key1')
    map_set('key1', 'mapkey1', 'value1')
    v = { 'mapkey1' => 'value1' }.inspect
    assert_equal "VALUE key1 0 #{v.length}\r\n#{v}\r\nEND\r\n", @conn.request('map_to_s key1')
  end

  def test_unknown_hash_name
    assert_equal "SERVER_ERROR nohash does not exists.\r\n",
                 @conn.request("map_size key1\enohash")
  end

  def test_missing_key
    assert_equal "CLIENT_ERROR does not find key\r\n", @conn.request('map_size')
  end
end
