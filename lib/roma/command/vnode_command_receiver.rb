require 'roma/messaging/connection_pool'
require 'roma/async_event'
require 'roma/configuration'

module Roma
  module Command
    module VnodeCommandReceiver
      # spushv_protection <true/false>
      def ev_spushv_protection(s)
        if s.length == 1
          send_data("#{@stats.spushv_protection}\r\n")
        elsif s.length == 2
          @stats.spushv_protection = (s[1] == 'true')
          send_data("#{@stats.spushv_protection}\r\n")
        else
          send_data("COMMAND ERROR\r\n")
        end
      end

      # spushv <hash-name> <vnode-id>
      # src                             dst
      #  |  ['spushv' <hash_name> <vnode>\r\n]->|
      #  |<-['READY'\r\n]                |
      #  |                 [<dumpdata>]->|
      #  |                       :       |
      #  |                       :       |
      #  |              [<end of dump>]->|
      #  |<-['STORED'\r\n]               |
      def ev_spushv(s)
        if s.length != 3
          @log.error("#{__method__}:wrong number of arguments(#{s})")
          return send_data("CLIENT_ERROR Wrong number of arguments.\r\n")
        end
        if @stats.spushv_protection
          @log.info("#{__method__}:In spushv_protection")
          return send_data("SERVER_ERROR In spushv_protection.\r\n")
        end
        @stats.run_receive_a_vnode["#{s[1]}_#{s[2]}"] = true

        $roma.stop_clean_up

        send_data("READY\r\n")

        count = rcount = 0
        @log.debug("#{__method__}:#{s.inspect} received.")
        loop do
          context_bin = read_bytes(20, @stats.spushv_read_timeout)
          vnode, last, clock, expire_time, klen = context_bin.unpack('NNNNN')
          break if klen == 0 # end of dump ?

          k = read_bytes(klen)
          vlen_bin = read_bytes(4, @stats.spushv_read_timeout)
          vlen, =  vlen_bin.unpack('N')
          if vlen == 0
            createhash(s[1], 'CREATED') unless @storages[s[1]]
            if @storages[s[1]].load_stream_dump(vnode, last, clock, expire_time, k, nil)
              #              @log.debug("#{__method__}:[#{vnode} #{last} #{clock} #{expire_time} #{k}] was stored.")
              count += 1
            else
              rcount += 1
              #              @log.warn("#{__method__}:[#{vnode} #{last} #{clock} #{expire_time} #{k}] was rejected.")
            end
          else
            @log.warn("#{__method__}:Too long key: key = #{k}") if klen > @stats.spushv_klength_warn
            @log.warn("#{__method__}:Too long value: key = #{k} vlen = #{vlen}") if vlen > @stats.spushv_vlength_warn
            v = read_bytes(vlen, @stats.spushv_read_timeout)

            createhash(s[1], 'CREATED') unless @storages[s[1]]
            if @storages[s[1]].load_stream_dump(vnode, last, clock, expire_time, k, v)
              count += 1
            #              @log.debug("#{__method__}:[#{vnode} #{last} #{clock} #{expire_time} #{k}] was stored.")
            else
              rcount += 1
              #              @log.warn("#{__method__}:[#{vnode} #{last} #{clock} #{expire_time} #{k}] was rejected.")
            end
          end
        end
        if @stats.spushv_protection
          @log.info("#{__method__}:Canceled because of spushv_protection")
          send_data("CANCELED\r\n")
        else
          send_data("STORED\r\n")
        end
        @log.debug("#{__method__}:#{s[1]}_#{s[2]} #{count} keys loaded.")
        @log.debug("#{__method__}:#{s[1]}_#{s[2]} #{rcount} keys rejected.") if rcount > 0
      rescue Storage::StorageException => e
        @log.error("#{e.inspect} #{$@}")
        close_connection
        if Roma.config.storage.exception_action == :shutdown
          @log.error("#{__method__}:The server will stop.")
          @stop_event_loop = true
        end
      rescue StandardError => e
        @log.error("#{e} #{$@}")
      ensure
        @stats.run_receive_a_vnode.delete("#{s[1]}_#{s[2]}") if s.length == 3
        @stats.last_clean_up = Time.now
      end

      # reqpushv <vnode-id> <node-id> <is primary?>
      # src                                       dst
      #  |<-['reqpushv <vnode> <node_id> <p?>\r\n']         |
      #  |                           ['PUSHED'\r\n]->|
      def ev_reqpushv(s)
        if s.length != 4
          send_data("CLIENT_ERROR usage:reqpushv vnode-id node-id primary-flag(true/false)\r\n")
          return
        end
        if @stats.run_iterate_storage || @stats.run_join || @stats.run_balance
          @log.warn("reqpushv rejected:#{s}")
          send_data("REJECTED\r\n")
          return
        end
        Roma::AsyncEvent.queue.push(Roma::AsyncMessage.new('reqpushv', [s[1], s[2], s[3]]))
        send_data("PUSHED\r\n")
      rescue StandardError => e
        @log.error("#{e}\n#{$@}")
      end
    end
  end
end
