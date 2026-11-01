require 'test_helper'
require 'tool_test_helper'
require 'roma/routing/routing_data'
require 'roma/tools/multi_commander'

class MultiCommanderTest < Test::Unit::TestCase
  include ToolTestHelper

  def test_send_cmd_all
    nodes = [fake_node, fake_node]
    routing_data = Roma::Routing::RoutingData.create(32, 3, 1, nodes.map(&:node_id))
    serve_routing(nodes[0], routing_data)
    commander = Roma::Tools::MultiCommander.new(nodes[0].node_id.sub('_', ':'))
    assert_equal "ROMA\r\n", commander.send_cmd('whoami')
    assert_equal "ROMA\r\n", commander.send_cmd('whoami', nodes[1].node_id)
    expected = routing_data.nodes.map { |node_id| "****** #{node_id}\r\nROMA\r\n" }.join
    assert_equal expected, commander.send_cmd_all('whoami')
  end

  # The other nodes still get the command.
  def test_node_down
    node = fake_node
    node_id = down_node
    routing_data = Roma::Routing::RoutingData.create(32, 3, 1, [node_id, node.node_id])
    serve_routing(node, routing_data)
    out = Roma::Tools::MultiCommander.new(node.node_id).send_cmd_all('whoami')
    assert_match(/\A\*{6} #{node_id}\r\nERROR: #{node_id}: .*\r\n\*{6} #{node.node_id}\r\nROMA\r\n\z/, out)
  end

  def test_no_routing_data
    node_id = down_node
    assert_raise(Roma::Tools::Error) { Roma::Tools::MultiCommander.new(node_id) }
  end
end
