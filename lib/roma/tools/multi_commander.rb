require 'roma/tools/admin_client'
require 'roma/tools/error'

module Roma
  module Tools
    # Sends a command to every node in the routing table of a node.
    class MultiCommander
      # Raises Error if the routing table of +node_id+ can't be got.
      def initialize(node_id, client: AdminClient.new)
        @client = client
        @rd = @client.routing_data(node_id)
      end

      # Returns the reply of +nid+, the first node by default, with "\r\n"
      # after each line. Raises Error if the node doesn't reply.
      def send_cmd(cmd, nid = @rd.nodes[0])
        @client.command(nid, cmd).map { |line| "#{line}\r\n" }.join
      end

      # Returns the replies of all the nodes, each after its node id. A node
      # that doesn't reply gets the error instead.
      def send_cmd_all(cmd)
        @rd.nodes.map do |nid|
          reply = begin
                    send_cmd(cmd, nid)
                  rescue Error => e
                    "ERROR: #{e.message}\r\n"
                  end
          "****** #{nid}\r\n#{reply}"
        end.join
      end
    end
  end
end
