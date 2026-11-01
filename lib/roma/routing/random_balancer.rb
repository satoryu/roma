module Roma
  module Routing
    module RandomBalancer

      # The randomly selected +from+'s vertual-node changes to +to+.
      # +idx+:: As for 0 is primary, 1 or more are secondary.
      def randomly_change_node_id!(idx, from, to, replication_in_host = false)
        vnodes = []
        routes.each_pair do |vnode, node_ids|
          cnt = 0
          node_ids.each_with_index do |node_id, i|
            if idx == i
              cnt += 1 if node_id == from
            else
              if replication_in_host == true
                cnt += 1 if node_id != to
              else
                cnt += 1 if node_id.split('_')[0] != to.split('_')[0]
              end
            end
          end
          vnodes << vnode if cnt == node_ids.length
        end
        return nil if vnodes.length == 0
        vnode = vnodes[rand(vnodes.length)]
        #puts "#{vnode} #{routes[vnode]}"
        routes[vnode][idx] = to
        #puts "#{vnode} #{routes[vnode]}"
        vnode
      end

      # Returns min/max values and correspondent node-id of the histogram.
      # +idx+:: As for 0 is primary, 1 or more are secondary.
      def get_min_max_histogram(idx)
        h = get_histogram
        min_node_id = max_node_id = nil
        min = routes.length
        max = 0
        h.each do |node_id, v|
          if v[idx] < min
            min = v[idx]
            min_node_id = node_id
          end
          if v[idx] > max
            max = v[idx]
            max_node_id = node_id
          end
        end
        [min, min_node_id, max, max_node_id]
      end
      
      # Returns a replacement list for balanced routing.
      def get_balanced_vn_replacement_list(replication_in_host = false)
        routing_data = clone
        ret = []
        @redundancy.times do |idx| # primary, secondary1, ...
          loop do # until balanced
            min, min_node_id, max, max_node_id = routing_data.get_min_max_histogram(idx)
            break if max - min < 2 || min_node_id == max_node_id
            vnode = routing_data.randomly_change_node_id!(idx, max_node_id, min_node_id, replication_in_host)
            return nil unless vnode # error
            ret << {:vnode=>vnode, :idx=>idx, :from=>max_node_id, :to=>min_node_id}
          end
        end
        ret
      end
      
      def balance!(vnode_replacement_list, replication_in_host = false)
        vnode_replacement_list.each do |rep|
          routes[rep[:vnode]][rep[:idx]] = rep[:to]
        end
      end

    end # module RandomBalancer
  end
end
