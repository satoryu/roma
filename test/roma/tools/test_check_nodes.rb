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
    assert_true check(*nodes.map(&:nid))
    assert_equal "#{nodes.map(&:nid).join(' ')} => a b (2 nodes)\n", @out.string
  end

  def test_split
    nodes = [answering('a b'), answering('c'), answering('a b')]
    assert_false check(*nodes.map(&:nid))
    assert_equal "#{nodes[0].nid} #{nodes[2].nid} => a b (2 nodes)\n#{nodes[1].nid} => c (1 nodes)\n", @out.string
  end

  def test_node_down
    node = answering('a')
    down = down_node
    assert_false check(node.nid, down)
    assert_match(/\Aerror: #{down}: .*\n#{node.nid} => a \(1 nodes\)\n\z/, @out.string)
  end
end
