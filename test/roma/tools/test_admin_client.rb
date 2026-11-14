require 'test_helper'
require 'tool_test_helper'
require 'roma/routing/routing_data'
require 'roma/tools/admin_client'

class AdminClientTest < Test::Unit::TestCase
  include ToolTestHelper

  def client
    Roma::Tools::AdminClient.new(timeout: 0.5)
  end

  def test_routing_data
    node = fake_node
    routing_data = Roma::Routing::RoutingData.create(32, 3, 1, [node.node_id])
    serve_routing(node, routing_data)
    assert_equal routing_data.routes, client.routing_data(node.node_id).routes
  end

  data('no routing data' => ["0\r\n", /has no routing data/],
       'closed' => [:close, /has no routing data/],
       'stops sending' => ["10\r\nabc", /execution expired/],
       'not binary' => ["3\r\nabc\r\nEND\r\n", /sent broken routing data/],
       'no reply' => [proc { '' }, /execution expired/])
  def test_routing_data_errors(data)
    reply, message = data
    node = fake_node
    node.replies['routingdump'] = reply
    assert_raise_message(message) { client.routing_data(node.node_id) }
  end

  def test_routing_data_cut
    server = TCPServer.new(0)
    thread = Thread.new do
      s = server.accept
      s.gets
      s.write("10\r\nabc")
      s.close
    end
    node_id = "localhost_#{server.addr[1]}"
    assert_raise_message("#{node_id} closed the connection.") { client.routing_data(node_id) }
  ensure
    thread.join
    server.close
  end

  # The reply ends when no line comes for a while.
  def test_command
    node = fake_node
    node.replies['stats'] = "a 1\r\nb 2\r\nEND\r\n"
    assert_equal ['a 1', 'b 2', 'END'], client.command(node.node_id, 'stats')
    assert_equal ['stats'], node.commands
  end

  def test_command_without_reply
    node = fake_node
    node.replies['stats'] = proc { '' }
    assert_raise_message("#{node.node_id} didn't reply to stats.") { client.command(node.node_id, 'stats') }
  end

  def test_request
    node = fake_node
    node.replies['stats'] = "a 1\r\nb 2\r\nEND\r\n"
    assert_equal 'a 1', client.request(node.node_id, 'stats')
  end

  data('closed' => [:close, /closed the connection/],
       'no reply' => [proc { '' }, /execution expired/])
  def test_request_errors(data)
    reply, message = data
    node = fake_node
    node.replies['stats'] = reply
    assert_raise_message(message) { client.request(node.node_id, 'stats') }
  end

  def test_node_down
    node_id = down_node
    error = assert_raise(Roma::Tools::Error) { client.command(node_id, 'whoami') }
    assert_match(/\A#{node_id}: .*refused/i, error.message)
  end
end
