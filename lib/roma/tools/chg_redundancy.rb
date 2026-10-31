require 'yaml'
require 'roma/tools/admin_client'
require 'roma/tools/error'

module Roma
  module Tools
    # Makes a routing table with another redundancy from the one of a node,
    # and writes it in YAML, the format of the routing files.
    class ChgRedundancy
      # +out+ is where the routing table goes.
      def initialize(out: $stdout, client: AdminClient.new)
        @out = out
        @client = client
      end

      # Raises Error if +redundancy+ is less than 1, or the routing table of
      # +node_id+ can't be got. A lower redundancy drops the last nodes of
      # each virtual node. The clocks start over.
      def change(node_id, redundancy)
        raise Error, "The redundancy should be 1 or more." if redundancy < 1
        rd = @client.routing_data(node_id)
        rd.v_clk.each_key { |vn| rd.v_clk[vn] = 0 }
        rd.v_idx.each_key { |vn| rd.v_idx[vn] = rd.v_idx[vn].first(redundancy) }
        rd.rn = redundancy
        rd.nodes.sort!
        @out.puts YAML.dump(rd)
      end
    end
  end
end
