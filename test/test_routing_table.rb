require 'test_helper'
require 'tmpdir'
require 'roma/routing/cb_rttable'

# Unit tests for the routing tables and the vnode selection used by join,
# recover, release and balance. They build small routing data by hand, so
# no romad is started.
module RoutingTableTestHelper
  A1 = 'hosta_11211'
  A2 = 'hosta_11212'
  B1 = 'hostb_11211'

  # 4 vnodes with 32-bit digests.
  DIV_BITS = 2
  VN = (0...2**DIV_BITS).map { |i| i << (32 - DIV_BITS) }

  # Routing data where vnode i is stored on v_idx[i] (primary first).
  def make_rd(v_idx, rn: 2, nodes: nil)
    rd = Roma::Routing::RoutingData.new(32, DIV_BITS, rn)
    rd.nodes = nodes || v_idx.flatten.uniq
    v_idx.each_with_index do |nids, i|
      rd.v_idx[VN[i]] = nids
      rd.v_clk[VN[i]] = 0
    end
    rd
  end
end

class RoutingTableTest < Test::Unit::TestCase
  include RoutingTableTestHelper

  def setup
    @rt = Roma::Routing::RoutingTable.new(make_rd([[A1, B1], [B1, A1], [A1, B1], [B1]]))
  end

  def test_get_vnode_id
    assert_equal VN[0], @rt.get_vnode_id(0)
    assert_equal VN[0], @rt.get_vnode_id(VN[1] - 1)
    assert_equal VN[1], @rt.get_vnode_id(VN[1])
    assert_equal VN[3], @rt.get_vnode_id(2**32 - 1)
  end

  def test_search_nodes_returns_a_copy
    nodes = @rt.search_nodes(VN[0])
    assert_equal [A1, B1], nodes
    nodes << A2
    assert_equal [A1, B1], @rt.search_nodes(VN[0])
    assert_nil @rt.search_nodes(12345)
  end

  def test_num_of_vn
    # [primary, [secondary], short, lost]
    assert_equal [2, [1], 1, 0], @rt.num_of_vn(A1)
    assert_equal [2, [2], 1, 0], @rt.num_of_vn(B1)
  end

  def test_get_stat
    stat = @rt.get_stat(A1)
    assert_equal 2, stat['routing.primary']
    assert_equal 1, stat['routing.secondary1']
    assert_equal 1, stat['routing.short_vnodes']
    assert_equal 0, stat['routing.lost_vnodes']
    assert_equal 4, stat['routing.vnodes.length']
  end

  def test_leave
    @rt.leave(B1)
    assert_equal [A1], @rt.nodes
    assert_equal [[A1], [A1], [A1], []], VN.map { |vn| @rt.search_nodes(vn) }
    # [primary, [secondary], short, lost]
    assert_equal [3, [0], 3, 1], @rt.num_of_vn(A1)
  end

  def test_proc_failed_leaves_at_threshold
    @rt.fail_cnt_threshold = 3
    2.times { @rt.proc_failed(B1) }
    assert_include @rt.nodes, B1
    @rt.proc_failed(B1)
    assert_not_include @rt.nodes, B1
  end

  def test_proc_succeed_resets_failures
    @rt.fail_cnt_threshold = 2
    @rt.proc_failed(B1)
    @rt.proc_succeed(B1)
    @rt.proc_failed(B1)
    assert_include @rt.nodes, B1
  end

  def test_proc_failed_ignores_failures_within_gap
    @rt.fail_cnt_threshold = 2
    @rt.fail_cnt_gap = 60
    3.times { @rt.proc_failed(B1) }
    assert_equal 0, @rt.fail_cnt[B1]
    assert_include @rt.nodes, B1
  end

  def test_check_repetition_in_routing
    assert_false @rt.check_repetition_in_routing
    rt = Roma::Routing::RoutingTable.new(make_rd([[A1, A2], [A1, B1], [B1, A1], [B1, A2]]))
    assert_true rt.check_repetition_in_routing
  end

  def test_sub_nid_rd
    @rt.sub_nid = { '192.168.1.0/24' => { regexp: 'host', replace: 'vm' } }
    assert_nil @rt.sub_nid_rd('10.0.0.1')

    rd = @rt.sub_nid_rd('192.168.1.10')
    assert_equal %w(vma_11211 vmb_11211), rd.nodes
    assert_equal %w(vma_11211 vmb_11211), rd.v_idx[VN[0]]
    # The table itself is not changed.
    assert_equal [A1, B1], @rt.nodes
  end

  def test_sub_nid_rd_with_illegal_address
    @rt.sub_nid = { '192.168.1.0/24' => { regexp: 'host', replace: 'vm' } }
    assert_nil @rt.sub_nid_rd('localhost')
  end
end

class ChurnbasedRoutingTableTest < Test::Unit::TestCase
  include RoutingTableTestHelper

  def setup
    @dir = Dir.mktmpdir('roma_rttable')
    @fname = File.join(@dir, 'test.route')
  end

  def teardown
    @rt.close_log if @rt
    FileUtils.rm_rf(@dir)
  end

  def make_rt(v_idx, **opts)
    @rt = Roma::Routing::ChurnbasedRoutingTable.new(make_rd(v_idx, **opts), @fname)
  end

  def log_lines
    File.readlines("#{@fname}.1").map { |l| l.split(' ', 2)[1].chomp }
  end

  def test_set_route
    make_rt([[A1, B1], [B1, A1], [A1, B1], [B1, A1]])
    assert_equal 1, @rt.set_route(VN[0], 0, [B1, A2])
    assert_equal [B1, A2], @rt.search_nodes(VN[0])
    assert_include @rt.nodes, A2
    assert_equal ["join #{A2}", "setroute #{VN[0]} 1 #{B1} #{A2}"], log_lines
    assert_match(/ join #{A2}\z/, @rt.event.last)
  end

  def test_set_route_rejects_old_clock_and_unknown_vnode
    make_rt([[A1, B1], [B1, A1], [A1, B1], [B1, A1]])
    @rt.set_route(VN[0], 5, [B1, A1])
    assert_equal "It's old table.", @rt.set_route(VN[0], 0, [A1])
    assert_equal [B1, A1], @rt.search_nodes(VN[0])
    assert_equal '1 is not found.', @rt.set_route(1, 0, [A1])
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
    @rt.set_leave_proc { |nid| left = nid }
    @rt.set_recover_proc { |cmd| recovered = cmd }

    @rt.leave(B1)
    assert_equal B1, left
    assert_equal 'start_auto_recover_process', recovered
    assert_equal [A1], @rt.nodes
    assert_equal [[A1]] * 4, VN.map { |vn| @rt.search_nodes(vn) }
    assert_equal [1] * 4, VN.map { |vn| @rt.search_nodes_with_clk(vn)[0] }
    assert_match(/ leave #{B1}\z/, @rt.event.last)
  end

  def test_leave_with_lost_vnodes
    make_rt([[A1, B1], [B1], [A1, B1], [A1, B1]])
    @rt.enabled_failover = true
    lost = false
    @rt.set_lost_proc { lost = true }

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

  def test_delete_old_trans
    make_rt([[A1, B1], [B1, A1], [A1, B1], [B1, A1]])
    @rt.transaction(VN[0], [A1, A2])
    @rt.delete_old_trans(60)
    assert_true @rt.trans.key?(VN[0])
    @rt.delete_old_trans(-1)
    assert_false @rt.trans.key?(VN[0])
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
    @rt.set_version(A1, 0x010203)
    @rt.set_version(B1, 0x010100)
    assert_equal 0x010100, @rt.min_version
  end
end

class RandomPartitionerTest < Test::Unit::TestCase
  include RoutingTableTestHelper

  A3 = 'hosta_11213'
  C1 = 'hostc_11211'

  def setup
    @dir = Dir.mktmpdir('roma_rttable')
  end

  def teardown
    @rt.close_log if @rt
    FileUtils.rm_rf(@dir)
  end

  def make_rt(v_idx, **opts)
    @rt = Roma::Routing::ChurnbasedRoutingTable.new(make_rd(v_idx, **opts), File.join(@dir, 'test.route'))
  end

  def test_exclude_nodes
    make_rt([[A1, B1], [B1, A2], [A2, B1], [B1, A1]])
    assert_equal [A1], @rt.exclude_nodes(A1, true)
    # Without replication in a host, every node on the same host is excluded.
    assert_equal [A1, A2], @rt.exclude_nodes(A1, false)
    assert_equal [A1], @rt.exclude_nodes_for_join(A1, false)
  end

  # The selection is random among the candidates, so these tests choose
  # many times to see that only the expected vnode is ever chosen.
  def assert_always_selects(expected)
    20.times { assert_equal expected, yield.first(2) }
  end

  def test_select_vn_for_join_prefers_short_vnodes
    # vnode 1 is short; vnodes 2 and 3 are full and on other hosts.
    make_rt([[A1, B1], [A1], [B1, C1], [B1, C1]])
    assert_always_selects([VN[1], [A1]]) { @rt.select_vn_for_join([A2], true) }
  end

  def test_select_vn_for_join_prefers_vnodes_of_other_hosts
    make_rt([[A1, B1], [B1, A3], [A1, A3], [B1, A1]])
    # vnodes 0, 1 and 3 hold B1 itself, which is excluded.
    vn, nids, = @rt.select_vn_for_join([B1], true)
    assert_equal [VN[2], [A1, A3]], [vn, nids]

    # A2 is on hosta, so vnodes with no hosta node come first.
    make_rt([[A1, B1], [B1, C1], [A1, A3], [A3, B1]])
    vn, nids, = @rt.select_vn_for_join([A2], true)
    assert_equal [VN[1], [B1, C1]], [vn, nids]
  end

  def test_select_vn_for_join_takes_primary_from_own_host
    make_rt([[A1, B1], [A1, B1], [A1, B1], [A1, B1]])
    # Every vnode has a primary on hosta, the joining node's host.
    _, _, is_primary = @rt.select_vn_for_join([A2], false)
    assert_true is_primary
  end

  def test_select_vn_for_join_without_candidates
    make_rt([[A1, B1], [B1, A1], [A1, B1], [B1, A1]])
    assert_nil @rt.select_vn_for_join([A1, B1], true)
  end

  def test_select_vn_for_recover
    # Only vnode 1 is short; vnode 0 is full and doesn't hold A1.
    make_rt([[A2, B1], [B1], [A1, B1], [B1, A1]])
    assert_always_selects([VN[1], [B1]]) { @rt.select_vn_for_recover([A1], true) }
    assert_nil @rt.select_vn_for_recover([B1], true)
  end

  def test_select_node_for_release
    make_rt([[A1, B1], [B1, A1], [A1, B1], [B1, A1]], nodes: [A1, A2, B1])
    to_nid, new_nids = @rt.select_node_for_release(A1, true, [A1, B1])
    assert_equal A2, to_nid
    assert_equal [A2, B1], new_nids
  end

  def test_select_node_for_release_avoids_hosts_of_other_replicas
    make_rt([[A1, B1], [B1, A1], [A1, B1], [B1, A1]], nodes: [A1, A2, B1, 'hostb_11212'])
    # hostb already has a replica, so only A2 can take over.
    to_nid, new_nids = @rt.select_node_for_release(A1, false, [A1, B1])
    assert_equal A2, to_nid
    assert_equal [A2, B1], new_nids
  end

  def test_select_vn_for_balance
    # Short vnodes come first: vnode 1 over the full vnodes 2 and 3.
    make_rt([[A1, B1], [B1], [A2, B1], [B1, A2]])
    assert_always_selects([VN[1], [B1]]) { @rt.select_vn_for_balance([A1], true) }
    assert_nil @rt.select_vn_for_balance([B1], true)
  end
end
