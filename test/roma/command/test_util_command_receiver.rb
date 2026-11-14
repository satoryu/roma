require 'test_helper'
require 'stringio'
require 'fake_node'
require 'receiver_command_test_helper'

class UtilCommandReceiverTest < Test::Unit::TestCase
  include ReceiverCommandTestHelper

  def test_chg_time_expt
    assert_equal 0x7fffffff, @conn.send(:chg_time_expt, 0)
    # Less than 30 days is relative.
    assert_in_delta Time.now.to_i + 100, @conn.send(:chg_time_expt, 100), 2
    assert_equal 2_592_000, @conn.send(:chg_time_expt, 2_592_000)
  end

  # The storages keep it in 32 bits, which wrapped around: 2**32 was 0, a
  # delete mark, and a large negative time never expired.
  def test_chg_time_expt_out_of_32_bits
    assert_equal 0xffffffff, @conn.send(:chg_time_expt, 2**32)
    assert_equal 0xffffffff, @conn.send(:chg_time_expt, Time.now.to_i * 1000)
    assert_equal 1, @conn.send(:chg_time_expt, -(2**40))
    assert_operator @conn.send(:chg_time_expt, -1), :<, Time.now.to_i
  end

  def test_async_send_cmd
    node = FakeNode.new
    assert_equal 'ROMA', @conn.send(:async_send_cmd, node.node_id, "whoami\r\n")
    # The node is down.
    assert_nil @conn.send(:async_send_cmd, 'localhost_1', "whoami\r\n")
  ensure
    node&.close
    Roma::Messaging::ConnectionPool.instance.close_all
  end

  # A connection to another node that answers with +reply+.
  class FakeConnection
    attr_reader :closed

    def initialize(reply)
      @reply = StringIO.new(reply)
    end

    def write(_data); end

    def gets = @reply.gets

    def close_connection
      @closed = true
    end
  end

  def stub_connection(reply)
    con = FakeConnection.new(reply)
    checkins = []
    @conn.define_singleton_method(:checkout_connection) { |_node_id| con }
    @conn.define_singleton_method(:checkin_connection) { |node_id, _con| checkins << node_id }
    [con, checkins]
  end

  def test_send_cmd
    con, checkins = stub_connection("ROMA\r\n")
    assert_equal 'ROMA', @conn.send(:send_cmd, OTHER_NODE_ID, "whoami\r\n")
    assert_equal [OTHER_NODE_ID], checkins
    assert_nil con.closed
  end

  # The connection isn't used again after a reply to an unknown command,
  # which may have more lines, as the one that suggests a command does.
  data('error' => "ERROR: 'fset' is not roma command.\r\n",
       'suggestion' => "\r\nERROR: 'fset' is not roma command.\r\nDid you mean this?\r\n\trset\r\n")
  def test_send_cmd_unknown_command(reply)
    con, checkins = stub_connection(reply)
    @conn.send(:send_cmd, OTHER_NODE_ID, "fset key\r\n")
    assert_equal [], checkins
    assert_true con.closed
  end

  def test_async_broadcast_cmd
    node = FakeNode.new
    @conn.routing_table.add_node(node.node_id)
    res = @conn.send(:async_broadcast_cmd, "whoami\r\n", [NODE_ID, OTHER_NODE_ID])
    assert_equal({ node.node_id => 'ROMA' }, res)
  ensure
    node&.close
    Roma::Messaging::ConnectionPool.instance.close_all
  end
end
