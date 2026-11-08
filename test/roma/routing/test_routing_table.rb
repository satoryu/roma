require 'test_helper'
require 'routing_table_test_helper'

class RoutingTableTest < Test::Unit::TestCase
  include RoutingTableTestHelper

  def setup
    @rt = Roma::Routing::RoutingTable.new(make_routing_data([[A1, B1], [B1, A1], [A1, B1], [B1]]))
  end

  def test_vnode_id
    assert_equal VN[0], @rt.vnode_id(0)
    assert_equal VN[0], @rt.vnode_id(VN[1] - 1)
    assert_equal VN[1], @rt.vnode_id(VN[1])
    assert_equal VN[3], @rt.vnode_id((2**32) - 1)
  end

  KEYS = ['', 'a', 'key:0:1', "key\eroma", 'キー', 'k' * 1000].freeze

  # The clients compute the digest so, and must find the same vnode.
  def test_digest
    KEYS.each do |key|
      assert_equal Digest::SHA1.hexdigest(key).hex % (2**32), @rt.digest(key), key
    end
  end

  data('16 bits' => 16, '33 bits' => 33, '64 bits' => 64)
  def test_digest_of_other_hash_spaces(bits)
    rt = Roma::Routing::RoutingTable.new(Roma::Routing::RoutingData.create(bits, 9, 2, [A1, B1]))
    KEYS.each do |key|
      assert_equal Digest::SHA1.hexdigest(key).hex % (2**bits), rt.digest(key), key
    end
  end

  def test_digest_in_threads_and_fibers
    expected = KEYS.map { |key| @rt.digest(key) }
    digests = Array.new(4) { Thread.new { KEYS.map { |key| Fiber.new { @rt.digest(key) }.resume } } }.map(&:value)
    assert_equal [expected] * 4, digests
  end

  def test_search_nodes_returns_a_copy
    nodes = @rt.search_nodes(VN[0])
    assert_equal [A1, B1], nodes
    nodes << A2
    assert_equal [A1, B1], @rt.search_nodes(VN[0])
    assert_nil @rt.search_nodes(12_345)
  end

  def test_num_of_vn
    # [primary, [secondary], short, lost]
    assert_equal [2, [1], 1, 0], @rt.count_vnodes(A1)
    assert_equal [2, [2], 1, 0], @rt.count_vnodes(B1)
  end

  def test_stat
    stat = @rt.stat(A1)
    assert_equal 2, stat['routing.primary']
    assert_equal 1, stat['routing.secondary1']
    assert_equal 1, stat['routing.short_vnodes']
    assert_equal 0, stat['routing.lost_vnodes']
    assert_equal 4, stat['routing.vnodes.length']
  end

  def test_leave
    @rt.leave(B1)
    assert_equal [A1], @rt.nodes
    assert_equal([[A1], [A1], [A1], []], VN.map { |vnode| @rt.search_nodes(vnode) })
    # [primary, [secondary], short, lost]
    assert_equal [3, [0], 3, 1], @rt.count_vnodes(A1)
  end

  def test_proc_failed_leaves_at_threshold
    @rt.failure_count_threshold = 3
    2.times { @rt.proc_failed(B1) }
    assert_include @rt.nodes, B1
    @rt.proc_failed(B1)
    assert_not_include @rt.nodes, B1
  end

  def test_proc_succeed_resets_failures
    @rt.failure_count_threshold = 2
    @rt.proc_failed(B1)
    @rt.proc_succeed(B1)
    @rt.proc_failed(B1)
    assert_include @rt.nodes, B1
  end

  def test_proc_failed_ignores_failures_within_gap
    @rt.failure_count_threshold = 2
    @rt.failure_count_gap = 60
    3.times { @rt.proc_failed(B1) }
    assert_equal 0, @rt.failure_counts[B1]
    assert_include @rt.nodes, B1
  end

  def test_check_repetition_in_routing
    assert_false @rt.check_repetition_in_routing
    rt = Roma::Routing::RoutingTable.new(make_routing_data([[A1, A2], [A1, B1], [B1, A1], [B1, A2]]))
    assert_true rt.check_repetition_in_routing
  end

  def test_sub_nid_rd
    @rt.node_id_substitutions = { '192.168.1.0/24' => { regexp: 'host', replace: 'vm' } }
    assert_nil @rt.substituted_routing_data('10.0.0.1')

    routing_data = @rt.substituted_routing_data('192.168.1.10')
    assert_equal %w(vma_11211 vmb_11211), routing_data.nodes
    assert_equal %w(vma_11211 vmb_11211), routing_data.routes[VN[0]]
    # The table itself is not changed.
    assert_equal [A1, B1], @rt.nodes
  end

  def test_sub_nid_rd_with_illegal_address
    @rt.node_id_substitutions = { '192.168.1.0/24' => { regexp: 'host', replace: 'vm' } }
    assert_nil @rt.substituted_routing_data('localhost')
  end
end
