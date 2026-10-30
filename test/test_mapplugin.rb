require 'test_helper'
require 'roma/plugin/plugin_map'

# End-to-end tests for the map plugin: they go through romad, including
# forwarding to the node that owns the key (MapPluginTestForceForward).
# Each command's behavior is covered by test_mapplugin_command.rb.
module MapPluginTests
  include RomaTestUtils

  def setup
    start_roma
    @rc=RomaTestClient.new(["localhost_11211","localhost_11212"])
  end

  def teardown
    stop_roma
    Roma::Messaging::ConPool::instance.close_all
  end

  def mk_data(n = 10)
    n.times do |i|
      v = "value#{i}"
      k = "mapkey#{i}"
      assert_equal 'STORED', @rc.map_set('key1', k, v)
      assert_equal v, @rc.map_get('key1', k)
    end    
  end

  def test_map_set
    assert_nil @rc.map_get('key1','mapkey1')
    assert_equal 'STORED', @rc.map_set('key1','mapkey1','value1')
    assert_equal 'value1', @rc.map_get('key1','mapkey1')

    assert_equal 'STORED', @rc.map_set('key1','mapkey1','value2')
    assert_equal 'value2', @rc.map_get('key1','mapkey1')
  end

  def test_map_delete
    mk_data
    assert_equal 'NOT_FOUND', @rc.map_delete('key2', 'key1')
    assert_equal 'NOT_DELETED', @rc.map_delete('key1', 'key1')
    assert_equal 'DELETED', @rc.map_delete('key1', 'mapkey1')
    assert_nil @rc.map_get('key1', 'mapkey1')
  end

  def test_map_clear
    assert_equal 'NOT_FOUND', @rc.map_empty?('key1')
    assert_equal 'NOT_FOUND', @rc.map_size('key1')
    assert_equal 'NOT_FOUND', @rc.map_clear('key1')
    mk_data
    assert !@rc.map_empty?('key1')
    assert_equal 10, @rc.map_size('key1')
    assert_equal 'CLEARED', @rc.map_clear('key1')
    assert @rc.map_empty?('key1')
    assert_equal 0, @rc.map_size('key1')
  end

  def test_map_value?
    assert_equal 'NOT_FOUND', @rc.map_value?('key1', 'value1')
    mk_data
    assert !@rc.map_value?('key1', 'key1')
    assert @rc.map_value?('key1', 'value1')
  end
  
  def test_map_keys
    assert_nil @rc.map_keys('key1')
    mk_data
    v = [10]
    10.times{|i| v << "mapkey#{i}" }
    assert_equal v, @rc.map_keys('key1')
  end

end # MapPluginTests

class MapPluginTest < Test::Unit::TestCase
  self.test_order = :defined
  include MapPluginTests
end

class MapPluginTestForceForward < Test::Unit::TestCase
  self.test_order = :defined
  include MapPluginTests

  def setup
    super
    @rc.rttable.force_forward = true
  end  
end

