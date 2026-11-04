require 'yaml'
require 'roma/routing/random_balancer'

module Roma
  module Routing
    class RoutingData
      include Routing::RandomBalancer

      attr_accessor :digest_bits, :divide_bits, :redundancy, :nodes, :routes, :clocks

      # The routing file of a node, such as roma0_3300.route.yml.
      def self.file_name(node_id)
        "#{node_id}.route.yml"
      end

      # The logs of the routing file +fname+ are this and a number, such as
      # roma0_3300.route.1, since they are not YAML.
      def self.log_prefix(fname)
        fname.delete_suffix('.yml')
      end

      def initialize(digest_bits, divide_bits, redundancy)
        @digest_bits = digest_bits
        @divide_bits = divide_bits
        @redundancy = redundancy
        @nodes = []
        @routes = {}
        @clocks = {}
      end

      # The keys of the routing table in YAML, in this order.
      KEYS = %w(digest_bits divide_bits redundancy nodes routes clocks).freeze

      def to_h
        KEYS.to_h { |key| [key, instance_variable_get("@#{key}")] }
      end

      # Raises KeyError if a key is missing.
      def self.from_h(hash)
        routing_data = new(hash.fetch('digest_bits'), hash.fetch('divide_bits'), hash.fetch('redundancy'))
        routing_data.nodes = hash.fetch('nodes')
        routing_data.routes = hash.fetch('routes')
        routing_data.clocks = hash.fetch('clocks')
        routing_data
      end

      # The routing table in YAML, as in the routing file. It has no tag of
      # the Ruby class, so it is read without making any Ruby object.
      def dump_yaml
        YAML.dump(to_h)
      end

      def self.load_yaml(yaml)
        from_h(YAML.safe_load(yaml))
      end

      def save(fname)
        @nodes.sort!
        File.write(fname, dump_yaml)
      end

      def self.load(fname)
        routing_data = load_snapshot(fname)
        routing_data.load_log_all(fname)
        routing_data
      end

      def self.load_snapshot(fname)
        load_yaml(File.read(fname))
      end

      def self.snapshot(fname)
        routing_data = load_snapshot(fname)
        loglist = routing_data.get_file_list(fname)
        return false if loglist.length < 2

        loglist.delete(loglist.last)
        loglist.each do |_i, f|
          routing_data.load_log_one(f)
          File.rename(f, "#{f}~")
        end
        File.rename(fname, "#{fname}~")
        routing_data.save(fname)
        true
      end

      def self.decode_binary(bin)
        magic, ver, digest_bits, divide_bits, redundancy, nodeslen = bin.unpack('a2nCCCn')
        raise 'Illegal format error' if magic != 'RT'
        raise 'Unsupported version error' if ver != 1

        routing_data = RoutingData.new(digest_bits, divide_bits, redundancy)

        bin = bin[9..-1]
        nodeslen.times do |_i|
          len, = bin.unpack('n')
          bin = bin[2..-1]
          node_id, = bin.unpack("a#{len}")
          bin = bin[len..-1]
          node_id.encode!('utf-8') if RUBY_VERSION >= '1.9.3'
          routing_data.nodes << node_id
        end
        (2**divide_bits).times do |i|
          vnode = i << (digest_bits - divide_bits)
          clocks, len = bin.unpack('Nc')
          routing_data.clocks[vnode] = clocks
          bin = bin[5..-1]
          len.times do |_i|
            idx, = bin.unpack('n')
            routing_data.routes[vnode] = [] unless routing_data.routes[vnode]
            routing_data.routes[vnode] << routing_data.nodes[idx]
            bin = bin[2..-1]
          end
        end
        routing_data
      end

      # for deep copy
      def clone
        Marshal.load(Marshal.dump(self))
      end

      # 2 bytes('RT'):magic code
      # unsigned short:format version
      # unsigned char:digest_bits
      # unsigned char:divide_bits
      # unsigned char:redundancy
      # unsigned short:number of nodes
      # while number of nodes
      #  unsigned short:length of node-id string
      #  node-id string
      # while umber of vnodes
      #  unsigned int32:clocks
      #  unsigned char:number of nodes
      #  while umber of nodes
      #   unsigned short:index of nodes
      def dump_binary
        format_version = 1
        # 9 bytes
        ret = ['RT', format_version, digest_bits, divide_bits, redundancy, nodes.length].pack('a2nCCCn')
        rev_hash = {}
        nodes.each_with_index do |node_id, idx|
          rev_hash[node_id] = idx
          # 2 + node_id.length bytes
          ret += [node_id.length, node_id].pack('na*')
        end
        (2**divide_bits).times do |i|
          vnode = i << (digest_bits - divide_bits)
          # 5 bytes
          ret += [clocks[vnode], routes[vnode].length].pack('Nc')
          routes[vnode].each do |node_id|
            # 2 bytes
            ret += [rev_hash[node_id]].pack('n')
          end
        end
        ret
      end

      def each_log_all(fname, &)
        loglist = get_file_list(fname)
        loglist.each do |_i, f|
          each_log_one(f, &)
        end
      end

      def each_log_one(fname)
        File.open(fname, 'r') do |f|
          until (line = f.gets).nil?
            line.chomp!
            next if line[0] == '#' || line.length == 0

            if line =~ /(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})\.\d+\s(.+)/
              yield Time.mktime(::Regexp.last_match(1), ::Regexp.last_match(2), ::Regexp.last_match(3),
                                ::Regexp.last_match(4), ::Regexp.last_match(5), ::Regexp.last_match(6)), ::Regexp.last_match(7)
            end
          end
        end
      end

      def load_log_all(fname)
        each_log_all(fname) do |t, line|
          parse_log(t, line)
        end
        @nodes.sort!
      end

      def load_log_one(fname)
        each_log_one(fname) do |t, line|
          parse_log(t, line)
        end
        @nodes.sort!
      end

      def parse_log(_t, line)
        s = line.split(' ')
        case s[0]
        when 'setroute'
          # setroute <vnode-id> <clock> <node-id> ...
          node_ids = []
          s[3..-1].each { |node_id| node_ids << node_id }
          @routes[s[1].to_i] = node_ids
          @clocks[s[1].to_i] = s[2].to_i
        when 'join'
          # join <node-id>
          @nodes << s[1] unless @nodes.include?(s[1])
        when 'leave'
          # leave <node-id>
          @nodes.delete(s[1])
        else
          raise "RoutingData.parse_log:parse error #{line}"
        end
      end

      def search_mask
        ((2**@divide_bits) - 1) << (@digest_bits - @divide_bits)
      end

      def next_vnode(vnode)
        n = (vnode >> (@digest_bits - @divide_bits)) + 1
        n = 0 if n == (2**@divide_bits)
        n << (@digest_bits - @divide_bits)
      end

      def create_nodes_from_routes
        buf_nodes = {}
        routes.each_value do |node_ids|
          node_ids.each { |node_id| buf_nodes[node_id] = node_id }
        end
        @nodes = buf_nodes.values.sort
      end

      # Returns the losted vnode-id list.
      def get_lost_vnodes
        ret = []
        routes.each_pair do |vnode, node_ids|
          ret << vnode if node_ids.length == 0
        end
        ret
      end

      def self.create(digest_bits, divide_bits, redundancy, nodes, replication_in_host = false)
        ret = RoutingData.new(digest_bits, divide_bits, redundancy)
        ret.nodes = nodes.clone

        node_list_maker = RandomNodeListMaker.new(nodes, replication_in_host)

        (2**divide_bits).times do |i|
          vnode = i << (digest_bits - divide_bits)
          ret.clocks[vnode] = 0
          ret.routes[vnode] = node_list_maker.list(redundancy)
        end

        # vnode balanceing process
        rlist = ret.get_balanced_vnode_replacement_list(replication_in_host)
        ret.balance!(rlist, replication_in_host) if rlist

        ret
      end

      # Returns the log file list by old ordered.
      # +fname+:: The routing file.(ex.roma0_3300.route.yml)
      # One of the following example:
      #   [[1, "roma0_3300.route.1"], [2, "roma0_3300.route.2"]]
      def get_file_list(fname)
        prefix = RoutingData.log_prefix(fname)
        l = {}
        files = Dir.glob("#{prefix}.*")
        files.each do |file|
          l[::Regexp.last_match(1).to_i] = ::Regexp.last_match(0) if /\A#{Regexp.escape(prefix)}\.(\d+)\z/ =~ file
        end
        # sorted by old order
        l.to_a.sort { |a, b| a[0] <=> b[0] }
      end

      def get_histogram
        ret = {}
        nodes.each do |node_id|
          ret[node_id] = Array.new(redundancy, 0)
        end
        routes.each_pair do |_vnode, node_ids|
          node_ids.each_with_index do |node_id, i|
            ret[node_id][i] += 1
          end
        end
        ret
      end

      class RandomNodeListMaker
        def initialize(nodes, replication_in_host)
          @replication_in_host = replication_in_host
          @nodes = nodes
          @host_idx = {}
          nodes.each do |node_id|
            h, _p = node_id.split('_')
            if @host_idx.key?(h)
              @host_idx[h] << node_id
            else
              @host_idx[h] = [node_id]
            end
          end
        end

        # Returns the random node-list without repetition.
        # +n+:: list length
        def list(n)
          ret = []
          hosts = []
          proc_other_one = :get_other_one
          proc_other_one = :get_other_one_repethost if @replication_in_host
          n.times do
            node_id = send(proc_other_one, hosts, ret)
            break unless node_id

            hosts << node_id.split('_')[0]
            ret << node_id
          end
          ret
        end

        # +exp_hosts+:: ignore
        # +exp_nodes+:: exceptional nodes(ex.['roma0_11211'])
        def get_other_one_repethost(_exp_hosts, exp_nodes)
          buf = @nodes.clone
          buf.delete_if { |node_id| exp_nodes.include?(node_id) }
          buf[rand(buf.length)]
        end

        # +exp_hosts+:: exceptional hosts(ex.['roma0','roma1'])
        # +exp_nodes+:: ignore
        def get_other_one(exp_hosts, _exp_nodes)
          hidx = @host_idx.clone
          exp_hosts.each { |h| hidx.delete(h) }
          return nil if hidx.length == 0

          rh = hidx.keys[rand(hidx.keys.length)]
          nodes = hidx[rh]
          nodes[rand(nodes.length)]
        end
      end # class RandomNodeListMaker
    end # class RoutingData
  end # module Routing
end # module Roma
