require 'roma/tools/admin_client'
require 'roma/tools/error'

module Roma
  module Tools
    # Makes a routing table with another redundancy from the one of a node,
    # and writes it in YAML, the format of the routing files.
    class RedundancyChanger
      # +out+ is where the routing table goes.
      def initialize(out: $stdout, client: AdminClient.new)
        @out = out
        @client = client
      end

      # Raises Error if +redundancy+ is less than 1, or the routing table of
      # +node_id+ can't be got. A lower redundancy drops the last nodes of
      # each virtual node. The clocks start over.
      def change(node_id, redundancy)
        raise Error, 'The redundancy should be 1 or more.' if redundancy < 1

        routing_data = @client.routing_data(node_id)
        routing_data.clocks.each_key { |vnode| routing_data.clocks[vnode] = 0 }
        routing_data.routes.each_key do |vnode|
          routing_data.routes[vnode] = routing_data.routes[vnode].first(redundancy)
        end
        routing_data.redundancy = redundancy
        routing_data.nodes.sort!
        @out.puts routing_data.dump_yaml
      end
    end
  end
end
