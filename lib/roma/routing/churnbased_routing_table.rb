require 'roma/routing/routing_table'
require 'roma/routing/random_partitioner'

module Roma
  module Routing

    class ChurnbasedRoutingTable < RoutingTable

      include Routing::RandomPartitioner

      attr :fname
      attr :log_fd
      attr :log_name
      attr :transactions # transaction
      attr :leave_proc
      attr :lost_proc
      attr :recover_proc
      attr_accessor :lost_action
      attr_accessor :auto_recover
      attr_accessor :auto_recover_status
      attr_accessor :auto_recover_time
      attr_accessor :event
      attr_accessor :event_limit_line
      attr_accessor :logs
      attr_reader :version_of_nodes
      attr_reader :min_version

      def initialize(routing_data,fname)
        super(routing_data)
        @routing_data.nodes.sort!
        @transactions={}
        @fname=fname
        @leave_proc=nil
        @lost_proc=nil
        @recover_proc=nil
        @lost_action=:no_action
        @auto_recover=false
        @auto_recover_status="waiting"
        @auto_recover_time=1800
        @event = []
        @event_limit_line = 1000
        @logs = []
        @enabled_failover=false
        @lock = Mutex.new
        @version_of_nodes = Hash.new(0)
        @min_version = nil
        open_log
      end

      def get_stat(ap)
        ret = super(ap)
        ret['routing.lost_action'] = @lost_action.to_s
        ret['routing.auto_recover'] = @auto_recover.to_s
        ret['routing.auto_recover_status'] = @auto_recover_status.to_s
        ret['routing.auto_recover_time'] = @auto_recover_time
        ret['routing.event'] = @event
        ret['routing.event_limit_line'] = @event_limit_line
        ret['routing.version_of_nodes'] = @version_of_nodes.inspect
        ret['routing.min_version'] = @min_version
        ret['routing.enabled_failover'] = @enabled_failover
        ret
      end

      def set_version(node_id,ver)
        @version_of_nodes[node_id] = ver
        @min_version = find_min_version
      end

      def find_min_version
        ret = 0xffffff
        @version_of_nodes.each_value{|ver| ret = ver if ret > ver}
        ret
      end

      def set_leave_proc(&block)
        @leave_proc=block
      end

      def set_lost_proc(&block)
        @lost_proc=block
      end

      def set_recover_proc(&block)
        @recover_proc=block
      end

      def open_log
        log_list=@routing_data.get_file_list(@fname)
        prefix=RoutingData.log_prefix(@fname)
        if log_list.length==0
          @log_name="#{prefix}.1"
        else
          if File::stat("#{prefix}.#{log_list.last[0]}").size == 0
            @log_name="#{prefix}.#{log_list.last[0]}"
          else
            @log_name="#{prefix}.#{log_list.last[0]+1}"
          end
        end
        @log_fd=File.open(@log_name,"a")
      end

      def write_log_setroute(vnode, clock, node_ids)
        log="setroute #{vnode} #{clock}"
        node_ids.each{ |node_id| log << " #{node_id}" }
        write_log(log)
      end

      def write_log(line)
        # log rotation
        if File::stat(@log_name).size > 1000 * 1024
          close_log
          open_log
        end
        t = Time.now
        time_string = "#{t.strftime('%Y-%m-%dT%H:%M:%S')}.#{t.usec}"
        @log_fd.write("#{time_string} #{line}\n")
        @log_fd.flush
      end

      def close_log
        @log_fd.close
      end

      def can_i_recover?
        @routing_data.nodes.length >= @routing_data.redundancy
      end

      def can_i_release?(my_node_id, replication_in_host)
        buf = self.nodes
        buf.delete(my_node_id)
        hosts = []

        unless replication_in_host
          buf.each{ |node|
            host = node.split(/[:_]/)[0]
            hosts << host unless hosts.include?(host)
          }
        else
          hosts = buf
        end

        hosts.length < @routing_data.redundancy
      end

      # Returns the list of losted-data vnode newer than argument time.
      def search_lost_vnodes(t)
        ret = []
        @routing_data.each_log_all(@fname){|log_t,line|
          next if t > log_t
          s = line.split(/ /)
          if s[0] == 'setroute' && s.length == 3
            # vnode has a no pnode. therefor this vnode was lost.
            ret << s[1].to_i
          end
        }
        ret
      end

      # select a vnodes where short of redundancy.
      def select_a_short_vnodes(exclued_nodes)
        ret = []
        @routing_data.routes.each_pair{|vnode, node_ids|
          if node_ids.length < @routing_data.redundancy && list_include?(node_ids,exclued_nodes) == false
            ret << [vnode,node_ids]
          end
        }
        ret
      end

      # vnode sampling without +without_nodes+
      def sample_vnode(without_nodes)
        short_idx = {}
        idx = {}
        @routing_data.routes.each_pair{|vnode, node_ids|
          unless list_include?(node_ids, without_nodes)
            idx[vnode] = node_ids
            short_idx[vnode] = node_ids if node_ids.length < @routing_data.redundancy
          end
        }
        idx = short_idx if short_idx.length > 0

        ks = idx.keys
        return nil if ks.length == 0
        vnode = ks[rand(ks.length)]
        node_ids = idx[vnode]
        [vnode, node_ids]
      end

      def list_include?(list,nodes)
        nodes.each{|node_id|
          return true if list.include?(node_id)
        }
        false
      end
      private :list_include?

      def set_route(vnode, clock, node_ids)
        return "#{vnode} is not found." unless @routing_data.routes.key?(vnode)
        @lock.synchronize {
          return "It's old table." if @routing_data.clocks[vnode] > clock
          node_ids.each{ |node_id|
            add_node(node_id) unless @routing_data.nodes.include?(node_id)
          }
          @routing_data.routes[vnode] = node_ids.clone
          clock += 1
          @routing_data.clocks[vnode] = clock
          @merkle_tree.set(vnode, node_ids)
          write_log_setroute(vnode, clock, node_ids)
          return clock
        }
      end

      def add_node(node_id)
        unless @routing_data.nodes.include?(node_id)
          @routing_data.nodes << node_id
          @routing_data.nodes.sort!
          write_log("join #{node_id}")
          set_event(node_id, 'join')
        end
      end

      def enabled_failover=(b)
        @failure_counts.clear
        @enabled_failover=b
      end

      def enabled_failover
        @enabled_failover
      end

      def leave(node_id)
        unless @enabled_failover
          return
        end
        return unless @routing_data.nodes.include?(node_id)

        @leave_proc.call(node_id) if @leave_proc
        @routing_data.nodes.delete(node_id)
        @version_of_nodes.delete(node_id)
        @min_version = find_min_version

        @log.warn("#{node_id} just failed.")
        write_log("leave #{node_id}")
        set_event(node_id, __method__)

        lost_vnodes=[]
        short_vnodes=[]
        @lock.synchronize {
          @routing_data.routes.each_pair{ |vnode, node_ids|
            buf = node_ids.clone
            if buf.delete(node_id)
              set_route_and_inc_clk_inside_sync(vnode, buf)
              if buf.length == 0
                lost_vnodes << vnode
                @log.error("Vnode data is lost.(Vnode=#{vnode})")
              elsif buf.length < @routing_data.redundancy
                short_vnodes << vnode
              end
            end
          }
        }
        if lost_vnodes.length > 0
          @lost_proc.call if @lost_proc
          if @lost_action == :auto_assign
            lost_vnodes.each{ |vnode|
              set_route_and_inc_clk_inside_sync( vnode, next_alive_vnode(vnode) )
            }
          end
        elsif short_vnodes.length > 0
          @log.error("Short vnodes exist.")
          @recover_proc.call('start_auto_recover_process') if @recover_proc
        end
        @failure_counts.delete(node_id)
      end

      def set_event(node_id, process)
        t = Time.now
        time_string = "#{t.strftime('%Y-%m-%dT%H:%M:%S')}.#{t.usec}"
        @event.shift if @event.size >= @event_limit_line
        @event << ("#{time_string} #{process} #{node_id}")
      end
      private :set_event

      def set_route_and_inc_clk_inside_sync(vnode, nodes)
        @routing_data.routes[vnode] = nodes
        clock = @routing_data.clocks[vnode] + 1
        @routing_data.clocks[vnode] = clock
        @merkle_tree.set(vnode, nodes)
        write_log_setroute(vnode, clock, nodes)
        clock
      end
      private :set_route_and_inc_clk_inside_sync

      def next_alive_vnode(vnode)
        svn = vnode
        while( (vnode = @routing_data.next_vnode(vnode)) != svn )
          return @routing_data.routes[vnode].clone if @routing_data.routes[vnode].length != 0
        end
        []
      end
      private :next_alive_vnode

      def each_vnode
        @routing_data.routes.each_pair{ |k, v| yield(k, v) }
      end

      def routes
        @routing_data.routes.clone
      end

      def search_nodes_for_write(vnode)
        return @transactions[vnode][0].clone if @transactions.key?(vnode)
        @routing_data.routes[vnode].clone
      rescue
        nil
      end

      def search_nodes_with_clk(vnode)
        @lock.synchronize {
          return [@routing_data.clocks[vnode], @routing_data.routes[vnode].clone]
        }
      rescue
        nil
      end

      # +vnode+: vnode-id
      # +node_ids+: node-id list
      def transaction(vnode, node_ids)
        return false if @transactions.key?(vnode)
        @transactions[vnode]=[node_ids.clone, Time.now]
        true
      end

      def commit(vnode)
        return false unless @transactions.key?(vnode)
        @lock.synchronize {
          @routing_data.routes[vnode]=@transactions[vnode][0]
          @transactions.delete(vnode)
          clock = @routing_data.clocks[vnode] + 1
          @routing_data.clocks[vnode] = clock
          @merkle_tree.set(vnode, @routing_data.routes[vnode])
          write_log_setroute(vnode, clock, @routing_data.routes[vnode])
          return clock
        }
      end

      def rollback(vnode)
        @transactions.delete(vnode)
      end

      # +sec+: elapsed-time
      def delete_old_transactions(sec=3600)
        @transactions.delete_if{|vnode,val| val[1] < Time.now-sec }
      end

      # Returns the status of vnode balance.
      # +ap+: my address_port string(ex."roma0_11211")
      def vnode_balance(ap)
        # amount of primary at node = amount of vnode / amount of node
        n = (2**divide_bits) / nodes.length

        pcount = scount = 0
        @routing_data.routes.each_pair{ |vnode, node_ids|
          next if node_ids == nil or node_ids.length == 0
          if node_ids[0] == ap
            pcount += 1
          elsif node_ids.include?(ap)
            scount += 1
          end
        }

        @log.debug("#{__method__}:n=#{n} pcount=#{pcount} scount=#{scount}")

        if pcount > n
          return :over
        elsif pcount < n
          return :less
        end
        :even
      end

      def has_node?(my_node_id)
        self.each_vnode do |vnode, node_ids|
          return true if node_ids.include?(my_node_id)
        end
        false
      end

    end # class ChurnbasedRoutingTable

  end # module Routing
end # module Roma
