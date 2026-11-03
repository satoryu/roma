require 'test_helper'
require 'stringio'
require 'tool_test_helper'
require 'roma/routing/routing_data'
require 'roma/tools/route_creator'

class RouteCreatorTest < Test::Unit::TestCase
  include ToolTestHelper

  def create_route(nodes, **opts)
    out = StringIO.new
    Roma::Tools::RouteCreator.new(out: out, dir: @dir).create(nodes, **opts)
    out.string
  end

  def load_route(node_id)
    Roma::Routing::RoutingData.load_snapshot(File.join(@dir, "#{node_id}.route.yml"))
  end

  def test_create
    out = create_route(%w(host1:11211 host2_11211), divide_bits: 3)
    assert_equal "nodes => [\"host1_11211\", \"host2_11211\"]\nRouting table has created.\n", out
    %w(host1_11211 host2_11211).each do |node_id|
      routing_data = load_route(node_id)
      assert_equal %w(host1_11211 host2_11211), routing_data.nodes
      assert_equal [32, 3, 2], [routing_data.digest_bits, routing_data.divide_bits, routing_data.redundancy]
      assert_equal 8, routing_data.routes.size
    end
  end

  def test_options
    create_route(%w(host1_1 host2_1 host3_1), digest_bits: 16, divide_bits: 4, redundancy: 3)
    routing_data = load_route('host1_1')
    assert_equal [16, 4, 3], [routing_data.digest_bits, routing_data.divide_bits, routing_data.redundancy]
  end

  def test_replication_in_host
    create_route(%w(host1_1 host1_2), divide_bits: 3, replication_in_host: true)
    load_route('host1_1').routes.each_value { |node_ids| assert_equal 2, node_ids.size }
  end

  # Without replication_in_host, a host doesn't hold the same data twice.
  def test_without_replication_in_host
    create_route(%w(host1_1 host1_2 host2_1), divide_bits: 3)
    load_route('host1_1').routes.each_value do |node_ids|
      assert_equal node_ids.size, node_ids.map { |node_id| node_id.split('_').first }.uniq.size
    end
  end

  data('digest bits less than divide bits' => [{ digest_bits: 8, divide_bits: 9 }, 'The digest bits should be divide bits or more.'],
       'divide bits over 32' => [{ digest_bits: 40, divide_bits: 33 }, 'The upper bound of divide bits is 32.'],
       'fewer nodes than redundancy' => [{ redundancy: 3 }, 'The number of the node IDs should be the redundancy or more.'])
  def test_invalid_arguments(data)
    opts, message = data
    error = assert_raise(Roma::Tools::Error) { create_route(%w(host1_1 host2_1), **opts) }
    assert_equal message, error.message
    assert_equal [], Dir.children(@dir)
  end
end
