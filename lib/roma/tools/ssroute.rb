require 'roma/routing/routing_data'
require 'roma/tools/error'

module Roma
  module Tools
    # Puts the routing logs of a node, but the last one, into its routing
    # file <node-id>.route. The old files are kept with a trailing ~.
    class Ssroute
      # +out+ is where messages go, and +dir+ is where the files are.
      def initialize(out: $stdout, dir: '.')
        @out = out
        @dir = dir
      end

      # Raises Error if there is nothing to put in, or the files can't be read.
      def snapshot(node_id)
        fname = File.join(@dir, "#{node_id.sub(':', '_')}.route")
        begin
          done = Roma::Routing::RoutingData.snapshot(fname)
        rescue => e
          raise Error, "error:#{e}"
        end
        raise Error, "Routing-log file does not found." unless done
        @out.puts "succeed"
      end
    end
  end
end
