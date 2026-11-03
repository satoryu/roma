require 'test_helper'
require 'stringio'
require 'tool_test_helper'
require 'roma/routing/routing_data'
require 'roma/tools/route_snapshot'

class RouteSnapshotTest < Test::Unit::TestCase
  include ToolTestHelper

  def setup
    super
    @fname = File.join(@dir, 'host1_1.route')
    Roma::Routing::RoutingData.create(32, 3, 1, ['host1_1']).save(@fname)
  end

  def write_log(n, line)
    File.write("#{@fname}.#{n}", "2026-01-01T00:00:00.1 #{line}\n")
  end

  def snapshot(node_id)
    out = StringIO.new
    Roma::Tools::RouteSnapshot.new(out: out, dir: @dir).snapshot(node_id)
    out.string
  end

  def test_snapshot
    write_log(1, 'join host2_1')
    write_log(2, 'join host3_1')
    assert_equal "succeed\n", snapshot('host1:1')
    assert_equal %w(host1_1 host2_1), Roma::Routing::RoutingData.load_snapshot(@fname).nodes
    assert_equal %w(host1_1.route host1_1.route.1~ host1_1.route.2 host1_1.route~), Dir.children(@dir).sort
  end

  # The last log is still being written.
  def test_without_enough_logs
    write_log(1, 'join host2_1')
    error = assert_raise(Roma::Tools::Error) { snapshot('host1_1') }
    assert_equal 'Routing-log file does not found.', error.message
  end

  data('missing route' => ['host2_1', /\Aerror:No such file or directory/],
       'broken log' => ['host1_1', /\Aerror:.*parse error/])
  def test_error(data)
    node_id, message = data
    write_log(1, 'unknown host2_1')
    write_log(2, 'join host3_1')
    assert_raise_message(message) { snapshot(node_id) }
  end
end
