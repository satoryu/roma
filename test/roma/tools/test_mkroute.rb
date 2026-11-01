require 'test_helper'
require 'stringio'
require 'tool_test_helper'
require 'roma/routing/routing_data'
require 'roma/tools/mkroute'

class MkrouteTest < Test::Unit::TestCase
  include ToolTestHelper

  def mkroute(nodes, **opts)
    out = StringIO.new
    Roma::Tools::Mkroute.new(out: out, dir: @dir).create(nodes, **opts)
    out.string
  end

  def load_route(nid)
    Roma::Routing::RoutingData.load_snapshot(File.join(@dir, "#{nid}.route"))
  end

  def test_create
    out = mkroute(%w(host1:11211 host2_11211), divide_bits: 3)
    assert_equal "nodes => [\"host1_11211\", \"host2_11211\"]\nRouting table has created.\n", out
    %w(host1_11211 host2_11211).each do |nid|
      routing_data = load_route(nid)
      assert_equal %w(host1_11211 host2_11211), routing_data.nodes
      assert_equal [32, 3, 2], [routing_data.digest_bits, routing_data.divide_bits, routing_data.redundancy]
      assert_equal 8, routing_data.routes.size
    end
  end

  def test_options
    mkroute(%w(host1_1 host2_1 host3_1), hash_bits: 16, divide_bits: 4, redundancy: 3)
    routing_data = load_route('host1_1')
    assert_equal [16, 4, 3], [routing_data.digest_bits, routing_data.divide_bits, routing_data.redundancy]
  end

  def test_replication_in_host
    mkroute(%w(host1_1 host1_2), divide_bits: 3, replication_in_host: true)
    load_route('host1_1').routes.each_value { |nids| assert_equal 2, nids.size }
  end

  # Without replication_in_host, a host doesn't hold the same data twice.
  def test_without_replication_in_host
    mkroute(%w(host1_1 host1_2 host2_1), divide_bits: 3)
    load_route('host1_1').routes.each_value do |nids|
      assert_equal nids.size, nids.map { |nid| nid.split('_').first }.uniq.size
    end
  end

  data('hash bits less than divide bits' => [{ hash_bits: 8, divide_bits: 9 }, 'The hash bits should be divide bits or more.'],
       'divide bits over 32' => [{ hash_bits: 40, divide_bits: 33 }, 'The upper bound of divide bits is 32.'],
       'fewer nodes than redundancy' => [{ redundancy: 3 }, 'The node-id number should be redundant number or more.'])
  def test_invalid_arguments(data)
    opts, message = data
    error = assert_raise(Roma::Tools::Error) { mkroute(%w(host1_1 host2_1), **opts) }
    assert_equal message, error.message
    assert_equal [], Dir.children(@dir)
  end
end
