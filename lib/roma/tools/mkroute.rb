require 'optparse'
require 'roma/routing/routing_data'

module Roma
  module Tools
    # Makes the routing table and writes it into <node-id>.route for each node.
    class Mkroute
      # +out+ and +err+ are where messages go, and +dir+ is where the files
      # are written.
      def initialize(out: $stdout, err: $stderr, dir: '.')
        @out = out
        @err = err
        @dir = dir
      end

      # Returns the exit status.
      def run(argv)
        # digest bit count
        dgst_bits = 32
        # dividing bit count (dgst_bits >= div_bits)
        div_bits = 9
        # redundancy (nodes.length >= rn)
        rn = 2
        # permit redundant on single host
        repeathost = false

        opts = OptionParser.new
        opts.banner = "usage:#{File.basename($0)} [options] node-id..."
        opts.on("-h", "--hash [bits]", "(default=32)") { |v| dgst_bits = v.to_i }
        opts.on("-d", "--divide [bits]", "(default=9)") { |v| div_bits = v.to_i }
        opts.on("-r", "--redundant [num]", "(default=2)") { |v| rn = v.to_i }
        opts.on(nil, "--enabled_repeathost") do
          repeathost = true
          @out.puts "Warning: \"--enabled_repeathost\" is deprecated. Please use \"--replication_in_host\""
        end
        opts.on(nil, "--replication_in_host") { repeathost = true }
        opts.on_tail("--help") do
          @out.puts opts.help
          return 0
        end

        begin
          nodes = opts.parse(argv)
        rescue OptionParser::ParseError => e
          @err.puts e.message
          @err.puts opts.help
          return 1
        end
        nodes = nodes.map { |n| n.sub(':', '_') }

        error = if nodes.empty?
                  opts.help
                elsif dgst_bits < div_bits
                  "The hash bits should be divide bits or more."
                elsif div_bits > 32
                  "The upper bound of divide bits is 32."
                elsif nodes.length < rn
                  "The node-id number should be redundant number or more."
                end
        if error
          @err.puts error
          return 1
        end

        rt = Roma::Routing::RoutingData.create(dgst_bits, div_bits, rn, nodes, repeathost)
        nodes.each { |nid| rt.save(File.join(@dir, "#{nid}.route")) }
        @out.puts "nodes => #{nodes}"
        @out.puts "Routing table has created."
        0
      end
    end
  end
end
