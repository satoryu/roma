#
# File: distance.rb
#
require 'jaro_winkler'

module Roma
  module Event
    module Distance
      def self.check_distance(cmd, event_list)
        jaro_winkler_distance = 0.0000 # initialize
        similar_cmd = ''
        event_list.each_key do |ev|
          distance = JaroWinkler.distance(cmd, ev)
          if distance > jaro_winkler_distance
            jaro_winkler_distance = distance
            similar_cmd = ev
          end
        end
        [(1 - jaro_winkler_distance), similar_cmd]
      end
    end # module Distance
  end # module Event
end # module Roma
