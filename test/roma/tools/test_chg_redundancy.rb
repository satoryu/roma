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
    rd = Roma::Routing::RoutingData.create(32, 3, redundancy, [node.nid, 'localhost_1', 'localhost_0'], true)
    rd.v_clk.each_key { |vn| rd.v_clk[vn] = 5 }
    serve_routing(node, rd)
    [node, rd]
  end

  def test_lower
    node, rd = serve(2)
    assert_equal [2], rd.v_idx.values.map(&:size).uniq
    changed = change(node.nid.sub('_', ':'), 1)
    assert_equal 1, changed.rn
    assert_equal rd.v_idx.transform_values { |nids| nids.first(1) }, changed.v_idx
    # The clocks start over.
    assert_equal [0], changed.v_clk.values.uniq
    assert_equal rd.nodes.sort, changed.nodes
  end

  # The nodes are added by romad later.
  def test_higher
    node, rd = serve(1)
    changed = change(node.nid, 3)
    assert_equal 3, changed.rn
    assert_equal rd.v_idx, changed.v_idx
  end

  data('zero' => 0, 'negative' => -1)
  def test_redundancy_less_than_one(redundancy)
    assert_raise_message('The redundancy should be 1 or more.') { change('localhost_1', redundancy) }
  end
end
