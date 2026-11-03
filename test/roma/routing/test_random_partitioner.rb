require 'test_helper'
require 'tmpdir'
require 'routing_table_test_helper'
require 'roma/routing/churnbased_routing_table'

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

  def make_rt(routes, **opts)
    @rt = Roma::Routing::ChurnbasedRoutingTable.new(make_routing_data(routes, **opts), File.join(@dir, 'test.route.yml'))
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
    assert_always_selects([VN[1], [A1]]) { @rt.select_vnode_for_join([A2], true) }
  end

  def test_select_vn_for_join_prefers_vnodes_of_other_hosts
    make_rt([[A1, B1], [B1, A3], [A1, A3], [B1, A1]])
    # vnodes 0, 1 and 3 hold B1 itself, which is excluded.
    vnode, node_ids, = @rt.select_vnode_for_join([B1], true)
    assert_equal [VN[2], [A1, A3]], [vnode, node_ids]

    # A2 is on hosta, so vnodes with no hosta node come first.
    make_rt([[A1, B1], [B1, C1], [A1, A3], [A3, B1]])
    vnode, node_ids, = @rt.select_vnode_for_join([A2], true)
    assert_equal [VN[1], [B1, C1]], [vnode, node_ids]
  end

  def test_select_vn_for_join_takes_primary_from_own_host
    make_rt([[A1, B1], [A1, B1], [A1, B1], [A1, B1]])
    # Every vnode has a primary on hosta, the joining node's host.
    _, _, is_primary = @rt.select_vnode_for_join([A2], false)
    assert_true is_primary
  end

  def test_select_vn_for_join_without_candidates
    make_rt([[A1, B1], [B1, A1], [A1, B1], [B1, A1]])
    assert_nil @rt.select_vnode_for_join([A1, B1], true)
  end

  def test_select_vn_for_recover
    # Only vnode 1 is short; vnode 0 is full and doesn't hold A1.
    make_rt([[A2, B1], [B1], [A1, B1], [B1, A1]])
    assert_always_selects([VN[1], [B1]]) { @rt.select_vnode_for_recover([A1], true) }
    assert_nil @rt.select_vnode_for_recover([B1], true)
  end

  def test_select_node_for_release
    make_rt([[A1, B1], [B1, A1], [A1, B1], [B1, A1]], nodes: [A1, A2, B1])
    to_node_id, new_node_ids = @rt.select_node_for_release(A1, true, [A1, B1])
    assert_equal A2, to_node_id
    assert_equal [A2, B1], new_node_ids
  end

  def test_select_node_for_release_avoids_hosts_of_other_replicas
    make_rt([[A1, B1], [B1, A1], [A1, B1], [B1, A1]], nodes: [A1, A2, B1, 'hostb_11212'])
    # hostb already has a replica, so only A2 can take over.
    to_node_id, new_node_ids = @rt.select_node_for_release(A1, false, [A1, B1])
    assert_equal A2, to_node_id
    assert_equal [A2, B1], new_node_ids
  end

  def test_select_vn_for_balance
    # Short vnodes come first: vnode 1 over the full vnodes 2 and 3.
    make_rt([[A1, B1], [B1], [A2, B1], [B1, A2]])
    assert_always_selects([VN[1], [B1]]) { @rt.select_vnode_for_balance([A1], true) }
    assert_nil @rt.select_vnode_for_balance([B1], true)
  end
end
