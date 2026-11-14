require 'roma/messaging/connection_pool'

module Roma
  module AsyncEvent
    # The processes that move the vnodes between the nodes: join, balance,
    # recover, release, and copying the data to the replica cluster.
    module VnodeTransfer
      private

      def asyncev_start_join_process(_args)
        @log.debug(__method__)
        if (running = running_process)
          @log.error("#{__method__}:#{running} process running")
          return true
        end
        @stats.run_join = true
        start_thread(__method__) do
          join_process
        ensure
          @stats.run_join = false
          @stats.join_node_id = nil
        end
        true
      end

      def asyncev_start_balance_process(_args)
        @log.debug(__method__)
        if (running = running_process)
          @log.error("#{__method__}:#{running} process running")
          return true
        end
        @stats.run_balance = true
        start_thread(__method__) do
          balance_process
        ensure
          @stats.run_balance = false
        end
        true
      end

      def asyncev_reqpushv(args)
        vnode, node_id, p = args
        @log.debug("#{__method__} #{args.inspect}")
        if @stats.run_iterate_storage
          @log.warn("#{__method__}:already be iterated storage process.")
        else
          @stats.run_iterate_storage = true
          start_thread(__method__) do
            sync_a_vnode(vnode.to_i, node_id, p == 'true')
          ensure
            @stats.run_iterate_storage = false
          end
        end
      end

      def asyncev_start_recover_process(args)
        @log.debug("#{__method__} #{args.inspect}")
        if (running = running_process)
          @log.error("#{__method__}:#{running} process running")
          return running != :recover
        end
        @stats.run_recover = true
        start_thread(__method__) do
          acquired_recover_process
        ensure
          @stats.run_recover = false
        end
      end

      def asyncev_start_auto_recover_process(args)
        @log.debug("#{__method__} #{args.inspect}")
        # ##run_join don't have possibility to be true in this case.
        # if @stats.run_join
        #  @log.error("#{__method__}:join process running")
        #  return true
        # end
        if @stats.run_recover
          @log.error("#{__method__}:recover process running.")
          return false
        end
        if @stats.run_balance
          @log.error("#{__method__}:balance process running")
          return true
        end

        @routing_table.auto_recover_status = 'preparing'
        t = Thread.new do
          Timeout.timeout(@routing_table.auto_recover_time) do
            loop do
              sleep 1
              break if @routing_table.auto_recover_status != 'preparing'
              # break if @stats.run_join #run_join don't have possibility to be true in this case.
              break if @stats.run_recover
              break if @stats.run_balance
            end
          end
          @log.debug('inactivated AUTO_RECOVER')
        rescue StandardError
          case @routing_table.lost_action
          when :auto_assign, :shutdown
            @stats.run_recover = true
            @routing_table.auto_recover_status = 'executing'
            begin
              @log.debug('auto recover start')
              acquired_recover_process
            rescue StandardError => e
              @log.error("#{__method__}:#{e.inspect} #{$ERROR_POSITION}")
            ensure
              @stats.run_recover = false
              @routing_table.auto_recover_status = 'waiting'
            end
          when :no_action
            @log.debug('auto recover NOT start. Because lost action is [no_action]')
          end
        end
        t[:name] = __method__
      end

      def asyncev_start_release_process(args)
        @log.debug("#{__method__} #{args}")
        if @stats.run_iterate_storage
          @log.warn("#{__method__}:already be iterated storage process.")
        else
          @stats.run_release = true
          @stats.run_iterate_storage = true
          @stats.spushv_protection = true
          start_thread(__method__) do
            release_process
          ensure
            @stats.run_iterate_storage = false
            @stats.run_release = false
          end
        end
      end

      def acquired_recover_process
        @log.info("#{__method__}:start")

        exclude_nodes = @routing_table.exclude_nodes_for_recover(@stats.my_node_id, @stats.replication_in_host)

        @do_acquired_recover_process = true
        loop do
          break unless @do_acquired_recover_process
          break if @routing_table.count_vnodes(@stats.my_node_id)[2] == 0 # short vnodes

          vnode, nodes, is_primary = @routing_table.select_vnode_for_recover(exclude_nodes, @stats.replication_in_host)
          break unless vnode

          next unless nodes.length != 0

          ret = req_push_a_vnode(vnode, nodes[0], is_primary)
          if ret == :rejected
            sleep 1
          elsif ret == false
            break
          end
          sleep 1
        end
        @log.info("#{__method__} has done.")
      rescue StandardError => e
        @log.error("#{e.inspect} #{$ERROR_POSITION}")
      ensure
        @do_acquired_recover_process = false
      end

      def join_process
        @log.info("#{__method__}:start")
        count = 0
        nv = @routing_table.routes.length
        exclude_nodes = @routing_table.exclude_nodes_for_join(@stats.my_node_id, @stats.replication_in_host)

        @do_join_process = true
        while @routing_table.vnode_balance(@stats.my_node_id) == :less && count < nv
          break unless @do_join_process

          vnode, nodes, is_primary = @routing_table.select_vnode_for_join(exclude_nodes, @stats.replication_in_host)
          unless vnode
            @log.warn("#{__method__}:vnode does not found")
            return false
          end
          ret = req_push_a_vnode(vnode, nodes[0], is_primary)
          if ret == :rejected
            sleep 5
          else
            sleep 1
            count += 1
          end
        end
      rescue StandardError => e
        @log.error("#{e.inspect} #{$ERROR_POSITION}")
      ensure
        @log.info("#{__method__} has done.")
        @do_join_process = false
      end

      def balance_process
        @log.info("#{__method__}:start")
        count = 0
        nv = @routing_table.routes.length
        exclude_nodes = @routing_table.exclude_nodes_for_balance(@stats.my_node_id, @stats.replication_in_host)

        @do_balance_process = true
        while @routing_table.vnode_balance(@stats.my_node_id) == :less && count < nv
          break unless @do_balance_process

          vnode, nodes, is_primary = @routing_table.select_vnode_for_balance(exclude_nodes, @stats.replication_in_host)
          unless vnode
            @log.warn("#{__method__}:vnode does not found")
            return false
          end
          ret = req_push_a_vnode(vnode, nodes[0], is_primary)
          if ret == :rejected
            sleep 5
          else
            sleep 1
            count += 1
          end
        end
        @log.info("#{__method__} has done.")
      rescue StandardError => e
        @log.error("#{e.inspect} #{$ERROR_POSITION}")
      ensure
        @do_balance_process = false
      end

      def req_push_a_vnode(vnode, src_node_id, is_primary)
        con = Roma::Messaging::ConnectionPool.instance.checkout(src_node_id)
        con.write("reqpushv #{vnode} #{@stats.my_node_id} #{is_primary}\r\n")
        res = con.gets # receive 'PUSHED\r\n' | 'REJECTED\r\n' | 'ERROR\r\n'
        if res == "REJECTED\r\n"
          @log.warn("#{__method__}:request was rejected from #{src_node_id}.")
          Roma::Messaging::ConnectionPool.instance.checkin(src_node_id, con)
          return :rejected
        elsif res != "PUSHED\r\n"
          @log.warn("#{__method__}:#{res}")
          return :rejected
        end
        Roma::Messaging::ConnectionPool.instance.checkin(src_node_id, con)
        # waiting for pushv
        count = 0
        while @routing_table.search_nodes(vnode).include?(@stats.my_node_id) == false &&
              count < @stats.reqpushv_timeout_count
          sleep 0.1
          count += 1
        end
        if count >= @stats.reqpushv_timeout_count
          @log.warn("#{__method__}:request has been time-out.vnode=#{vnode} node_id=#{src_node_id}")
          return :timeout
        end
        true
      rescue StandardError => e
        @log.error("#{__method__}:#{e.inspect} #{$ERROR_POSITION}")
        @routing_table.proc_failed(src_node_id)
        false
      end

      def release_process
        @log.info("#{__method__}:start.")

        if @routing_table.can_i_release?(@stats.my_node_id, @stats.replication_in_host)
          @log.error("#{__method__}:Sufficient nodes do not found.")
          return
        end

        @do_release_process = true
        while @routing_table.has_node?(@stats.my_node_id)
          break unless @do_release_process

          @routing_table.each_vnode do |vnode, node_ids|
            break unless @do_release_process

            next unless node_ids.include?(@stats.my_node_id)

            to_node_id, new_node_ids = @routing_table.select_node_for_release(@stats.my_node_id,
                                                                              @stats.replication_in_host, node_ids)
            res = sync_a_vnode_for_release(vnode, to_node_id, new_node_ids)
            if res == :abort
              @log.error("#{__method__}:release_process aborted due to SERVER_ERROR received.")
              @do_release_process = false
            end
            if res == false
              @log.warn("#{__method__}:error at vnode=#{vnode} to_node_id=#{to_node_id} new_node_id=#{new_node_ids}")
              redo
            end
          end
        end
        @log.info("#{__method__} has done.")
      rescue StandardError => e
        @log.error("#{e}\n#{$ERROR_POSITION}")
      ensure
        @do_release_process = false
        Roma::Messaging::ConnectionPool.instance.close_all
      end

      def sync_a_vnode_for_release(vnode, to_node_id, new_node_ids)
        node_ids = @routing_table.search_nodes(vnode)

        if node_ids.include?(to_node_id) == false
          @log.debug("#{__method__}:#{vnode} #{to_node_id}")
          # change routing data at the vnode and synchronize a data
          node_ids << to_node_id
          return false unless @routing_table.transaction(vnode, node_ids)

          # synchronize a data
          @storages.each_key do |hash_name|
            res = push_a_vnode_stream(hash_name, vnode, to_node_id)

            next unless res != 'STORED'

            @routing_table.rollback(vnode)
            @log.error("#{__method__}:push_a_vnode was failed:hash_name=#{hash_name} vnode=#{vnode}:#{res}")
            return :abort if res.start_with?('SERVER_ERROR')

            return false
          end

          if (clock = @routing_table.commit(vnode)) == false
            @routing_table.rollback(vnode)
            @log.error("#{__method__}:routing table commit failed")
            return false
          end

          clock = @routing_table.update_route(vnode, clock, new_node_ids)
          clock, new_node_ids = @routing_table.search_nodes_with_clk(vnode) if clock.is_a?(Integer) == false

          cmd = "setroute #{vnode} #{clock - 1}"
          new_node_ids.each { |nn| cmd << " #{nn}" }
          res = async_broadcast_cmd("#{cmd}\r\n")
          @log.debug("#{__method__}:async_broadcast_cmd(#{cmd}) #{res}")
        end

        true
      rescue StandardError => e
        @log.error("#{e}\n#{$ERROR_POSITION}")
        false
      end

      def sync_a_vnode(vnode, to_node_id, is_primary = nil)
        node_ids = @routing_table.search_nodes(vnode)

        if node_ids.include?(to_node_id) == false || (is_primary && node_ids[0] != to_node_id)
          @log.debug("#{__method__}:#{vnode} #{to_node_id} #{is_primary}")
          # change routing data at the vnode and synchronize a data
          node_ids << to_node_id
          return false unless @routing_table.transaction(vnode, node_ids)

          # synchronize a data
          @storages.each_key do |hash_name|
            res = push_a_vnode_stream(hash_name, vnode, to_node_id)

            next unless res != 'STORED'

            @routing_table.rollback(vnode)
            @log.error("#{__method__}:push_a_vnode was failed:hash_name=#{hash_name} vnode=#{vnode}:#{res}")
            return false
          end

          if (clock = @routing_table.commit(vnode)) == false
            @routing_table.rollback(vnode)
            @log.error("#{__method__}:routing table commit failed")
            return false
          end

          node_ids = edit_nodes(node_ids, to_node_id, is_primary)
          clock = @routing_table.update_route(vnode, clock, node_ids)
          clock, node_ids = @routing_table.search_nodes_with_clk(vnode) if clock.is_a?(Integer) == false

          cmd = "setroute #{vnode} #{clock - 1}"
          node_ids.each { |nn| cmd << " #{nn}" }
          res = async_broadcast_cmd("#{cmd}\r\n")
          @log.debug("#{__method__}:async_broadcast_cmd(#{cmd}) #{res}")
        else
          # synchronize a data
          @storages.each_key do |hash_name|
            res = push_a_vnode_stream(hash_name, vnode, to_node_id)
            if res != 'STORED'
              @log.error("#{__method__}:push_a_vnode was failed:hash_name=#{hash_name} vnode=#{vnode}:#{res}")
              return false
            end
          end
        end

        true
      rescue StandardError => e
        @log.error("#{e}\n#{$ERROR_POSITION}")
        false
      end

      def edit_nodes(nodes, new_node_id, is_primary)
        return [new_node_id] if @routing_table.redundancy == 1

        # [node_a, node_b, new_node_id]
        nodes.delete(new_node_id)
        # [node_a, node_b]

        if nodes.length >= @routing_table.redundancy
          host = new_node_id.split(/[:_]/)[0]
          buf = [] # list of a same host
          nodes.each do |node_id|
            buf << node_id if node_id.split(/[:_]/)[0] == host
          end
          if buf.length > 0
            # include same host
            # delete a last one, due to save a primary node
            nodes.delete(buf.last)
          else
            nodes.delete(nodes.last)
          end
        end

        if is_primary
          # [new_node_id, node_a]
          nodes.insert(0, new_node_id)
        else
          # [node_a, new_node_id]
          nodes << new_node_id
        end
        nodes
      end

      def push_a_vnode_stream(hash_name, vnode, node_id)
        @log.debug("#{__method__}:hash_name=#{hash_name} vnode=#{vnode} node_id=#{node_id}")

        # Not a SERVER_ERROR, which would make the release process abort; the
        # push is tried again.
        unless stop_clean_up
          @log.error("#{__method__}:the storage clean up didn't stop:hash_name=#{hash_name} vnode=#{vnode}")
          return 'CANCELED'
        end

        con = Roma::Messaging::ConnectionPool.instance.checkout(node_id)

        @do_push_a_vnode_stream = true

        con.write("spushv #{hash_name} #{vnode}\r\n")

        res = con.gets # READY\r\n or error string
        if res != "READY\r\n"
          con.close
          return res.chomp
        end

        res_dump = @storages[hash_name].each_vn_dump(vnode) do |data|
          unless @do_push_a_vnode_stream
            con.close
            @log.error("#{__method__}:canceled in hash_name=#{hash_name} vnode=#{vnode} node_id=#{node_id}")
            return 'CANCELED'
          end

          con.write(data)
          sleep @stats.stream_copy_wait
        end
        con.write("\0" * 20) # end of stream

        res = con.gets # STORED\r\n or error string
        Roma::Messaging::ConnectionPool.instance.checkin(node_id, con)
        res.chomp! if res
        if res_dump == false
          @log.error("#{__method__}:each_vn_dump in hash_name=#{hash_name} vnode=#{vnode} node_id=#{node_id}")
          return 'CANCELED'
        end
        res
      rescue StandardError => e
        @log.error("#{e}\n#{$ERROR_POSITION}")
        e.to_s
      end

      def asyncev_start_replicate_existing_data_process(args)
        # args is [@cluster_replication_writer.replica_rttable])
        start_thread(__method__) do
          @cluster_replication_writer.run_existing_data_replication = true
          replicate_existing_data_process(args)
        ensure
          @cluster_replication_writer.run_existing_data_replication = false
        end
      end

      def replicate_existing_data_process(args)
        @log.info("#{__method__} :start.")

        @storages.each_key do |hash_name|
          @routing_table.routes.each_key do |vnode|
            raise unless @cluster_replication_writer.run_existing_data_replication

            args[0].routes[vnode].each do |replica_node_id|
              res = push_a_vnode_stream(hash_name, vnode, replica_node_id)
              if res != 'STORED'
                @log.error("#{__method__}:push_a_vnode was failed:hash_name=#{hash_name} vnode=#{vnode}:#{res}")
                return false
              end
            end
          end
        end

        @log.info("#{__method__} has done.")
      rescue StandardError => e
        @log.error("#{e}\n#{$ERROR_POSITION}")
      end
    end
  end
end
