require 'yaml'
require 'roma/routing/random_balancer'

module Roma
  module Routing

    class RoutingData

      include Routing::RandomBalancer

      attr_accessor :digest_bits
      attr_accessor :divide_bits
      attr_accessor :redundancy
      attr_accessor :nodes
      attr_accessor :routes
      attr_accessor :clocks

      def initialize(digest_bits,divide_bits,redundancy)
        @digest_bits=digest_bits
        @divide_bits=divide_bits
        @redundancy=redundancy
        @nodes=[]
        @routes={}
        @clocks={}
      end

      def save(fname)
        @nodes.sort!
        open(fname,'wb'){|io|
          io.write(YAML.dump(self))
        }
      end

      def self.load(fname)
        routing_data=load_snapshot(fname)
        routing_data.load_log_all(fname)
        routing_data
      end

      def self.load_snapshot(fname)
        routing_data=nil
        open(fname,'rb'){|io|
          routing_data = YAML.unsafe_load(io.read)
        }
        routing_data
      end

      def self.snapshot(fname)
        routing_data=load_snapshot(fname)
        loglist=routing_data.get_file_list(fname)
        if loglist.length<2
          return false
        end
        loglist.delete(loglist.last)
        loglist.each{|i,f|
          routing_data.load_log_one(f)
          File.rename(f,"#{f}~")
        }
        File.rename(fname,"#{fname}~")
        routing_data.save(fname)
        true
      end

      def self.decode_binary(bin)
        magic, ver, digest_bits, divide_bits, redundancy, nodeslen = bin.unpack('a2nCCCn')
        raise 'Illegal format error' if magic != 'RT'
        raise 'Unsupported version error' if ver != 1

        routing_data = RoutingData.new(digest_bits, divide_bits, redundancy)
        
        bin = bin[9..-1]
        nodeslen.times{|i|
          len, = bin.unpack('n')
          bin = bin[2..-1]
          nid, = bin.unpack("a#{len}")
          bin = bin[len..-1]
          nid.encode!("utf-8") if RUBY_VERSION >= "1.9.3"
          routing_data.nodes << nid 
        }
        (2**divide_bits).times{|i|
          vn=i<<(digest_bits-divide_bits)
          clocks,len = bin.unpack('Nc')
          routing_data.clocks[vn] = clocks
          bin = bin[5..-1]
          len.times{|i|
            idx, = bin.unpack('n')
            routing_data.routes[vn] = [] unless routing_data.routes[vn]
            routing_data.routes[vn] << routing_data.nodes[idx]
            bin = bin[2..-1]
          }
        }
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
        ret = ['RT',format_version,digest_bits,divide_bits,redundancy,nodes.length].pack('a2nCCCn')
        rev_hash = {}
        nodes.each_with_index{|nid,idx|
          rev_hash[nid] = idx
          # 2 + nid.length bytes
          ret += [nid.length,nid].pack('na*')
        }
        (2**divide_bits).times{|i|
          vn=i<<(digest_bits-divide_bits)
          # 5 bytes
          ret += [clocks[vn],routes[vn].length].pack('Nc')
          routes[vn].each{|nid|
            # 2 bytes
            ret += [rev_hash[nid]].pack('n')
          }
        }
        ret
      end

      def each_log_all(fname)
        loglist=get_file_list(fname)
        loglist.each{|i,f|
          each_log_one(f){|t,l| yield t,l}
        }
      end

      def each_log_one(fname)
        File.open(fname,"r"){|f|
          while((line=f.gets)!=nil)
            line.chomp!
            next if line[0]=="#" || line.length==0
            if line =~ /(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})\.\d+\s(.+)/
              yield Time.mktime($1, $2, $3, $4, $5, $6), $7 
            end
          end
        }
      end

      def load_log_all(fname)
        each_log_all(fname){|t,line|
          parse_log(t,line)
        }
        @nodes.sort!
      end

      def load_log_one(fname)
        each_log_one(fname){|t,line|
          parse_log(t,line)
        }
        @nodes.sort!
      end

      def parse_log(t,line)
        s=line.split(' ')
        case s[0]
        when 'setroute'
          # setroute <vnode-id> <clock> <node-id> ...
          nids=[]
          s[3..-1].each{ |nid| nids << nid }
          @routes[s[1].to_i]=nids
          @clocks[s[1].to_i]=s[2].to_i
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
        2**@divide_bits-1<<(@digest_bits-@divide_bits)
      end

      def next_vnode(vn)
        n = (vn >> (@digest_bits-@divide_bits)) + 1
        n = 0 if n == (2**@divide_bits)
        n << (@digest_bits-@divide_bits)
      end

      def create_nodes_from_routes
        buf_nodes={}
        routes.each_value{|nids|
          nids.each{|nid| buf_nodes[nid]=nid }
        }
        @nodes=buf_nodes.values.sort
      end

      # Returns the losted vnode-id list.
      def get_lost_vnodes
        ret=[]
        routes.each_pair{|vn,nids|
          ret << vn if nids.length == 0
        }
        ret
      end

      def self.create(digest_bits,divide_bits,redundancy,nodes,repethost=false)
        ret=RoutingData.new(digest_bits,divide_bits,redundancy)
        ret.nodes=nodes.clone

        rnlm=RandomNodeListMaker.new(nodes,repethost)

        (2**divide_bits).times do |i|
          vn=i<<(digest_bits-divide_bits)
          ret.clocks[vn]=0
          ret.routes[vn]=rnlm.list(redundancy)
        end

        # vnode balanceing process
        rlist = ret.get_balanced_vn_replacement_list(repethost)
        ret.balance!(rlist, repethost) if rlist

        ret
      end

      # Returns the log file list by old ordered.
      # +fname+:: Prefix of a log file.(ex.roma0_3300.route)
      # One of the following example:
      #   [[1, "roma0_3300.route.1"], [2, "roma0_3300.route.2"]]
      def get_file_list(fname)
        l={}
        files=Dir.glob("#{fname}*")
        files.each{ |file|
          if /#{fname}\.(\d+)$/=~file
            l[$1.to_i]=$&
          end
        }
        # sorted by old order
        l.to_a.sort{|a,b| a[0]<=>b[0]}
      end

      def get_histogram
        ret = {}
        nodes.each{|nid|
          ret[nid] = Array.new(redundancy,0)
        }
        routes.each_pair{|vn,nids|
          nids.each_with_index{|nid,i|
            ret[nid][i] += 1
          }
        }
        ret
      end

      private

      class RandomNodeListMaker
        def initialize(nodes,repethost)
          @repethost=repethost
          @nodes=nodes
          @host_idx={}
          nodes.each{|nid|
            h, _p = nid.split('_')
            if @host_idx.key?(h)
              @host_idx[h] << nid
            else
              @host_idx[h]=[nid]
            end
          }          
        end

        # Returns the random node-list without repetition.
        # +n+:: list length
        def list(n)
          ret=[]
          hosts=[]
          proc_other_one = :get_other_one
          proc_other_one = :get_other_one_repethost if @repethost
          n.times{
            nid=nil
            nid=send(proc_other_one,hosts,ret)
            break unless nid
            hosts << nid.split('_')[0]
            ret << nid
          }
          ret
        end
        
        # +exp_hosts+:: ignore
        # +exp_nodes+:: exceptional nodes(ex.['roma0_11211'])
        def get_other_one_repethost(exp_hosts,exp_nodes)
          buf=@nodes.clone
          buf.delete_if{|nid| exp_nodes.include?(nid)}
          buf[rand(buf.length)]
        end

        # +exp_hosts+:: exceptional hosts(ex.['roma0','roma1'])
        # +exp_nodes+:: ignore
        def get_other_one(exp_hosts,exp_nodes)
          hidx=@host_idx.clone
          exp_hosts.each{|h| hidx.delete(h) }
          return nil if hidx.length == 0
          
          rh=hidx.keys[rand(hidx.keys.length)]
          nodes=hidx[rh]
          nodes[rand(nodes.length)]
        end
      end # class RandomNodeListMaker

    end # class RoutingData

  end # module Routing
end # module Roma
