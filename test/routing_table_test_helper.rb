
require 'roma/routing/churnbased_routing_table'

# Helpers of the unit tests for the routing tables and the vnode selection
# used by join, recover, release and balance. They build small routing data
# by hand, so no romad is started.
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
