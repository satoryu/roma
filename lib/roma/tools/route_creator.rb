require 'roma/routing/routing_data'
require 'roma/tools/error'

module Roma
  module Tools
    # Makes the routing table and writes it into <node-id>.route.yml for each node.
    class RouteCreator
      # +out+ is where messages go, and +dir+ is where the files are written.
      def initialize(out: $stdout, dir: '.')
        @out = out
        @dir = dir
      end

      # +digest_bits+ is the digest bit count, +divide_bits+ the dividing bit
      # count, and +redundancy+ the number of nodes that hold each data.
      # +replication_in_host+ permits a host to hold the same data twice.
      # Raises Error if they don't go together.
      def create(nodes, digest_bits: 32, divide_bits: 9, redundancy: 2, replication_in_host: false)
        nodes = nodes.map { |n| n.sub(':', '_') }
        if digest_bits < divide_bits
          raise Error, 'The digest bits should be divide bits or more.'
        elsif divide_bits > 32
          raise Error, 'The upper bound of divide bits is 32.'
        elsif nodes.length < redundancy
          raise Error, 'The number of the node IDs should be the redundancy or more.'
        end

        routing_data = Roma::Routing::RoutingData.create(digest_bits, divide_bits, redundancy, nodes,
                                                         replication_in_host)
        nodes.each { |node_id| routing_data.save(File.join(@dir, Roma::Routing::RoutingData.file_name(node_id))) }
        @out.puts "nodes => #{nodes}"
        @out.puts 'Routing table has created.'
      end
    end
  end
end
