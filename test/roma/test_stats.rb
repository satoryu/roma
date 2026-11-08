require 'test_helper'
require 'roma/stats'

# Unit tests for Roma::Stats.
class StatsTest < Test::Unit::TestCase
  def setup
    @stats = Roma::Stats.send(:new)
  end

  def test_record_latency
    @stats.latency_check_time_count = 60
    [0.3, 0.1, 0.2].each { |latency| @stats.record_latency('get', latency) }
    data = @stats.latency_data['get']
    assert_equal [0.3, 0.1, 0.2], data['latency']
    assert_equal 0.3, data['latency_max']['current']
    assert_equal 0.1, data['latency_min']['current']

    # Keeps the last 10.
    11.times { |i| @stats.record_latency('get', i) }
    assert_equal (1..10).to_a, data['latency']

    # After latency_check_time_count seconds, starts over.
    data['time'] -= 61
    @stats.record_latency('get', 0.5)
    assert_equal [], data['latency']
    assert_equal [2, 3, 4, 5, 6, 7, 8, 9, 10, 0.5], data['latency_past']
    assert_equal 10, data['latency_max']['past']
    assert_equal 0, data['latency_max']['current']
    assert_equal 0, data['latency_min']['past']
    assert_equal 99_999, data['latency_min']['current']
  end

  def test_record_latency_of_each_command
    @stats.record_latency('get', 0.1)
    @stats.record_latency('set', 0.2)
    assert_equal [0.1], @stats.latency_data['get']['latency']
    assert_equal [0.2], @stats.latency_data['set']['latency']
  end
end
