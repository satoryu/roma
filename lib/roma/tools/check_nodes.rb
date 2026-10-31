require 'roma/tools/admin_client'
require 'roma/tools/error'

module Roma
  module Tools
    # Asks nodes for the nodes they know, to find a node down or a split
    # brain.
    class CheckNodes
      def initialize(out: $stdout, client: AdminClient.new)
        @out = out
        @client = client
      end

      # Writes the node lists that +node_ids+ answer, with the nodes that
      # answer each, and the errors. Returns true if all of them answer the
      # same list.
      def check(node_ids)
        lists = Hash.new { |h, k| h[k] = [] }
        errors = node_ids.count do |nid|
          lists[@client.request(nid, 'nodelist').split] << nid
          false
        rescue Error => e
          @out.puts "error: #{e.message}"
          true
        end
        lists.each do |nodes, answered|
          @out.puts "#{answered.join(' ')} => #{nodes.join(' ')} (#{nodes.size} nodes)"
        end
        errors.zero? && lists.size == 1
      end
    end
  end
end
