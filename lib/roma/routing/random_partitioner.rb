module Roma
  module Routing
    module RandomPartitioner
      def exclude_nodes(my_node_id, replication_in_host)
        exclude_nodes = nodes
        if replication_in_host
          exclude_nodes = [my_node_id]
        else
          myhost = my_node_id.split(/[:_]/)[0]
          exclude_nodes.delete_if { |node_id| node_id.split(/[:_]/)[0] != myhost }
        end
        exclude_nodes
      end

      def exclude_nodes_for_join(my_node_id, _rep_host)
        [my_node_id]
      end

      alias exclude_nodes_for_recover exclude_nodes
      alias exclude_nodes_for_balance exclude_nodes

      def myhost_include?(nodes, myhost)
        nodes.each do |node_id|
          return true if node_id.split(/[:_]/)[0] == myhost
        end
        false
      end
      private :myhost_include?

      # vnode sampling exclude +exclude_nodes+
      def select_vnode_for_join(exclude_nodes, replication_in_host)
        short_idx = {}
        myhost_idx = {}
        idx = {}
        myhost = exclude_nodes[0].split(/[:_]/)[0]

        @routing_data.routes.each_pair do |vnode, node_ids|
          next if list_include?(node_ids, exclude_nodes)

          if myhost_include?(node_ids, myhost)
            myhost_idx[vnode] = node_ids
          else
            idx[vnode] = node_ids # other hosts
          end
          short_idx[vnode] = node_ids if node_ids.length < @routing_data.redundancy
        end

        # vnodes sampling priority:
        # 1. Short vnodes
        # 2. Other hosts vnodes
        # 3. My host vnodes
        if short_idx.length > 0
          idx = short_idx
        elsif idx.length == 0
          idx = myhost_idx
        end

        return nil if idx.length == 0

        ks = idx.keys
        vnode = ks[rand(ks.length)]
        node_ids = idx[vnode]

        is_primary = if !replication_in_host && node_ids[0].split(/[:_]/)[0] == myhost
                       true
                     else
                       rand(@routing_data.redundancy) == 0
                     end

        [vnode, node_ids, is_primary]
      end

      # select a vnodes where short of redundancy.
      def select_vnode_for_recover(exclude_nodes, _rep_host)
        ret = []
        @routing_data.routes.each_pair do |vnode, node_ids|
          if node_ids.length < @routing_data.redundancy && list_include?(node_ids, exclude_nodes) == false
            ret << [vnode, node_ids]
          end
        end
        if ret.length == 0
          nil
        else
          n = rand(ret.length)
          [ret[n][0], ret[n][1], (rand(@routing_data.redundancy) == 0)]
        end
      end

      def select_node_for_release(my_node_id, replication_in_host, node_ids)
        buf = nodes

        if replication_in_host
          node_ids.each { |node_id| buf.delete(node_id) }
        else
          deny_hosts = []
          node_ids.each do |node_id|
            host = node_id.split(/[:_]/)[0]
            deny_hosts << host if host != my_node_id.split(/[:_]/)[0]
          end
          buf.delete_if { |node_id| deny_hosts.include?(node_id.split(/[:_]/)[0]) }
        end

        buf.delete_if { |instance| instance == my_node_id }
        to_node_id = buf.sample
        new_node_ids = node_ids.map { |n| n == my_node_id ? to_node_id : n }
        [to_node_id, new_node_ids]
      end

      # vnode sampling exclude +exclude_nodes+
      def select_vnode_for_balance(exclude_nodes, _rep_host)
        short_idx = {}
        idx = {}
        @routing_data.routes.each_pair do |vnode, node_ids|
          unless list_include?(node_ids, exclude_nodes)
            idx[vnode] = node_ids
            short_idx[vnode] = node_ids if node_ids.length < @routing_data.redundancy
          end
        end
        idx = short_idx if short_idx.length > 0

        ks = idx.keys
        return nil if ks.length == 0

        vnode = ks[rand(ks.length)]
        node_ids = idx[vnode]
        [vnode, node_ids, rand(@routing_data.redundancy) == 0]
      end
    end
  end
end
