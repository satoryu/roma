require 'roma/routing/routing_data'
require 'roma/tools/error'

module Roma
  module Tools
    # Makes the routing table and writes it into <node-id>.route for each node.
    class Mkroute
      # +out+ is where messages go, and +dir+ is where the files are written.
      def initialize(out: $stdout, dir: '.')
        @out = out
        @dir = dir
      end

      # +hash_bits+ is the digest bit count, +divide_bits+ the dividing bit
      # count, and +redundancy+ the number of nodes that hold each data.
      # +replication_in_host+ permits a host to hold the same data twice.
      # Raises Error if they don't go together.
      def create(nodes, hash_bits: 32, divide_bits: 9, redundancy: 2, replication_in_host: false)
        nodes = nodes.map { |n| n.sub(':', '_') }
        if hash_bits < divide_bits
          raise Error, "The hash bits should be divide bits or more."
        elsif divide_bits > 32
          raise Error, "The upper bound of divide bits is 32."
        elsif nodes.length < redundancy
          raise Error, "The node-id number should be redundant number or more."
        end

        rt = Roma::Routing::RoutingData.create(hash_bits, divide_bits, redundancy, nodes, replication_in_host)
        nodes.each { |nid| rt.save(File.join(@dir, "#{nid}.route")) }
        @out.puts "nodes => #{nodes}"
        @out.puts "Routing table has created."
      end
    end
  end
end
