require 'test_helper'
require 'stringio'
require 'tool_test_helper'
require 'roma/tools/check_nodes'

class CheckNodesTest < Test::Unit::TestCase
  include ToolTestHelper

  def answering(nodelist)
    fake_node.tap { |node| node.replies['nodelist'] = "#{nodelist}\r\n" }
  end

  def check(*node_ids)
    @out = StringIO.new
    Roma::Tools::CheckNodes.new(out: @out, client: Roma::Tools::AdminClient.new(timeout: 0.5)).check(node_ids)
  end

  def test_same
    nodes = [answering('a b'), answering('a b')]
    assert_true check(*nodes.map(&:node_id))
    assert_equal "#{nodes.map(&:node_id).join(' ')} => a b (2 nodes)\n", @out.string
  end

  def test_split
    nodes = [answering('a b'), answering('c'), answering('a b')]
    assert_false check(*nodes.map(&:node_id))
    assert_equal "#{nodes[0].node_id} #{nodes[2].node_id} => a b (2 nodes)\n#{nodes[1].node_id} => c (1 nodes)\n",
                 @out.string
  end

  def test_node_down
    node = answering('a')
    down = down_node
    assert_false check(node.node_id, down)
    assert_match(/\Aerror: #{down}: .*\n#{node.node_id} => a \(1 nodes\)\n\z/, @out.string)
  end
end
