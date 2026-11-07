require 'roma/logging/rlogger'
require 'roma/routing/routing_data'
require 'roma/routing/merkle_tree'
require 'json'

module Roma
  module Routing
    class RoutingTable
      attr_reader :routing_data, :search_mask, :failure_counts, :merkle_tree, :hash_space_size, :redundancy,
                  :divide_bits
      attr_accessor :failure_count_threshold, :failure_count_gap, :node_id_substitutions

      def initialize(routing_data)
        @log = Roma::Logging::RLogger.instance
        @routing_data = routing_data
        @redundancy = @routing_data.redundancy
        @divide_bits = @routing_data.divide_bits
        @hash_space_size = 2**@routing_data.digest_bits
        @search_mask = @routing_data.search_mask
        @failure_counts = Hash.new(0)
        @failure_count_threshold = 5
        @failure_count_gap = 0
        @fail_time = Time.now
        @node_id_substitutions = {}
        init_merkle_tree
      end

      def count_vnodes(ap)
        pn = short = lost = 0
        sn = Array.new(@routing_data.redundancy - 1, 0)
        @routing_data.routes.each_pair do |_vnode, node_ids|
          if node_ids.nil? || node_ids.length == 0
            lost += 1
            next
          elsif node_ids[0] == ap
            pn += 1
          elsif node_ids.include?(ap)
            i = node_ids.index(ap) - 1
            sn[i] += 1
          end
          short += 1 if node_ids.length < @routing_data.redundancy
        end
        [pn, sn, short, lost]
      end

      def get_stat(ap)
        pn, sn, short, lost = count_vnodes(ap)
        ret = {}
        ret['routing.redundant'] = @redundancy
        ret['routing.nodes.length'] = nodes.length
        ret['routing.nodes'] = nodes.inspect
        ret['routing.digest_bits'] = @routing_data.digest_bits
        ret['routing.divide_bits'] = @divide_bits
        ret['routing.vnodes.length'] = vnodes.length
        ret['routing.primary'] = pn
        (@redundancy - 1).times { |i| ret["routing.secondary#{i + 1}"] = sn[i] }
        ret['routing.short_vnodes'] = short
        ret['routing.lost_vnodes'] = lost
        ret['routing.failure_count_threshold'] = @failure_count_threshold
        ret['routing.failure_count_gap'] = @failure_count_gap
        ret['routing.node_id_substitutions'] = @node_id_substitutions.inspect
        ret
      end

      def init_merkle_tree
        @merkle_tree = MerkleTree.new(@routing_data.digest_bits, @routing_data.divide_bits)
        @routing_data.routes.each_pair do |vnode, node_ids|
          @merkle_tree.set(vnode, node_ids)
        end
      end

      def nodes
        @routing_data.nodes.clone
      end

      def vnodes
        @routing_data.routes.keys
      end

      # get vnode id from hash value
      def vnode_id(d)
        d & @search_mask
      end

      # get array of node ID which have vnode
      # +vnode+: vnode id
      def search_nodes(vnode)
        @routing_data.routes[vnode].clone
      rescue StandardError
        nil
      end

      # delete dropping node from list
      # +node_id+: dropping node
      def leave(node_id)
        @routing_data.nodes.delete(node_id)
        # delet node_id from list
        @routing_data.routes.each_pair do |vnode, node_ids|
          node_ids.delete_if { |other_node_id| other_node_id == node_id }
          @log.error("Vnode data is lost.(Vnode=#{vnode})") if node_ids.length == 0
          @merkle_tree.set(vnode, node_ids)
        end
        @failure_counts.delete(node_id)
      end

      def dump
        Marshal.dump(@routing_data)
      end

      def dump_yaml
        @routing_data.dump_yaml
      end

      def dump_json
        JSON.generate(
          [{ digest_bits: @routing_data.digest_bits, divide_bits: @routing_data.divide_bits, redundancy: @routing_data.redundancy },
           @routing_data.nodes, @routing_data.routes]
        )
      end

      def dump_binary
        @routing_data.dump_binary
      end

      def check_repetition_in_routing
        @routing_data.routes.each_value do |value|
          host = []
          value.each do |instance|
            host << instance.split('_')[0]
          end
          return true if host.uniq!
        end

        false
      end

      def proc_failed(node_id)
        t = Time.now
        if t - @fail_time > @failure_count_gap
          @failure_counts[node_id] += 1
          leave(node_id) if @failure_counts[node_id] >= @failure_count_threshold
        end
        @fail_time = t
      end

      def proc_succeed(node_id)
        @failure_counts.delete(node_id)
      end

      # Reconstruct vnodes from routes
      def create_nodes_from_routes
        @routing_data.create_nodes_from_routes
      end

      # Returns a new RoutingData object which replaced host name by the node_id_substitutions attribute.
      def substituted_routing_data(addr)
        node_id_substitutions.each do |mask, sub|
          return replaced_routing_data(sub[:regexp], sub[:replace]) if check_netmask?(addr, mask)
        end
        nil
      end

      private

      def replaced_routing_data(regexp, replace)
        routing_data = Marshal.load(dump)

        routing_data.nodes.map! do |node_id|
          node_id.sub(regexp, replace)
        end

        routing_data.routes.each_value do |node_ids|
          node_ids.map! do |node_id|
            node_id.sub(regexp, replace)
          end
        end
        routing_data
      end

      def check_netmask?(addr, mask)
        if addr =~ /(\d+)\.(\d+)\.(\d+)\.(\d+)/
          iaddr = (::Regexp.last_match(1).to_i << 24) + (::Regexp.last_match(2).to_i << 16) + (::Regexp.last_match(3).to_i << 8) + ::Regexp.last_match(4).to_i
        else
          @log.error("#{__method__}:Illigal format addr #{addr}")
          return false
        end

        if mask =~ %r{(\d+)\.(\d+)\.(\d+)\.(\d+)/(\d+)}
          imask_addr = (::Regexp.last_match(1).to_i << 24) + (::Regexp.last_match(2).to_i << 16) + (::Regexp.last_match(3).to_i << 8) + ::Regexp.last_match(4).to_i
          imask = ((2**::Regexp.last_match(5).to_i) - 1) << (32 - ::Regexp.last_match(5).to_i)
        else
          @log.error("#{__method__}:Illigal format mask #{mask}")
          return false
        end
        (iaddr & imask) == (imask_addr & imask)
      end
    end # class RoutingTable
  end # module Routing
end # module Roma
