require 'test_helper'
require 'routing_table_test_helper'

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
