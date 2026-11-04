module Roma
  module Command
    module RoutingCommandReceiver
      # join <node id>
      def ev_join(s)
        @routing_table.add_node(s[1])
        send_data("ADDED\r\n")
      end

      # leave <node id>
      def ev_leave(s)
        @log.warn("receive a leave #{s[1]} message.")
        @routing_table.leave(s[1])
        send_data("DELETED\r\n")
      end

      def ev_nodelist(_s)
        send_data("#{@routing_table.nodes.join(' ')}\r\n")
      end

      def ev_create_nodes_from_v_idx(_s)
        @routing_table.create_nodes_from_routes
        send_data("CREATED\r\n")
      end

      # routingdump [yaml|json|yamlbytes|bin]\r\n
      def ev_routingdump(s)
        rt = @routing_table
        routing_data = @routing_table.substituted_routing_data(@addr)
        rt = Roma::Routing::RoutingTable.new(routing_data) if routing_data

        if s.length == 1
          dump = rt.dump
          send_data("#{dump.length}\r\n#{dump}\r\nEND\r\n")
        elsif s[1] == 'yaml'
          dump = rt.dump_yaml
          send_data("#{dump}\r\nEND\r\n")
        elsif s[1] == 'json'
          dump = rt.dump_json
          send_data("#{dump}\r\nEND\r\n")
        elsif s[1] == 'yamlbytes'
          dump = rt.dump_yaml
          send_data("#{dump.length + 7}\r\nEND\r\n")
        elsif s[1] == 'bin'
          dump = rt.dump_binary
          send_data("#{dump.length}\r\n#{dump}\r\nEND\r\n")
        else
          send_data("CLIENT_ERROR\r\n")
        end
      end

      def ev_enabled_repetition_in_routing?(s)
        rt = @routing_table
        routing_data = @routing_table.substituted_routing_data(@addr)
        rt = Roma::Routing::RoutingTable.new(routing_data) if routing_data

        if s.length == 1
          repetition = rt.check_repetition_in_routing
          send_data("#{repetition}\r\n")
        else
          send_data("CLIENT_ERROR\r\n")
        end
      end

      # setroute <vnode-id> <clock> <node-id> ...
      def ev_setroute(s)
        if s.length < 4
          send_data("CLIENT_ERROR\r\n")
        else
          node_ids = []
          s[3..-1].each { |node_id| node_ids << node_id }
          # check irregular node name
          node_ids.each do |node_id|
            if !node_id.ascii_only? || node_id.empty?
              send_data("CLIENT_ERROR : irregular node name was input.[\"#{node_id}\"]\r\n")
              return
            end
          end
          res = @routing_table.set_route(s[1].to_i, s[2].to_i, node_ids)
          if res.is_a?(Integer)
            send_data("STORED\r\n")
          else
            send_data("SERVER_ERROR #{res}\r\n")
          end
        end
      end

      # getroute <vnode-id>
      def ev_getroute(s)
        if s.length < 2
          send_data("CLIENT_ERROR\r\n")
          return
        end
        clock, node_ids = @routing_table.search_nodes_with_clk(s[1].to_i)
        if clock.nil?
          send_data("END\r\n")
          return
        end
        res = "#{clock - 1}"
        node_ids.each { |node_id| res << " #{node_id}" }
        send_data("#{res}\r\n")
      end

      # mklhash <id>
      def ev_mklhash(s)
        send_data("#{@routing_table.merkle_tree.get(s[1])}\r\n")
      end

      # history_of_lost [yyyymmddhhmmss]
      def ev_history_of_lost(s)
        t = if s.length == 2
              Time.mktime(s[1][0..3], s[1][4..5], s[1][6..7], s[1][8..9], s[1][10..11], s[1][12..13])
            else
              Time.mktime(2000, 1, 1, 0, 0, 0)
            end
        nodes = @routing_table.search_lost_vnodes(t)
        nodes.each { |vnode| send_data("#{vnode}\r\n") }
        send_data("END\r\n")
      rescue StandardError
        send_data("CLIENT_ERROR\r\n")
      end

      # set_auto_recover [true|false] <sec>
      def ev_set_auto_recover(s)
        # check argument
        if /^true$|^false$/ !~ s[1]
          return send_data("CLIENT_ERROR arguments must be true or false\r\n")
        elsif s.length != 2 && s.length != 3
          return send_data("CLIENT_ERROR number of arguments(0 for 1)\r\n")
        elsif s.length == 3 && s[2].to_i < 1
          return send_data("CLIENT_ERROR length must be greater than zero\r\n")
        end

        res = broadcast_cmd("rset_auto_recover #{s[1]} #{s[2]}\r\n")
        if s[1] == 'true'
          @routing_table.auto_recover = true
        elsif s[1] == 'false'
          @routing_table.auto_recover = false
        end
        @routing_table.auto_recover_status = 'waiting'
        @routing_table.auto_recover_time = s[2].to_i if s[2]
        res[@stats.my_node_id] = 'STORED'
        send_data("#{res}\r\n")
      end

      def ev_rset_auto_recover(s)
        if /^true$|^false$/ !~ s[1]
          return send_data("CLIENT_ERROR arguments must be true or false\r\n")
        elsif s.length != 2 && s.length != 3
          return send_data("CLIENT_ERROR number of arguments(0 for 1)\r\n")
        elsif s.length == 3 && s[2].to_i < 1
          return send_data("CLIENT_ERROR length must be greater than zero\r\n")
        end

        if s[1] == 'true'
          @routing_table.auto_recover = true
        elsif s[1] == 'false'
          @routing_table.auto_recover = false
        end
        @routing_table.auto_recover_status = 'waiting'
        @routing_table.auto_recover_time = s[2].to_i if s[2]
        send_data("STORED\r\n")
      end

      # set_lost_action [auto_assign|shutdown]
      def ev_set_lost_action(s)
        if s.length != 2 || /^auto_assign$|^shutdown$/ !~ s[1]
          return send_data("CLIENT_ERROR changing lost_action must be auto_assign or shutdown\r\n")
        elsif /^auto_assign$|^shutdown$/ !~ @routing_table.lost_action
          return send_data("CLIENT_ERROR can use this command only current lost action is auto_assign or shutdwn mode\r\n")
        end

        res = broadcast_cmd("rset_lost_action #{s[1]}\r\n")
        @routing_table.lost_action = s[1].to_sym
        res[@stats.my_node_id] = 'STORED'
        send_data("#{res}\r\n")
      end

      def ev_rset_lost_action(s)
        if s.length != 2 || /^auto_assign$|^shutdown$/ !~ s[1]
          return send_data("CLIENT_ERROR changing lost_action must be auto_assign or shutdown\r\n")
        elsif /^auto_assign$|^shutdown$/ !~ @routing_table.lost_action
          return send_data("CLIENT_ERROR can use this command only current lost action is auto_assign or shutdwn mode\r\n")
        end

        @routing_table.lost_action = s[1].to_sym
        send_data("STORED\r\n")
      end

      # set_threshold_for_failover <n>
      def ev_set_threshold_for_failover(s)
        return send_data("usage:set_threshold_for_failover <n>\r\n") if s.length != 2 || s[1].to_i == 0

        res = broadcast_cmd("rset_threshold_for_failover #{s[1]}\r\n")
        @routing_table.failure_count_threshold = s[1].to_i
        res[@stats.my_node_id] = 'STORED'
        send_data("#{res}\r\n")
      end

      # rset_threshold_for_failover <n>
      def ev_rset_threshold_for_failover(s)
        return send_data("usage:rset_threshold_for_failover <n>\r\n") if s.length != 2 || s[1].to_i == 0

        @routing_table.failure_count_threshold = s[1].to_i
        send_data("STORED\r\n")
      end

      # set_gap_for_failover
      def ev_set_gap_for_failover(s)
        return send_data("usage:set_gap_for_failover <n>\r\n") if s.length != 2

        res = broadcast_cmd("rset_gap_for_failover #{s[1]}\r\n")
        @routing_table.failure_count_gap = s[1].to_f
        res[@stats.my_node_id] = 'STORED'
        send_data("#{res}\r\n")
      end

      # rset_gap_for_failover
      def ev_rset_gap_for_failover(s)
        return send_data("usage:rset_gap_for_failover <n>\r\n") if s.length != 2

        @routing_table.failure_count_gap = s[1].to_f
        send_data("STORED\r\n")
      end

      # cleat RTTABLE_SUB_NID map
      def ev_clear_rttable_sub_nid(_s)
        res = broadcast_cmd("rclear_rttable_sub_nid\r\n")
        @routing_table.node_id_substitutions.clear
        res[@stats.my_node_id] = 'CLEARED'
        send_data("#{res}\r\n")
      end

      def ev_rclear_rttable_sub_nid(_s)
        @routing_table.node_id_substitutions.clear
        send_data("CLEARED\r\n")
      end

      # add_rttable_sub_nid <netmask> <regexp> <replace>
      def ev_add_rttable_sub_nid(s)
        return send_data("usage:add_rttable_sub_nid <netmask> <regexp> <replace>\r\n") if s.length != 4

        res = broadcast_cmd("radd_rttable_sub_nid #{s[1]} #{s[2]} #{s[3]}\r\n")
        @routing_table.node_id_substitutions[s[1]] = { regexp: "#{s[2]}", replace: "#{s[3]}" }
        res[@stats.my_node_id] = 'ADDED'
        send_data("#{res}\r\n")
      end

      # radd_rttable_sub_nid <netmask> <regexp> <replace>
      def ev_radd_rttable_sub_nid(s)
        return send_data("usage:add_rttable_sub_nid <netmask> <regexp> <replace>\r\n") if s.length != 4

        @routing_table.node_id_substitutions[s[1]] = { regexp: "#{s[2]}", replace: "#{s[3]}" }
        send_data("ADDED\r\n")
      end

      # delete_rttable_sub_nid <netmask>
      def ev_delete_rttable_sub_nid(s)
        return send_data("usage:delete_rttable_sub_nid <netmask>\r\n") if s.length != 2

        res = broadcast_cmd("rdelete_rttable_sub_nid #{s[1]}\r\n")
        res[@stats.my_node_id] = if @routing_table.node_id_substitutions.delete s[1]
                                   'DELETED'
                                 else
                                   'NOT_FOUND'
                                 end
        send_data("#{res}\r\n")
      end

      # rdelete_rttable_sub_nid <netmask>
      def ev_rdelete_rttable_sub_nid(s)
        return send_data("usage:delete_rttable_sub_nid <netmask>\r\n") if s.length != 2

        if @routing_table.node_id_substitutions.delete s[1]
          send_data("DELETED\r\n")
        else
          send_data("NOT_FOUND\r\n")
        end
      end

      # get_key_info <key>
      def ev_get_key_info(s)
        return send_data("CLIENT_ERROR number of arguments(0 for 1)\r\n") if s.length != 2

        d = Digest::SHA1.hexdigest(s[1]).hex % @routing_table.hash_space_size
        vnode = @routing_table.get_vnode_id(d)
        nodes = @routing_table.search_nodes_for_write(vnode)
        send_data(format("d = %s 0x%x\r\n", d, d))
        send_data(format("vn = %s 0x%x\r\n", vnode, vnode))
        send_data("nodes = #{nodes.inspect}\r\n")
        send_data("END\r\n")
      end
    end # module RoutingCommandReceiver
  end # module Command
end # module Roma
