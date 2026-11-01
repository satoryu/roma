require 'test_helper'
require 'fake_node'
require 'receiver_command_test_helper'

class UtilCommandReceiverTest < Test::Unit::TestCase
  include ReceiverCommandTestHelper

  def test_chg_time_expt
    assert_equal 0x7fffffff, @conn.chg_time_expt(0)
    # Less than 30 days is relative.
    assert_in_delta Time.now.to_i + 100, @conn.chg_time_expt(100), 2
    assert_equal 2_592_000, @conn.chg_time_expt(2_592_000)
  end

  def test_async_send_cmd
    node = FakeNode.new
    assert_equal 'ROMA', @conn.async_send_cmd(node.node_id, "whoami\r\n")
    # The node is down.
    assert_nil @conn.async_send_cmd('localhost_1', "whoami\r\n")
  ensure
    node&.close
    Roma::Messaging::ConPool.instance.close_all
  end

  def test_async_broadcast_cmd
    node = FakeNode.new
    @conn.routing_table.add_node(node.node_id)
    res = @conn.async_broadcast_cmd("whoami\r\n", [NODE_ID, OTHER_NODE_ID])
    assert_equal({ node.node_id => 'ROMA' }, res)
  ensure
    node&.close
    Roma::Messaging::ConPool.instance.close_all
  end
end
