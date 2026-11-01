require 'test_helper'
require 'receiver_command_test_helper'

class BackgroundCommandReceiverTest < Test::Unit::TestCase
  include ReceiverCommandTestHelper

  # Makes this node primary of fewer vnodes than its share.
  def unbalance
    @conn.rttable.each_vnode { |vn, _| @conn.rttable.set_route(vn, @conn.rttable.search_nodes_with_clk(vn)[0], [OTHER_NID, NID]) }
  end

  def test_balance
    unbalance
    @conn.relay_reply = 'STARTED'
    assert_equal replies('STARTED', other: 'STARTED'), @conn.request('balance')
    assert_equal ["rbalance\r\n"], @conn.broadcasts
    assert_equal ['start_balance_process'], queued_events
  end

  def test_balance_when_balanced
    @conn.relay_reply = 'SERVER_ERROR'
    assert_equal replies('SERVER_ERROR Not unbalance or othre process is already running.', other: 'SERVER_ERROR'),
                 @conn.request('balance')
    assert_equal [], queued_events
  end

  def test_rbalance
    assert_equal "SERVER_ERROR Not unbalance or other process is already running.\r\n", @conn.request('rbalance')
    unbalance
    assert_equal "STARTED\r\n", @conn.request('rbalance')
    @conn.stats.run_join = true
    assert_equal "SERVER_ERROR Not unbalance or other process is already running.\r\n", @conn.request('rbalance')
    assert_equal ['start_balance_process'], queued_events
  end

  def test_release
    assert_equal "STARTED\r\n", @conn.request('release')
    @conn.stats.run_release = true
    assert_equal "SERVER_ERROR Other process is already running.\r\n", @conn.request('release')
    assert_equal ['start_release_process'], queued_events
  end

  def test_recover
    @conn.relay_reply = 'STARTED'
    assert_equal replies('STARTED', other: 'STARTED'), @conn.request('recover')
    assert_equal ["rrecover\r\n"], @conn.broadcasts
    @conn.stats.run_recover = true
    assert_equal replies('SERVER_ERROR Recover process is already running.', other: 'STARTED'), @conn.request('recover')
    assert_equal ['start_recover_process'], queued_events
  end

  def test_rrecover
    assert_equal "STARTED\r\n", @conn.request('rrecover')
    @conn.stats.run_recover = true
    assert_equal "SERVER_ERROR Recover process is already running.\r\n", @conn.request('rrecover')
    assert_equal ['start_recover_process'], queued_events
  end

  # With fewer nodes than the redundancy, the vnodes can't be recovered.
  data('recover' => 'recover', 'rrecover' => 'rrecover')
  def test_recover_without_enough_nodes(command)
    @conn.rttable.instance_variable_get(:@rd).nodes.delete(OTHER_NID)
    assert_equal "SERVER_ERROR nodes num < redundant num\r\n", @conn.request(command)
  end
end
