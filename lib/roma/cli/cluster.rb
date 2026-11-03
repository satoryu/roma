require 'roma/cli/common'

module Roma
  module Subcommands
    # roma cluster: work with every node of a cluster.
    class Cluster < Thor
      extend Common
      check_unknown_options!

      desc 'command NODE_ID COMMAND...', 'Send a command to every node in the routing table of a node'
      def command(node_id, command, *args)
        require 'roma/tools/cluster_command'
        puts Roma::Tools::ClusterCommand.new(node_id).send_command_to_all([command, *args].join(' '))
      end

      desc 'check NODE_ID...', 'Check that the nodes answer and know the same nodes, or exit with 1'
      def check(node_id, *node_ids)
        require 'roma/tools/check_nodes'
        return if Roma::Tools::CheckNodes.new.check([node_id, *node_ids])

        raise Roma::Tools::Error, "The nodes don't answer the same nodes."
      end
    end
  end
end
