require 'test_helper'
require 'stringio'
require 'tool_test_helper'
require 'fake_kvs'
require 'roma/tools/bench'

class BenchTest < Test::Unit::TestCase
  include ToolTestHelper
  include FakeKVSHelper

  def setup
    super
    @kvs = fake_kvs
    @out = StringIO.new
  end

  def bench(interval: 10)
    Roma::Tools::Bench.new([@kvs.node_id], out: @out, interval: interval)
  end

  def test_set_and_get
    bench.run(%i(set get), num: 3, threads: 2)
    assert_equal({ 'key_0' => 'value_0', 'key_1' => 'value_1', 'key_2' => 'value_2' }, @kvs.data)
    assert_equal 6, @kvs.commands.grep(/\Aget /).size
    assert_equal "Start thread 0\nStart thread 1\n", @out.string.lines.grep(/Start/).join
    assert_empty @out.string.lines.grep(/failed/)
  end

  def test_value_size
    bench.run(%i(set get), num: 2, value_size: 5)
    assert_equal [5, 5], @kvs.data.values.map(&:size)
    assert_match(/\A[a-z]{5}\z/, @kvs.data['key_0'])
    assert_empty @out.string.lines.grep(/failed/)
  end

  def test_wrong_values
    @kvs.data['key_0'] = 'other'
    bench.run(%i(get), num: 2)
    assert_equal ["get k=0 failed\n", "get k=1 failed\n"], @out.string.lines.grep(/failed/)
  end

  def test_set_failed
    @kvs.replies['set'] = "NOT_STORED\r\n"
    bench.run(%i(set), num: 1)
    assert_include @out.string, "set k=0 failed\n"
  end

  def test_set_error
    @kvs.replies['set'] = "SERVER_ERROR busy\r\n"
    bench.run(%i(set), num: 1)
    assert_include @out.string, "set k=0 set key_0: SERVER_ERROR busy\n"
  end

  def test_stop
    b = bench
    t = Thread.new { b.run(%i(rand), num: 5) }
    sleep 0.1
    b.stop
    assert_not_nil t.join(5)
  end

  def test_node_down
    Roma::Tools::Bench.new([down_node], out: @out).run(%i(get), num: 1)
    assert_match(/^get k=0 localhost_\d+: .*refused/i, @out.string)
  end

  def test_rand
    bench.run(%i(rand), num: 5, duration: 0.2)
    names = @kvs.commands.map { |c| c.split.first }.uniq.sort
    assert_equal %w(delete get set), names
    assert_empty @out.string.lines.grep(/failed/)
  end

  def test_report
    bench(interval: 0.1).run(%i(rand), num: 5, duration: 0.35)
    assert_match(/^qps=\d+ max=\d+\.\d+ min=\d+\.\d+ ave=\d+\.\d+$/, @out.string)
  end

  def test_stats
    stats = Roma::Tools::Bench::Stats.new
    assert_equal 'qps=0 max=0.000000 min=0.000000 ave=0.000000', stats.report(10)
    [0.5, 0.1, 0.3].each { |t| stats.record(t) }
    assert_equal 'qps=1 max=0.500000 min=0.100000 ave=0.666667', stats.report(2)
    # It starts over.
    assert_equal 'qps=0 max=0.000000 min=0.000000 ave=0.000000', stats.report(10)
  end
end
