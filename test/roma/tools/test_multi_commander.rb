require 'test_helper'
require 'tool_test_helper'
require 'roma/routing/routing_data'
require 'roma/tools/multi_commander'

class MultiCommanderTest < Test::Unit::TestCase
  include ToolTestHelper

  def test_send_cmd_all
    nodes = [fake_node, fake_node]
    rd = Roma::Routing::RoutingData.create(32, 3, 1, nodes.map(&:nid))
    serve_routing(nodes[0], rd)
    commander = Roma::Tools::MultiCommander.new(nodes[0].nid.sub('_', ':'))
    assert_equal "ROMA\r\n", commander.send_cmd('whoami')
    assert_equal "ROMA\r\n", commander.send_cmd('whoami', nodes[1].nid)
    expected = rd.nodes.map { |nid| "****** #{nid}\r\nROMA\r\n" }.join
    assert_equal expected, commander.send_cmd_all('whoami')
  end

  # The other nodes still get the command.
  def test_node_down
    node = fake_node
    nid = down_node
    rd = Roma::Routing::RoutingData.create(32, 3, 1, [nid, node.nid])
    serve_routing(node, rd)
    out = Roma::Tools::MultiCommander.new(node.nid).send_cmd_all('whoami')
    assert_match(/\A\*{6} #{nid}\r\nERROR: #{nid}: .*\r\n\*{6} #{node.nid}\r\nROMA\r\n\z/, out)
  end

  def test_no_routing_data
    nid = down_node
    assert_raise(Roma::Tools::Error) { Roma::Tools::MultiCommander.new(nid) }
  end
end
