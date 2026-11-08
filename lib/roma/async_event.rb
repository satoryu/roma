require 'digest/sha1'
require 'timeout'
require 'roma/async_message'
require 'roma/configuration'

module Roma
  module AsyncEvent
    @@async_queue = Queue.new

    def self.queue
      @@async_queue
    end

    def start_async_event_loop
      @async_thread = Thread.new do
        async_event_loop
      end
      @async_thread[:name] = __method__
    rescue StandardError => e
      @log.error("#{e}\n#{$ERROR_POSITION}")
    end

    private

    def stop_async_event_loop
      count = 0
      while @@async_queue.empty? == false && count < 100
        count += 1
        sleep 0.1
      end
      @async_thread.exit
    end

    def async_event_loop
      loop do
        while msg = @@async_queue.pop
          if send("asyncev_#{msg.event}", msg.args)
            msg.callback.call(msg, true) if msg.callback
          elsif msg.retry?
            t = Thread.new do
              msg.wait
              msg.incr_count
              @@async_queue.push(msg)
            end
            t[:name] = __method__
          else
            @log.error("async event retry out:#{msg.inspect}")
            msg.callback.call(msg, false) if msg.callback
          end
        end
      end
    rescue StandardError => e
      @log.error("#{e}\n#{$ERROR_POSITION}")
      retry
    end

    def asyncev_broadcast_cmd(args)
      @log.debug("#{__method__} #{args.inspect}")
      cmd, node_ids, tout = args
      t = Thread.new do
        async_broadcast_cmd("#{cmd}\r\n", node_ids, tout)
      end
      t[:name] = __method__
      true
    end

    def asyncev_start_join_process(_args)
      @log.debug(__method__)
      if @stats.run_join
        @log.error("#{__method__}:join process running")
        return true
      end
      if @stats.run_recover
        @log.error("#{__method__}:recover process running")
        return true
      end
      if @stats.run_balance
        @log.error("#{__method__}:balance process running")
        return true
      end
      @stats.run_join = true
      t = Thread.new do
        join_process
      rescue StandardError => e
        @log.error("#{__method__}:#{e.inspect} #{$ERROR_POSITION}")
      ensure
        @stats.run_join = false
        @stats.join_node_id = nil
      end
      t[:name] = __method__
      true
    end

    def asyncev_start_balance_process(_args)
      @log.debug(__method__)
      if @stats.run_join
        @log.error("#{__method__}:join process running")
        return true
      end
      if @stats.run_recover
        @log.error("#{__method__}:recover process running")
        return true
      end
      if @stats.run_balance
        @log.error("#{__method__}:balance process running")
        return true
      end
      @stats.run_balance = true
      t = Thread.new do
        balance_process
      rescue StandardError => e
        @log.error("#{__method__}:#{e.inspect} #{$ERROR_POSITION}")
      ensure
        @stats.run_balance = false
      end
      t[:name] = __method__
      true
    end

    def asyncev_redundant(args)
      node_id, hash_name, k, d, clock, expire_time, v = args
      @log.debug("#{__method__} #{args.inspect}")
      unless @routing_table.nodes.include?(node_id)
        @log.warn("async redundant failed:#{node_id} does not found in routing table.#{k}\e#{hash_name} #{d} #{clock} #{expire_time} #{v.length}")
        return true # no retry
      end
      res = async_send_cmd(node_id, "rset #{k}\e#{hash_name} #{d} #{clock} #{expire_time} #{v.length}\r\n#{v}\r\n", 10)
      if res.nil? || res.start_with?('ERROR')
        @log.warn("async redundant failed:#{k}\e#{hash_name} #{d} #{clock} #{expire_time} #{v.length} -> #{node_id}")
        return false # retry
      end
      true
    end

    def asyncev_zredundant(args)
      node_id, hash_name, k, d, clock, expire_time, zv = args
      @log.debug("#{__method__} #{args.inspect}")
      unless @routing_table.nodes.include?(node_id)
        @log.warn("async zredundant failed:#{node_id} does not found in routing table.#{k}\e#{hash_name} #{d} #{clock} #{expire_time} #{zv.length}")
        return true # no retry
      end
      res = async_send_cmd(node_id, "rzset #{k}\e#{hash_name} #{d} #{clock} #{expire_time} #{zv.length}\r\n#{zv}\r\n",
                           10)
      if res.nil? || res.start_with?('ERROR')
        @log.warn("async zredundant failed:#{k}\e#{hash_name} #{d} #{clock} #{expire_time} #{zv.length} -> #{node_id}")
        return false # retry
      end
      true
    end

    def asyncev_rdelete(args)
      node_id, hash_name, k, clock = args
      @log.debug("#{__method__} #{args.inspect}")
      unless @routing_table.nodes.include?(node_id)
        @log.warn("async rdelete failed:#{node_id} does not found in routing table.#{k}\e#{hash_name} #{clock}")
        return true # no retry
      end
      res = async_send_cmd(node_id, "rdelete #{k}\e#{hash_name} #{clock}\r\n", 10)
      unless res
        @log.warn("async redundant failed:#{k}\e#{hash_name} #{clock} -> #{node_id}")
        return false # retry
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
        t = Thread.new do
          sync_a_vnode(vnode.to_i, node_id, p == 'true')
        rescue StandardError => e
          @log.error("#{__method__}:#{e.inspect} #{$ERROR_POSITION}")
        ensure
          @stats.run_iterate_storage = false
        end
        t[:name] = __method__
      end
    end

    def asyncev_start_recover_process(args)
      @log.debug("#{__method__} #{args.inspect}")
      if @stats.run_join
        @log.error("#{__method__}:join process running")
        return true
      end
      if @stats.run_recover
        @log.error("#{__method__}:recover process running.")
        return false
      end
      if @stats.run_balance
        @log.error("#{__method__}:balance process running")
        return true
      end
      @stats.run_recover = true
      t = Thread.new do
        acquired_recover_process
      rescue StandardError => e
        @log.error("#{__method__}:#{e.inspect} #{$ERROR_POSITION}")
      ensure
        @stats.run_recover = false
      end
      t[:name] = __method__
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
        t = Thread.new do
          release_process
        rescue StandardError => e
          @log.error("#{__method__}:#{e.inspect} #{$ERROR_POSITION}")
        ensure
          @stats.run_iterate_storage = false
          @stats.run_release = false
        end
        t[:name] = __method__
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
      while @routing_table.search_nodes(vnode).include?(@stats.my_node_id) == false && count < @stats.reqpushv_timeout_count
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

      stop_clean_up

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

    def asyncev_start_storage_clean_up_process(_args)
      #      @log.info("#{__method__}")
      if @stats.run_storage_clean_up
        @log.error("#{__method__}:already in being")
        return
      end
      @stats.run_storage_clean_up = true
      t = Thread.new do
        storage_clean_up_process
      rescue StandardError => e
        @log.error("#{__method__}:#{e.inspect} #{$ERROR_POSITION}")
      ensure
        @stats.last_clean_up = Time.now
        @stats.run_storage_clean_up = false
      end
      t[:name] = __method__
    end

    def storage_clean_up_process
      @log.info("#{__method__}:start")
      me = @stats.my_node_id
      vnhash = {}
      @routing_table.each_vnode do |vnode, node_ids|
        next unless node_ids.include?(me)

        vnhash[vnode] = if node_ids[0] == me
                          :primary
                        else
                          :"secondary#{node_ids.index(me)}"
                        end
      end
      t = Time.now.to_i - Roma.config.storage.delete_mark_expire_time
      count = 0
      @storages.each_pair do |hash_name, st|
        break unless @stats.do_clean_up?

        st.each_clean_up(t, vnhash) do |key, vnode|
          # @log.debug("#{__method__}:key=#{key} vnode=#{vnode}")
          if @stats.run_receive_a_vnode.key?("#{hash_name}_#{vnode}")
            false
          else
            nodes = @routing_table.search_nodes_for_write(vnode)
            if nodes && nodes.length > 1
              nodes[1..-1].each do |node_id|
                res = async_send_cmd(node_id, "out #{key}\e#{hash_name} #{vnode}\r\n")
                @log.warn("send out command failed:#{key}\e#{hash_name} #{vnode} -> #{node_id}") unless res
                # @log.debug("#{__method__}:res=#{res}")
              end
            end
            count += 1
            @stats.out_count += 1
            true
          end
        end
      end
      @log.info("#{__method__}:#{count} keys deleted.") if count > 0

      # delete @routing_table.logs
      if @stats.gui_run_gather_logs || @routing_table.logs.empty?
        false
      else
        gathered_time = @routing_table.logs[0]
        # delete gathering log data after 5min
        @routing_table.logs.clear if gathered_time.to_i < Time.now.to_i - (60 * 5)
      end
    ensure
      @log.info("#{__method__}:stop")
    end

    def asyncev_start_storage_flush_process(args)
      hash_name, db_index = args
      @log.debug("#{__method__} #{args.inspect}")

      st = @storages[hash_name]
      if st.dbs[db_index] != :safecopy_flushing
        @log.error("Can not flush storage. stat = #{st.dbs[db_index]}")
        return true
      end
      t = Thread.new do
        st.flush_db(db_index)
        st.update_db_status(db_index, :safecopy_flushed)
        @log.info("#{__method__}:storage has flushed. (#{hash_name}, #{db_index})")
      rescue StandardError => e
        @log.error("#{__method__}:#{e.inspect} #{$ERROR_POSITION}")
      end
      t[:name] = __method__
      true
    end

    def asyncev_start_storage_cachecleaning_process(args)
      hash_name, db_index = args
      @log.debug("#{__method__} #{args.inspect}")

      st = @storages[hash_name]
      if st.dbs[db_index] != :cachecleaning
        @log.error("Can not start cachecleaning process. stat = #{st.dbs[db_index]}")
        return true
      end
      t = Thread.new do
        storage_cachecleaning_process(hash_name, db_index)
      rescue StandardError => e
        @log.error("#{__method__}:#{e.inspect} #{$ERROR_POSITION}")
      end
      t[:name] = __method__
      true
    end

    def storage_cachecleaning_process(hash_name, db_index)
      count = 0
      rcount = 0
      st = @storages[hash_name]

      @do_storage_cachecleaning_process = true
      loop do
        # get keys in a cache up to 100 kyes
        keys = st.keys_in_cache(db_index)
        break if keys.nil? || keys.length == 0
        break unless @do_storage_cachecleaning_process

        # @log.debug("#{__method__}:#{keys.length} keys found")

        # copy cache -> db
        st.each_cache_by_keys(db_index, keys) do |vnode, last, clock, expire_time, k, v|
          break unless @do_storage_cachecleaning_process

          if st.load_stream_dump_for_cachecleaning(vnode, last, clock, expire_time, k, v)
            count += 1
            # @log.debug("#{__method__}:[#{vnode} #{last} #{clock} #{expire_time} #{k}] was stored.")
          else
            rcount += 1
            # @log.debug("#{__method__}:[#{vnode} #{last} #{clock} #{expire_time} #{k}] was rejected.")
          end
        end

        # remove keys in a cache
        keys.each { |key| st.out_cache(db_index, key) }
      end
      if @do_storage_cachecleaning_process == false
        @log.warn("#{__method__}:uncompleted")
      else
        st.update_db_status(db_index, :normal)
      end
      @log.debug("#{__method__}:#{count} keys loaded.")
      @log.debug("#{__method__}:#{rcount} keys rejected.") if rcount > 0
    ensure
      @do_storage_cachecleaning_process = false
    end

    def asyncev_start_get_routing_event(args)
      @log.debug("#{__method__} #{args}")
      t = Thread.new do
        load_routing_events
      rescue StandardError => e
        @log.error("#{__method__}:#{e.inspect} #{$ERROR_POSITION}")
      end
      t[:name] = __method__
    end

    def load_routing_events
      @log.info("#{__method__}:start.")

      routing_path = Roma.config.routing.path
      # The storage files may be in a directory named like the routing logs.
      f_list = Dir.glob("#{routing_path}/#{@stats.my_node_id}*").select { |f| File.file?(f) }

      f_list.each do |fname|
        IO.foreach(fname) do |line|
          if line =~ /join|leave/
            @routing_table.event.shift if @routing_table.event.size >= @routing_table.event_limit_line
            @routing_table.event << line.chomp
          end
        end
      end

      @log.info("#{__method__} has done.")
    rescue StandardError => e
      @log.error("#{e}\n#{$ERROR_POSITION}")
    end

    def asyncev_start_get_logs(args)
      @log.debug("#{__method__} #{args}")
      t = Thread.new do
        load_logs(args)
      rescue StandardError => e
        @log.error("#{__method__}:#{e.inspect} #{$ERROR_POSITION}")
      ensure
        @stats.gui_run_gather_logs = false
      end
      t[:name] = __method__
    end

    def load_logs(args)
      @log.debug("#{__method__}:start.")

      log_path = Roma.config.log.path
      log_file = "#{log_path}/#{@stats.my_node_id}.log"

      target_logs = []
      File.open(log_file) do |f|
        start_point = find_point(f, args[0], 'start')
        end_point = find_point(f, args[1], 'end')

        ## read target logs
        f.seek(start_point, IO::SEEK_SET)
        target_logs = f.read(end_point - start_point)
        target_logs = target_logs.each_line.map(&:chomp)
        target_logs.delete('.')
      end

      @routing_table.logs = target_logs
      # set gathered date for expiration
      @routing_table.logs.unshift(Time.now)

      @log.debug("#{__method__} has done.")
    rescue StandardError => e
      @routing_table.logs = []
      @log.error("#{e}\n#{$ERROR_POSITION}")
    ensure
      @stats.gui_run_gather_logs = false
    end

    def find_point(f, target_time, type, latency_time = Time.now, current_pos = 0, new_pos = f.size / 2)
      # hilatency check
      ps = Time.now - latency_time
      if ps > 5
        @log.warn('gather_logs process was failed.')
        raise
      end

      # initialize read size
      read_size = 2048

      # first check
      unless target_time.class == Time
        # in case of not set end_date
        return f.size if target_time == 'current'

        target_time =~ /(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)/
        target_time = Time.mktime(Regexp.last_match[1], Regexp.last_match[2], Regexp.last_match[3],
                                  Regexp.last_match[4], Regexp.last_match[5], Regexp.last_match[6], 0o00000)

        # check outrange or not
        f.seek(0, IO::SEEK_SET)
        begining_log = f.read(read_size)
        # Regexp.last_match is the first time in the log.
        begining_log.index(/[IDEW],\s\[(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)\.(\d+)/)
        begining_time = Time.mktime(Regexp.last_match[1], Regexp.last_match[2], Regexp.last_match[3],
                                    Regexp.last_match[4], Regexp.last_match[5], Regexp.last_match[6], Regexp.last_match[7])

        f.seek(-read_size, IO::SEEK_END)
        end_log = f.read(read_size)
        # Regexp.last_match is the last time in the log.
        end_log.rindex(/[IDEW],\s\[(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)\.(\d+)/)
        end_time = Time.mktime(Regexp.last_match[1], Regexp.last_match[2], Regexp.last_match[3], Regexp.last_match[4],
                               Regexp.last_match[5], Regexp.last_match[6], Regexp.last_match[7])

        case type
        when 'start'
          if target_time < begining_time
            return 0
          elsif target_time > end_time
            @log.error('irregular time was set.')
            raise
          end
        when 'end'
          if target_time > end_time
            return f.size
          elsif target_time < begining_time
            @log.error('irregular time was set.')
            raise
          end
        end
      end

      # read half sector size
      f.seek(new_pos, IO::SEEK_SET)
      sector_log = f.read(read_size)
      # grep date
      date_a = sector_log.scan(/[IDEW],\s\[(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)\.(\d+)/)

      time_a = []
      date_a.each do |time|
        time_a.push(Time.mktime(time[0], time[1], time[2], time[3], time[4], time[5], time[6]))
      end
      sector_time_first = time_a[0]
      sector_time_last = time_a[-1]

      if target_time.between?(sector_time_first, sector_time_last)
        time_a.each do |time|
          next unless target_time <= time

          time_string = time.strftime('%Y-%m-%dT%H:%M:%S')
          target_index = sector_log.index(/[IDEW],\s\[#{time_string}/)
          return new_pos + target_index
        end
      elsif sector_time_first > target_time
        target_pos = new_pos - ((new_pos - current_pos).abs / 2)
      elsif sector_time_first < target_time
        target_pos = new_pos + ((new_pos - current_pos).abs / 2)
      end

      find_point(f, target_time, type, latency_time, new_pos, target_pos)
    end

    def asyncev_start_replicate_existing_data_process(args)
      # args is [$roma.cluster_replication_writer.replica_rttable])
      t = Thread.new do
        $roma.cluster_replication_writer.run_existing_data_replication = true
        replicate_existing_data_process(args)
      rescue StandardError => e
        @log.error("#{__method__}:#{e.inspect} #{$ERROR_POSITION}")
      ensure
        $roma.cluster_replication_writer.run_existing_data_replication = false
      end
      t[:name] = __method__
    end

    def replicate_existing_data_process(args)
      @log.info("#{__method__} :start.")

      @storages.each_key do |hash_name|
        @routing_table.routes.each_key do |vnode|
          raise unless $roma.cluster_replication_writer.run_existing_data_replication

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
  end # module AsyncEvent
end # module Roma
