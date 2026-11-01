module Roma
  module Routing
    module RandomBalancer

      # The randomly selected +from+'s vertual-node changes to +to+.
      # +idx+:: As for 0 is primary, 1 or more are secondary.
      def randomly_change_nid!(idx, from, to, repethost = false)
        vns = []
        routes.each_pair do |vn, nids|
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
          vns << vn if cnt == nids.length
        end
        return nil if vns.length == 0
        vn = vns[rand(vns.length)]
        #puts "#{vn} #{routes[vn]}"
        routes[vn][idx] = to
        #puts "#{vn} #{routes[vn]}"
        vn
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
            vn = routing_data.randomly_change_nid!(idx, max_nid, min_nid, repethost)
            return nil unless vn # error
            ret << {:vn=>vn, :idx=>idx, :from=>max_nid, :to=>min_nid}
          end
        end
        ret
      end
      
      def balance!(vn_replacement_list, repethost = false)
        vn_replacement_list.each do |rep|
          routes[rep[:vn]][rep[:idx]] = rep[:to]
        end
      end

    end # module RandomBalancer
  end
end
