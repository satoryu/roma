require 'test_helper'

require 'roma/routing/routing_data'
require 'yaml'

if ENV['OPTIONAL']
  class MkrouteRichTest < Test::Unit::TestCase
    self.test_order = :defined
    def setup
    end

    def teardown
    end

    def test_make_rich_routing
      # digest bit count 32
      # vnode bit count 16
      # redundancy 2
      # array of node ID ['roma0_3300','roma1_3300','roma2_3300']
      routing_data=Roma::Routing::RoutingData.create(32,16,2,['roma0_3300','roma1_3300','roma2_3300']) # vnode bit count 16

      assert( routing_data.routes.length==65536 )
      assert( routing_data.nodes.length==3 )
      assert( routing_data.search_mask==0xffff0000 )
      assert( routing_data.digest_bits==32 )
      assert( routing_data.divide_bits==16 )
      assert( routing_data.redundancy==2 )

      c0=c1=c2=0
      routing_data.routes.each_value{|v|
        case v[0]
        when 'roma0_3300'
          c0+=1
        when 'roma1_3300'
          c1+=1
        when 'roma2_3300'
          c2+=1
        end
      }
      # confirming dispersion is lower than 10%
      assert( (c0-c1).abs < routing_data.routes.length/10 )
      assert( (c1-c2).abs < routing_data.routes.length/10 )
    end

  end
end
