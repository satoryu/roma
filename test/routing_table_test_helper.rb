require 'roma/routing/churnbased_routing_table'

# Helpers of the unit tests for the routing tables and the vnode selection
# used by join, recover, release and balance. They build small routing data
# by hand, so no server is started.
module RoutingTableTestHelper
  A1 = 'hosta_11211'
  A2 = 'hosta_11212'
  B1 = 'hostb_11211'

  # 4 vnodes with 32-bit digests.
  DIVIDE_BITS = 2
  VN = (0...2**DIVIDE_BITS).map { |i| i << (32 - DIVIDE_BITS) }

  # Routing data where vnode i is stored on routes[i] (primary first).
  def make_routing_data(routes, redundancy: 2, nodes: nil)
    routing_data = Roma::Routing::RoutingData.new(32, DIVIDE_BITS, redundancy)
    routing_data.nodes = nodes || routes.flatten.uniq
    routes.each_with_index do |node_ids, i|
      routing_data.routes[VN[i]] = node_ids
      routing_data.clocks[VN[i]] = 0
    end
    routing_data
  end
end
