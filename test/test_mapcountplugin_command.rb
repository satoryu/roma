require 'test/unit'
require 'json'
require 'time'
require 'plugin_test_harness'
require 'roma/plugin/plugin_mapcount'

# Unit tests for the mapcount plugin commands. They run in-process, so no
# romad is started. test_mapcountplugin.rb checks them through romad.
class MapCountPluginCommandTest < Test::Unit::TestCase
  DATE_FORMAT = Roma::CommandPlugin::PluginMapCount::DATE_FORMAT

  def setup
    @conn = PluginTestHarness.for(Roma::CommandPlugin::PluginMapCount).new
  end

  def request(cmd, key, sub_keys, expt = 0)
    @conn.request("#{cmd} #{key} #{expt} #{sub_keys.bytesize}", sub_keys)
  end

  # Returns the single value in a reply, or nil for "END\r\n".
  def parse_value(res)
    return nil if res == "END\r\n"
    header, rest = res.split("\r\n", 2)
    _, key, _, len = header.split(' ')
    assert_equal 'key1', key
    assert_equal "\r\nEND\r\n", rest[len.to_i..-1]
    rest[0, len.to_i]
  end

  def json(cmd, sub_keys = '', expt = 0)
    v = parse_value(request(cmd, 'key1', sub_keys, expt))
    v && JSON.parse(v)
  end

  def marshal(cmd, sub_keys = '', expt = 0)
    v = parse_value(request(cmd, 'key1', sub_keys, expt))
    v && Marshal.load(v)
  end

  def without_date(h)
    h.reject { |k, _| k == 'last_updated_date' }
  end

  def assert_recent_date(h)
    t = Time.parse(h['last_updated_date'])
    assert_in_delta Time.parse(Time.now.strftime(DATE_FORMAT)), t, 2
  end

  def test_countup
    ret = json('mapcount_countup', 'subkey1')
    assert_equal({ 'subkey1' => 1 }, without_date(ret))
    assert_recent_date(ret)
  end

  def test_countup_multiple_sub_keys
    json('mapcount_countup', 'subkey0,subkey1')
    ret = json('mapcount_countup', 'subkey1')
    assert_equal({ 'subkey0' => 1, 'subkey1' => 2 }, without_date(ret))
  end

  def test_countup_with_count
    json('mapcount_countup', 'subkey0,subkey1')
    ret = json('mapcount_countup', 'subkey0:3, subkey1:10')
    assert_equal({ 'subkey0' => 4, 'subkey1' => 11 }, without_date(ret))
    ret = json('mapcount_countup', 'subkey0:-5')
    assert_equal({ 'subkey0' => -1, 'subkey1' => 11 }, without_date(ret))
  end

  def test_countup_invalid_sub_keys
    assert_equal "CLIENT_ERROR invalid sub_keys format: sub-key\r\n",
                 request('mapcount_countup', 'key1', 'sub-key')
    assert_nil json('mapcount_get')
  end

  def test_countup_counts_and_replicates
    json('mapcount_countup', 'subkey1')
    assert_equal 1, @conn.stats.write_count
    assert_equal [PluginTestHarness::REPLICA_NID], @conn.redundant_calls.first[:nodes]
  end

  def test_countup_ms
    ret = marshal('mapcount_countup_ms', 'subkey0,subkey1:2')
    assert_equal({ 'subkey0' => 1, 'subkey1' => 2 }, without_date(ret))
    assert_recent_date(ret)
  end

  def test_countup_expt
    json('mapcount_countup', 'subkey1', 100)
    assert_in_delta Time.now.to_i + 100, @conn.redundant_calls.last[:expt], 2
    # An absolute time in the past makes the key expire immediately.
    json('mapcount_countup', 'subkey1', Time.now.to_i - 1)
    assert_nil json('mapcount_get')
  end

  def test_get
    assert_nil json('mapcount_get')
    json('mapcount_countup', 'subkey0,subkey1,subkey2')
    ret = json('mapcount_get')
    assert_equal({ 'subkey0' => 1, 'subkey1' => 1, 'subkey2' => 1 }, without_date(ret))
    assert_recent_date(ret)
    assert_equal 2, @conn.stats.read_count
  end

  def test_get_sub_keys
    json('mapcount_countup', 'subkey0,subkey1,subkey2')
    ret = json('mapcount_get', 'subkey0, subkey2,nokey')
    assert_equal({ 'subkey0' => 1, 'subkey2' => 1 }, without_date(ret))
    assert_recent_date(ret)
  end

  def test_get_ms
    assert_nil marshal('mapcount_get_ms')
    json('mapcount_countup', 'subkey0,subkey1')
    assert_equal({ 'subkey1' => 1 }, without_date(marshal('mapcount_get_ms', 'subkey1')))
  end

  def test_update
    assert_nil json('mapcount_update')
    json('mapcount_countup', 'subkey0,subkey1')
    ret = json('mapcount_update')
    assert_equal({ 'subkey0' => 1, 'subkey1' => 1 }, without_date(ret))
    assert_recent_date(ret)
    assert_equal 2, @conn.stats.write_count
  end

  def test_update_sub_keys
    json('mapcount_countup', 'subkey0,subkey1')
    assert_equal({ 'subkey1' => 1 }, without_date(json('mapcount_update', 'subkey1')))
    assert_equal({}, without_date(json('mapcount_update', 'subkey2')))
    # The sub keys only filter the reply; nothing is removed.
    assert_equal({ 'subkey0' => 1, 'subkey1' => 1 }, without_date(json('mapcount_get')))
  end

  def test_update_date
    json('mapcount_countup', 'subkey1')
    stored = Marshal.load(@conn.storage.get(0, 'key1', 0))
    stored['last_updated_date'] = '2000-01-01T00:00:00 +00'
    @conn.storage.set(0, 'key1', 0, 0x7fffffff, Marshal.dump(stored))
    assert_recent_date(json('mapcount_update'))
  end

  def test_update_expt
    json('mapcount_countup', 'subkey1')
    json('mapcount_update', '', Time.now.to_i - 1)
    assert_nil json('mapcount_get')
  end

  def test_update_ms
    assert_nil marshal('mapcount_update_ms')
    json('mapcount_countup', 'subkey0,subkey1')
    assert_equal({ 'subkey0' => 1 }, without_date(marshal('mapcount_update_ms', 'subkey0')))
  end
end
