require 'test_helper'
require 'tmpdir'
require 'routing_table_test_helper'
require 'roma/routing/churnbased_routing_table'

class ChurnbasedRoutingTableTest < Test::Unit::TestCase
  include RoutingTableTestHelper

  def setup
    @dir = Dir.mktmpdir('roma_rttable')
    @fname = File.join(@dir, 'test.route.yml')
  end

  def teardown
    @rt.close_log if @rt
    FileUtils.rm_rf(@dir)
  end

  def make_rt(routes, **)
    @rt = Roma::Routing::ChurnbasedRoutingTable.new(make_routing_data(routes, **), @fname)
  end

  def log_lines
    File.readlines(File.join(@dir, 'test.route.1')).map { |l| l.split(' ', 2)[1].chomp }
  end

  def test_set_route
    make_rt([[A1, B1], [B1, A1], [A1, B1], [B1, A1]])
    assert_equal 1, @rt.update_route(VN[0], 0, [B1, A2])
    assert_equal [B1, A2], @rt.search_nodes(VN[0])
    assert_include @rt.nodes, A2
    assert_equal ["join #{A2}", "setroute #{VN[0]} 1 #{B1} #{A2}"], log_lines
    assert_match(/ join #{A2}\z/, @rt.event.last)
  end

  def test_set_route_rejects_old_clock_and_unknown_vnode
    make_rt([[A1, B1], [B1, A1], [A1, B1], [B1, A1]])
    @rt.update_route(VN[0], 5, [B1, A1])
    assert_equal "It's old table.", @rt.update_route(VN[0], 0, [A1])
    assert_equal [B1, A1], @rt.search_nodes(VN[0])
    assert_equal '1 is not found.', @rt.update_route(1, 0, [A1])
  end

  def test_leave_does_nothing_unless_failover_is_enabled
    make_rt([[A1, B1], [B1, A1], [A1, B1], [B1, A1]])
    @rt.leave(B1)
    assert_include @rt.nodes, B1
  end

  def test_leave_starts_recovery_for_short_vnodes
    make_rt([[A1, B1], [B1, A1], [A1, B1], [B1, A1]])
    @rt.enabled_failover = true
    left = recovered = nil
    @rt.on_leave { |node_id| left = node_id }
    @rt.on_recover { |cmd| recovered = cmd }

    @rt.leave(B1)
    assert_equal B1, left
    assert_equal 'start_auto_recover_process', recovered
    assert_equal [A1], @rt.nodes
    assert_equal([[A1]] * 4, VN.map { |vnode| @rt.search_nodes(vnode) })
    assert_equal([1] * 4, VN.map { |vnode| @rt.search_nodes_with_clk(vnode)[0] })
    assert_match(/ leave #{B1}\z/, @rt.event.last)
  end

  def test_leave_with_lost_vnodes
    make_rt([[A1, B1], [B1], [A1, B1], [A1, B1]])
    @rt.enabled_failover = true
    lost = false
    @rt.on_lost { lost = true }

    @rt.leave(B1)
    assert_true lost
    assert_equal [], @rt.search_nodes(VN[1])
    assert_equal [VN[1]], @rt.search_lost_vnodes(Time.now - 60)
    assert_equal [], @rt.search_lost_vnodes(Time.now + 60)
  end

  def test_leave_with_lost_vnodes_and_auto_assign
    make_rt([[A1, B1], [B1], [A1, B1], [A1, B1]])
    @rt.enabled_failover = true
    @rt.lost_action = :auto_assign

    @rt.leave(B1)
    # The lost vnode takes the nodes of the next vnode.
    assert_equal [A1], @rt.search_nodes(VN[1])
  end

  def test_transaction
    make_rt([[A1, B1], [B1, A1], [A1, B1], [B1, A1]])
    assert_true @rt.transaction(VN[0], [A1, B1, A2])
    assert_false @rt.transaction(VN[0], [A1])
    # Writes go to the new nodes while the routing has not changed.
    assert_equal [A1, B1, A2], @rt.search_nodes_for_write(VN[0])
    assert_equal [A1, B1], @rt.search_nodes(VN[0])

    assert_equal 1, @rt.commit(VN[0])
    assert_equal [A1, B1, A2], @rt.search_nodes(VN[0])
    assert_false @rt.commit(VN[0])
  end

  def test_rollback
    make_rt([[A1, B1], [B1, A1], [A1, B1], [B1, A1]])
    @rt.transaction(VN[0], [A1, A2])
    @rt.rollback(VN[0])
    assert_equal [A1, B1], @rt.search_nodes_for_write(VN[0])
    assert_false @rt.commit(VN[0])
  end

  def test_delete_old_transactions
    make_rt([[A1, B1], [B1, A1], [A1, B1], [B1, A1]])
    @rt.transaction(VN[0], [A1, A2])
    @rt.delete_old_transactions(60)
    assert_true @rt.transactions.key?(VN[0])
    @rt.delete_old_transactions(-1)
    assert_false @rt.transactions.key?(VN[0])
  end

  def test_vnode_balance
    make_rt([[A1, B1], [A1, B1], [A1, B1], [B1, A1]])
    assert_equal :over, @rt.vnode_balance(A1)
    assert_equal :less, @rt.vnode_balance(B1)
    make_rt([[A1, B1], [B1, A1], [A1, B1], [B1, A1]])
    assert_equal :even, @rt.vnode_balance(A1)
  end

  def test_can_i_recover?
    make_rt([[A1, B1], [B1, A1], [A1, B1], [B1, A1]])
    assert_true @rt.can_i_recover?
    make_rt([[A1], [A1], [A1], [A1]])
    assert_false @rt.can_i_recover?
  end

  # Despite its name, it returns true when the node can NOT be released:
  # the rest of the cluster has fewer nodes (or hosts) than the redundancy.
  def test_can_i_release?
    make_rt([[A1, B1], [B1, A2], [A2, B1], [B1, A1]])
    # Without A1, A2 and B1 remain, on two hosts.
    assert_false @rt.can_i_release?(A1, true)
    assert_false @rt.can_i_release?(A1, false)
    # Without B1, A1 and A2 remain, but on one host.
    assert_false @rt.can_i_release?(B1, true)
    assert_true @rt.can_i_release?(B1, false)
  end

  def test_has_node?
    make_rt([[A1, B1], [B1, A1], [A1, B1], [B1, A1]], nodes: [A1, A2, B1])
    assert_true @rt.has_node?(A1)
    assert_false @rt.has_node?(A2)
  end

  def test_set_version
    make_rt([[A1, B1], [B1, A1], [A1, B1], [B1, A1]])
    @rt.update_version(A1, 0x010203)
    @rt.update_version(B1, 0x010100)
    assert_equal 0x010100, @rt.min_version
  end
end
