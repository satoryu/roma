require 'roma/cli/common'

module Roma
  module Subcommands
    # roma route: make and change the routing tables.
    class Route < Thor
      extend Common
      check_unknown_options!

      desc 'create NODE_ID...', 'Make the routing table and write it into NODE_ID.route for each node'
      option :digest_bits, type: :numeric, default: 32, banner: 'BITS', desc: 'Digest bit count'
      option :divide_bits, aliases: '-d', type: :numeric, default: 9, banner: 'BITS',
                           desc: 'Dividing bit count, which makes 2^BITS virtual nodes'
      option :redundancy, aliases: '-r', type: :numeric, default: 2, banner: 'NUM',
                          desc: 'Number of nodes that hold each data'
      option :replication_in_host, type: :boolean, default: false, desc: 'Permit a host to hold the same data twice'
      def create(node_id, *node_ids)
        require 'roma/tools/mkroute'
        Roma::Tools::Mkroute.new.create([node_id, *node_ids],
                                        hash_bits: options[:digest_bits], divide_bits: options[:divide_bits],
                                        redundancy: options[:redundancy],
                                        replication_in_host: options[:replication_in_host])
      end

      desc 'snapshot NODE_ID', 'Put the routing logs of a node, but the last one, into NODE_ID.route'
      def snapshot(node_id)
        require 'roma/tools/ssroute'
        Roma::Tools::Ssroute.new.snapshot(node_id)
      end

      desc 'change-redundancy NUM NODE_ID',
           'Write the routing table of a node in YAML, with NUM nodes to hold each data'
      def change_redundancy(num, node_id)
        require 'roma/tools/chg_redundancy'
        Roma::Tools::ChgRedundancy.new.change(node_id, Integer(num, exception: false) || 0)
      end
    end
  end
end
