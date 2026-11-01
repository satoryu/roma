module Roma
  module Routing
    module RandomBalancer

      # The randomly selected +from+'s vertual-node changes to +to+.
      # +idx+:: As for 0 is primary, 1 or more are secondary.
      def randomly_change_nid!(idx, from, to, repethost = false)
        vnodes = []
        routes.each_pair do |vnode, nids|
          cnt = 0
          nids.each_with_index do |nid, i|
            if idx == i
              cnt += 1 if nid == from
            else
              if repethost == true
                cnt += 1 if nid != to
              else
                cnt += 1 if nid.split('_')[0] != to.split('_')[0]
              end
            end
          end
          vnodes << vnode if cnt == nids.length
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
        min_nid = max_nid = nil
        min = routes.length
        max = 0
        h.each do |nid, v|
          if v[idx] < min
            min = v[idx]
            min_nid = nid
          end
          if v[idx] > max
            max = v[idx]
            max_nid = nid
          end
        end
        [min, min_nid, max, max_nid]
      end
      
      # Returns a replacement list for balanced routing.
      def get_balanced_vn_replacement_list(repethost = false)
        routing_data = clone
        ret = []
        @redundancy.times do |idx| # primary, secondary1, ...
          loop do # until balanced
            min, min_nid, max, max_nid = routing_data.get_min_max_histogram(idx)
            break if max - min < 2 || min_nid == max_nid
            vnode = routing_data.randomly_change_nid!(idx, max_nid, min_nid, repethost)
            return nil unless vnode # error
            ret << {:vnode=>vnode, :idx=>idx, :from=>max_nid, :to=>min_nid}
          end
        end
        ret
      end
      
      def balance!(vn_replacement_list, repethost = false)
        vn_replacement_list.each do |rep|
          routes[rep[:vnode]][rep[:idx]] = rep[:to]
        end
      end

    end # module RandomBalancer
  end
end
