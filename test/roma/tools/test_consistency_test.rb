require 'test_helper'
require 'stringio'
require 'tool_test_helper'
require 'fake_kvs'
require 'roma/tools/consistency_test'

class ConsistencyTestTest < Test::Unit::TestCase
  include ToolTestHelper
  include FakeKVSHelper

  def setup
    super
    @kvs = fake_kvs
    @out = StringIO.new
  end

  def consistency(**opts)
    Roma::Tools::ConsistencyTest.new([@kvs.nid], out: @out).run(**opts)
  end

  def test_rounds
    assert_equal 0, consistency(keys: 3, rounds: 2)
    assert_equal({ 'key_0' => '2', 'key_1' => '2', 'key_2' => '2' }, @kvs.data)
    assert_equal '', @out.string
  end

  def test_hundred_rounds
    consistency(keys: 1, rounds: 100)
    assert_equal "100 loop has finished.\n", @out.string
  end

  # The values are kept by the node, but not stored.
  def test_errors
    @kvs.replies['set'] = "NOT_STORED\r\n"
    assert_equal 2, consistency(keys: 2, rounds: 1)
    assert_match(/^set k=key_0 NOT_STORED$/, @out.string)
    assert_match(/^error k=key_1 nil$/, @out.string)
  end

  def test_node_down
    assert_equal 1, Roma::Tools::ConsistencyTest.new([down_node], out: @out).run(keys: 1, rounds: 1)
    assert_match(/^set k=key_0 localhost_\d+: /, @out.string)
    assert_match(/^error k=key_0 localhost_\d+: /, @out.string)
  end
end
