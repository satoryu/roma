require 'test_helper'
require 'stringio'
require 'tool_test_helper'
require 'roma/routing/routing_data'
require 'roma/tools/chg_redundancy'

class ChgRedundancyTest < Test::Unit::TestCase
  include ToolTestHelper

  def change(node_id, redundancy)
    out = StringIO.new
    Roma::Tools::ChgRedundancy.new(out: out).change(node_id, redundancy)
    YAML.unsafe_load(out.string)
  end

  def serve(redundancy)
    node = fake_node
    routing_data = Roma::Routing::RoutingData.create(32, 3, redundancy, [node.nid, 'localhost_1', 'localhost_0'], true)
    routing_data.clocks.each_key { |vnode| routing_data.clocks[vnode] = 5 }
    serve_routing(node, routing_data)
    [node, routing_data]
  end

  def test_lower
    node, routing_data = serve(2)
    assert_equal [2], routing_data.routes.values.map(&:size).uniq
    changed = change(node.nid.sub('_', ':'), 1)
    assert_equal 1, changed.redundancy
    assert_equal routing_data.routes.transform_values { |nids| nids.first(1) }, changed.routes
    # The clocks start over.
    assert_equal [0], changed.clocks.values.uniq
    assert_equal routing_data.nodes.sort, changed.nodes
  end

  # The nodes are added by romad later.
  def test_higher
    node, routing_data = serve(1)
    changed = change(node.nid, 3)
    assert_equal 3, changed.redundancy
    assert_equal routing_data.routes, changed.routes
  end

  data('zero' => 0, 'negative' => -1)
  def test_redundancy_less_than_one(redundancy)
    assert_raise_message('The redundancy should be 1 or more.') { change('localhost_1', redundancy) }
  end
end
