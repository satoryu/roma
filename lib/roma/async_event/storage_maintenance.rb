module Roma
  module AsyncEvent
    # The processes that clean up, flush and clean the caches of the
    # storages.
    module StorageMaintenance
      private

      def asyncev_start_storage_clean_up_process(_args)
        #      @log.info("#{__method__}")
        if @stats.run_storage_clean_up
          @log.error("#{__method__}:already in being")
          return
        end
        @stats.run_storage_clean_up = true
        start_thread(__method__) do
          storage_clean_up_process
        ensure
          @stats.last_clean_up = Time.now
          @stats.run_storage_clean_up = false
        end
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
        start_thread(__method__) do
          st.flush_db(db_index)
          st.update_db_status(db_index, :safecopy_flushed)
          @log.info("#{__method__}:storage has flushed. (#{hash_name}, #{db_index})")
        end
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
        start_thread(__method__) do
          storage_cachecleaning_process(hash_name, db_index)
        end
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
    end
  end
end
