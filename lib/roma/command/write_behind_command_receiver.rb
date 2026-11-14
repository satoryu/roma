require 'timeout'
require 'roma/async_event'

module Roma
  module Command
    # The commands of write-behind and of the cluster replication.
    # SystemCommandReceiver includes it, so that they are system commands.
    module WriteBehindCommandReceiver
      # writebehind_rotate [hash_name]
      def ev_writebehind_rotate(s)
        return send_data("CLIENT_ERROR number of arguments (0 for 1)\r\n") if s.length < 2

        res = broadcast_cmd("rwritebehind_rotate #{s[1]}\r\n")

        res[@stats.my_node_id] = if $roma.wb_writer.rotate(s[1])
                                   'ROTATED'
                                 else
                                   'NOT_OPEND'
                                 end
        send_data("#{res}\r\n")
      end

      # rwritebehind_rotate [hash_name]
      def ev_rwritebehind_rotate(s)
        return send_data("CLIENT_ERROR number of arguments (0 for 1)\r\n") if s.length < 2

        if $roma.wb_writer.rotate(s[1])
          send_data("ROTATED\r\n")
        else
          send_data("NOT_OPEND\r\n")
        end
      end

      # writebehind_get_path [hash_name]
      def ev_writebehind_get_path(s)
        return send_data("CLIENT_ERROR number of arguments (0 for 1)\r\n") if s.length < 2

        res = broadcast_cmd("rwritebehind_get_path #{s[1]}\r\n")

        ret = $roma.wb_writer.path(s[1])
        res[@stats.my_node_id] = ret

        send_data("#{res}\r\n")
      end

      # rwritebehind_get_path [hash_name]
      def ev_rwritebehind_get_path(s)
        return send_data("CLIENT_ERROR number of arguments (0 for 1)\r\n") if s.length < 2

        ret = $roma.wb_writer.path(s[1])
        send_data("#{ret}\r\n")
      end

      # writebehind_get_current_file [hash_name]
      def ev_writebehind_get_current_file(s)
        return send_data("CLIENT_ERROR number of arguments (0 for 1)\r\n") if s.length < 2

        res = broadcast_cmd("rwritebehind_get_current_file #{s[1]}\r\n")

        ret = $roma.wb_writer.current_file_path(s[1])
        res[@stats.my_node_id] = (ret || 'NOT_OPEND')
        send_data("#{res}\r\n")
      end

      # rwritebehind_get_current_file [hash_name]
      def ev_rwritebehind_get_current_file(s)
        return send_data("CLIENT_ERROR number of arguments (0 for 1)\r\n") if s.length < 2

        ret = $roma.wb_writer.current_file_path(s[1])
        if ret
          send_data("#{ret}\r\n")
        else
          send_data("NOT_OPEND\r\n")
        end
      end

      # switch_replication command is change status of cluster replication
      # if you want to activate, assign 1 node_id(addr_port) of replication cluster as argument.
      # if you want to copy existing data, add the 'all' after node_id as argument
      # switch_replication <true|false> [node_id] [copy target]
      def ev_switch_replication(s)
        error = switch_replication_error(s)
        return send_data(error) if error

        res = broadcast_cmd("rswitch_replication #{s[1]} #{s[2]} #{s[3]}\r\n")
        res[@stats.my_node_id] = switch_replication(s)
        send_data("#{res}\r\n")
      rescue StandardError => e
        send_data("#{e.class}: #{e}\r\n")
      end

      # rswitch_replication <true|false> [node_id] [copy target]
      def ev_rswitch_replication(s)
        error = switch_replication_error(s)
        return send_data(error) if error

        send_data("#{switch_replication(s)}\r\n")
      rescue StandardError => e
        send_data("#{e.class}: #{e}\r\n")
      end

      # wb_command_map <hash string>
      # ex.
      # {:set=>1,:append=>2,:delete=>3}
      def ev_wb_command_map(s)
        return send_data("CLIENT_ERROR number of arguments\r\n") if s.length < 2

        map = {}
        cmd = s[1..-1].join
        if cmd =~ /^\{(.+)\}$/
          ::Regexp.last_match(1).split(',').each do |kv|
            k, v = kv.split('=>')
            map[k[1..-1].to_sym] = v.to_i if v && k[0] == ':'
          end

          res = broadcast_cmd("rwb_command_map #{s[1..-1].join}\r\n")
          @stats.wb_command_map = map
          res[@stats.my_node_id] = map.inspect
          send_data("#{res}\r\n")
        else
          send_data("CLIENT_ERROR hash string parse error\r\n")
        end
      end

      def ev_rwb_command_map(s)
        return send_data("CLIENT_ERROR number of arguments\r\n") if s.length < 2

        map = {}
        cmd = s[1..-1].join
        if cmd =~ /^\{(.+)\}$/
          ::Regexp.last_match(1).split(',').each do |kv|
            k, v = kv.split('=>')
            map[k[1..-1].to_sym] = v.to_i if v && k[0] == ':'
          end
          @stats.wb_command_map = map
          send_data("#{map}\r\n")
        else
          send_data("CLIENT_ERROR hash string parse error\r\n")
        end
      end

      private

      def switch_replication_error(s)
        if !s.length.between?(2, 4)
          "CLIENT_ERROR number of arguments\r\n"
        elsif s[1] !~ /^(true|false)$/
          "CLIENT_ERROR value must be true or false\r\n"
        elsif s[3] && s[3] != 'all'
          "CLIENT_ERROR [copy target] must be all or nil\r\n"
        end
      end

      # Switches the cluster replication of this node by switch_replication,
      # and returns the reply.
      def switch_replication(s)
        writer = $roma.cluster_replication_writer
        Timeout.timeout(1) do
          if s[1] == 'true'
            writer.activate(s[2], existing_data: s[3] == 'all')
            if s[3] == 'all'
              Roma::AsyncEvent.queue.push(Roma::AsyncMessage.new('start_replicate_existing_data_process',
                                                                 [writer.replica_rttable]))
            end
            'ACTIVATED'
          else
            writer.deactivate
            'DEACTIVATED'
          end
        end
      end
    end
  end
end
