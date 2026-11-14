require 'roma/version'
require 'roma/peer_command'

module Roma
  # The jobs that a server runs periodically for the cluster: watching the
  # other nodes, failover, the versions, syncing the routing table, and
  # cleaning up the storages.
  module ClusterMaintenance
    include PeerCommand

    private

    def start_periodic_jobs
      run_periodically(1, :watch_cluster)
      run_periodically(10, :maintain_cluster)
    end

    # Calls +job+ every +interval+ seconds in a thread named after it. An
    # error in +job+ is logged and doesn't stop the thread.
    def run_periodically(interval, job)
      t = Thread.new do
        loop do
          sleep interval
          send(job)
        rescue Exception => e
          @log.error("#{e}\n#{$@}")
        end
      end
      t[:name] = job
      t
    end

    # Checks the other nodes, so that a node that is down fails over, and
    # stops cleaning up the storages while vnodes are moving.
    def watch_cluster
      nodes_check(@routing_table.nodes - [@stats.my_node_id]) if @routing_table.enabled_failover

      if (@stats.run_join || @stats.run_recover || @stats.run_balance) &&
         @stats.run_storage_clean_up
        stop_clean_up
      end
    end

    # Enables failover once all the nodes have started. After that, checks the
    # versions of the nodes and syncs the routing table. Also starts cleaning up
    # the storages, updates the replica cluster and resets the counters.
    def maintain_cluster
      if @startup && @routing_table.enabled_failover == false
        @log.debug('nodes_check start')
        if nodes_check(@routing_table.nodes - [@stats.my_node_id])
          @log.info('all nodes started')
          AsyncEvent.queue.clear
          @routing_table.enabled_failover = true
          Command::Receiver.make_event_list
          @startup = false
        end
      elsif @routing_table.enabled_failover == false
        @log.warn('failover disable now!!')
      else
        version_check
        @routing_table.delete_old_transactions(@stats.routing_transaction_timeout)
        start_sync_routing_process
      end

      if @routing_table.enabled_failover &&
         @stats.run_storage_clean_up == false &&
         @stats.run_balance == false &&
         @stats.run_recover == false &&
         @stats.run_iterate_storage == false &&
         @stats.run_join == false &&
         @stats.run_receive_a_vnode.empty? &&
         @stats.do_clean_up?
        Roma::AsyncEvent.queue.push(Roma::AsyncMessage.new('start_storage_clean_up_process'))
      end

      if @cluster_replication_writer.run_replication && @cluster_replication_writer.change_mklhash?
        node_id = @cluster_replication_writer.replica_nodelist.sample
        @cluster_replication_writer.update_mklhash(node_id)
        @cluster_replication_writer.update_nodelist(node_id)
        @cluster_replication_writer.update_rttable(node_id)
      end

      @stats.clear_counters
    end

    # Whether every node of +nodes+ is up and has the same name. It stops at
    # the first node that isn't.
    def nodes_check(nodes)
      nodes.all? { |node_id| node_check(node_id) }
    end

    def node_check(node_id)
      if @startup && @routing_table.enabled_failover == false && !Roma::Messaging::ConnectionPool.instance.check_connection(node_id)
        @log.info("I'm waiting for booting the #{node_id} instance.")
        return false
      end
      name = async_send_cmd(node_id, "whoami\r\n", 2)
      return false unless name

      if name != @stats.name
        @log.error("#{node_id} has diffarent name.")
        @log.error("me = \"#{@stats.name}\"  #{node_id} = \"#{name}\"")
        return false
      end
      true
    end

    def version_check
      nodes = @routing_table.nodes
      nodes.each do |node_id|
        vs = async_send_cmd(node_id, "version\r\n", 2)
        next unless vs

        if /VERSION\s(?:ROMA-)?(\d+)\.(\d+)\.(\d+)/ =~ vs
          ver = (::Regexp.last_match(1).to_i << 16) + (::Regexp.last_match(2).to_i << 8) + ::Regexp.last_match(3).to_i
          @routing_table.update_version(node_id, ver)
        end
      end
    end

    def start_sync_routing_process
      return if @stats.run_join || @stats.run_recover || @stats.run_balance || @stats.run_sync_routing

      nodes = @routing_table.nodes
      return if nodes.length == 1 && nodes[0] == @stats.my_node_id

      @stats.run_sync_routing = true

      idx = nodes.index(@stats.my_node_id)
      unless idx
        @log.error("My node-id(=#{@stats.my_node_id}) does not found in the routingtable.")
        EventMachine.stop_event_loop
        return
      end
      t = Thread.new do
        begin
          ret = routing_hash_comparison(nodes[idx - 1])
          if ret == :inconsistent
            @log.info('create nodes from routes')

            @routing_table.create_nodes_from_routes
            begin
              con = Roma::Messaging::ConnectionPool.instance.checkout(nodes[idx - 1])
              con.write("create_nodes_from_v_idx\r\n")
              if con.gets == "CREATED\r\n"
                Roma::Messaging::ConnectionPool.instance.checkin(nodes[idx - 1], con)
              else
                @log.error("get busy result in create_nodes_from_v_idx command from #{nodes[idx - 1]}.")
                con.close
              end
            rescue Exception
              @log.error("create_nodes_from_v_idx command unreachable to the #{nodes[idx - 1]}.")
            end
          end
        rescue Exception => e
          @log.error("#{e}\n#{$@}")
        end
        @stats.run_sync_routing = false
      end
      t[:name] = 'sync_routing'
    end

    def routing_hash_comparison(node_id, id = '0')
      return :skip if @stats.run_join || @stats.run_recover || @stats.run_balance

      h = async_send_cmd(node_id, "mklhash #{id}\r\n")
      if h && h.start_with?('ERROR') == false && @routing_table.merkle_tree.get(id) != h
        if (id.length - 1) == @routing_table.divide_bits
          sync_routing(node_id, id)
        else
          routing_hash_comparison(node_id, "#{id}0")
          routing_hash_comparison(node_id, "#{id}1")
        end
        return :inconsistent
      end
      :consistent
    end

    def sync_routing(node_id, id)
      vnode = @routing_table.merkle_tree.to_vnode(id)
      @log.warn("vnode=#{vnode} inconsistent")

      res = async_send_cmd(node_id, "getroute #{vnode}\r\n")
      return if res.nil? || res.start_with?('ERROR')

      clock, *node_ids = res.split(' ')
      clock = @routing_table.update_route(vnode, clock.to_i, node_ids)

      return unless clock.is_a?(Integer) == false

      clock, node_ids = @routing_table.search_nodes_with_clk(vnode)
      cmd = "setroute #{vnode} #{clock - 1}"
      node_ids.each { |other_node_id| cmd << " #{other_node_id}" }
      async_send_cmd(node_id, "#{cmd}\r\n")
    end
  end
end
