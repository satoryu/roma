require 'roma/async_event'
require 'roma/configuration'

module Roma
  module Command
    module SystemCommandReceiver
      # Defines set_<name>, which changes a setting of every node to a value,
      # and rset_<name>, which the other nodes run for it. +check+ returns
      # what is wrong with the value, or nil, and the block changes the
      # setting of this node. They reply +reply+, set_<name> for each node.
      def self.def_setting_command(name, check = nil, reply: 'STORED', &)
        define_method(:"ev_set_#{name}") do |s|
          error = setting_error(s, check)
          return send_data("CLIENT_ERROR #{error}\r\n") if error

          res = broadcast_cmd("rset_#{name} #{s[1]}\r\n")
          instance_exec(s[1], &)
          res[@stats.my_node_id] = reply
          send_data("#{res}\r\n")
        end

        define_method(:"ev_rset_#{name}") do |s|
          error = setting_error(s, check)
          return send_data("CLIENT_ERROR #{error}\r\n") if error

          instance_exec(s[1], &)
          send_data("#{reply}\r\n")
        end
      end

      # Checks of the values of settings, which return what is wrong.
      POSITIVE_LENGTH = ->(v) { 'length must be greater than zero' if v.to_i < 1 }
      POSITIVE_TIME = ->(v) { 'time value must be lager than 0' if v.to_f <= 0 }
      POSITIVE_INTEGER_TIME = ->(v) { 'time value must be lager than 0' if v.to_i <= 0 }
      POSITIVE_SIZE = ->(v) { 'size value must be larger than 0' if v.to_i <= 0 }
      LOG_SHIFT_AGE = lambda do |v|
        'invalid arguments' if v.to_i < 1 && !%w(0 min hour daily weekly monthly).include?(v)
      end

      # balse [reason]
      def ev_balse(s)
        send_data("Are you sure?(yes/no)\r\n")
        if gets != "yes\r\n"
          close_connection_after_writing
          return
        end

        if s.length == 2
          @log.info("Receive a balse #{s[1]}")
        else
          @log.info('Receive a balse command.')
        end
        @routing_table.enabled_failover = false
        res = broadcast_cmd("rbalse\r\n")
        res[@stats.my_node_id] = 'BYE'
        send_data("#{res.inspect}\r\n")
        close_connection_after_writing
        @stop_event_loop = true
      end

      # rbalse [reason]
      def ev_rbalse(s)
        if s.length == 2
          @log.info("Receive a rbalse #{s[1]}")
        else
          @log.info('Receive a rbalse command.')
        end
        @routing_table.enabled_failover = false
        send_data("BYE\r\n")
        close_connection_after_writing
        @stop_event_loop = true
      end

      # shutdown [reason]
      def ev_shutdown(s)
        send_data("*** ARE YOU REALLY SURE TO SHUTDOWN? *** (yes/no)\r\n")
        if gets != "yes\r\n"
          close_connection_after_writing
          return
        end

        if s.length == 2
          @log.info("Receive a shutdown #{s[1]}")
        else
          @log.info('Receive a shutdown command.')
        end
        @routing_table.enabled_failover = false
        res = broadcast_cmd("rshutdown\r\n")
        res[@stats.my_node_id] = 'BYE'
        send_data("#{res.inspect}\r\n")
        close_connection_after_writing
        @stop_event_loop = true
      end

      # rshutdown [reason]
      def ev_rshutdown(s)
        if s.length == 2
          @log.info("Receive a rshutdown #{s[1]}")
        else
          @log.info('Receive a rshutdown command.')
        end
        @routing_table.enabled_failover = false
        send_data("BYE\r\n")
        close_connection_after_writing
        @stop_event_loop = true
      end

      # shutdown_self
      def ev_shutdown_self(s)
        if s.length == 1
          send_data("\r\n=================================================================\r\n")
          send_data("CAUTION!!: \r\n\tThis command kill the instance!\r\n\tThere is some possibility of occuring redundancy down!\r\n")
          send_data("=================================================================\r\n")
          send_data("\r\nAre you sure to shutdown this instance?(yes/no)\r\n")
          if gets != "yes\r\n"
            close_connection_after_writing
            return
          end
          @log.info('Receive a shutdown_self command.')
          @routing_table.enabled_failover = false
          send_data("BYE\r\n")
          @stop_event_loop = true
          close_connection_after_writing
        else
          send_data("ERROR: shutdown_instance has irregular argument.\r\n")
        end
      end

      # version
      def ev_version(_s)
        send_data("VERSION ROMA-#{Roma::VERSION}\r\n")
      end

      # quit
      def ev_quit(_s)
        close_connection
      end

      def ev_whoami(_s)
        send_data("#{@stats.name}\r\n")
      end

      # stats [regexp]
      def ev_stats(s) = ev_stat(s)

      # stat [regexp]
      def ev_stat(s)
        regexp = s[1] if s.length == 2
        h = {}
        h['version'] = Roma::VERSION
        send_stat_result(nil, h, regexp)
        send_stat_result(nil, config_stat, regexp)
        send_stat_result(nil, @stats.stat, regexp)
        @storages.each do |hash_name, st|
          send_stat_result("storages[#{hash_name}].", storage_stat(st), regexp)
        end
        send_stat_result(nil, $roma.write_behind_stat, regexp)
        send_stat_result(nil, @routing_table.stat(@stats.my_node_id), regexp)
        send_stat_result(nil, connection_stat, regexp)
        send_stat_result(nil, DNSCache.instance.stat, regexp)
        send_data("END\r\n")
      end

      def send_stat_result(prefix, h, regexp = nil)
        h.each do |k, v|
          key = if prefix
                  "#{prefix}#{k}"
                else
                  "#{k}"
                end
          if regexp
            send_data("#{key} #{v}\r\n") if key =~ /#{regexp}/
          else
            send_data("#{key} #{v}\r\n")
          end
        end
      end
      private :send_stat_result

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
        return send_data("CLIENT_ERROR number of arguments\r\n") unless s.length.between?(2, 4)
        return send_data("CLIENT_ERROR value must be true or false\r\n") unless s[1] =~ /^(true|false)$/
        return send_data("CLIENT_ERROR [copy target] must be all or nil\r\n") if s[3] && s[3] != 'all'

        res = broadcast_cmd("rswitch_replication #{s[1]} #{s[2]} #{s[3]}\r\n")

        Timeout.timeout(1) do
          case s[1]
          when 'true'
            $roma.cluster_replication_writer.update_mklhash(s[2])
            $roma.cluster_replication_writer.update_nodelist(s[2])
            $roma.cluster_replication_writer.update_rttable(s[2])
            $roma.cluster_replication_writer.run_replication = true
            if s[3] == 'all'
              $roma.cluster_replication_writer.run_existing_data_replication = true
              Roma::AsyncEvent.queue.push(Roma::AsyncMessage.new('start_replicate_existing_data_process',
                                                                 [$roma.cluster_replication_writer.replica_rttable]))
            end
            res[@stats.my_node_id] = 'ACTIVATED'
          when 'false'
            $roma.cluster_replication_writer.replica_mklhash = nil
            $roma.cluster_replication_writer.replica_nodelist = []
            $roma.cluster_replication_writer.replica_rttable = nil
            $roma.cluster_replication_writer.run_replication = false
            $roma.cluster_replication_writer.run_existing_data_replication = false
            res[@stats.my_node_id] = 'DEACTIVATED'
          end
        end
        send_data("#{res}\r\n")
      rescue StandardError => e
        send_data("#{e.class}: #{e}\r\n")
      end

      # rswitch_replication <true|false> [node_id] [copy target]
      def ev_rswitch_replication(s)
        return send_data("CLIENT_ERROR number of arguments\r\n") unless s.length.between?(2, 4)
        return send_data("CLIENT_ERROR value must be true or false\r\n") unless s[1] =~ /^(true|false)$/
        return send_data("CLIENT_ERROR [copy target] must be all or nil\r\n") if s[3] && s[3] != 'all'

        Timeout.timeout(1) do
          case s[1]
          when 'true'
            $roma.cluster_replication_writer.update_mklhash(s[2])
            $roma.cluster_replication_writer.update_nodelist(s[2])
            $roma.cluster_replication_writer.update_rttable(s[2])
            $roma.cluster_replication_writer.run_replication = true
            if s[3] == 'all'
              $roma.cluster_replication_writer.run_existing_data_replication = true
              Roma::AsyncEvent.queue.push(Roma::AsyncMessage.new('start_replicate_existing_data_process',
                                                                 [$roma.cluster_replication_writer.replica_rttable]))
            end
            send_data("ACTIVATED\r\n")
          when 'false'
            $roma.cluster_replication_writer.replica_mklhash = nil
            $roma.cluster_replication_writer.replica_nodelist = []
            $roma.cluster_replication_writer.replica_rttable = nil
            $roma.cluster_replication_writer.run_replication = false
            $roma.cluster_replication_writer.run_existing_data_replication = false
            send_data("DEACTIVATED\r\n")
          end
        end
      rescue StandardError => e
        send_data("#{e.class}: #{e}\r\n")
      end

      # dcnice command is setting priority for a data-copy thread.
      # a niceness of 1 is the highest priority and 5 is the lowest priority.
      # dcnice <priority:1 to 5>
      def ev_dcnice(s)
        return send_data("CLIENT_ERROR number of arguments (0 for 1)\r\n") if s.length < 2

        res = broadcast_cmd("rdcnice #{s[1]}\r\n")
        res[@stats.my_node_id] = dcnice(s[1].to_i)
        send_data("#{res}\r\n")
      end

      def ev_rdcnice(s)
        return send_data("CLIENT_ERROR number of arguments (0 for 1)\r\n") if s.length < 2

        send_data("#{dcnice(s[1].to_i)}\r\n")
      end

      def ev_restart(_s)
        res = broadcast_cmd("rrestart\r\n")
        $roma.eventloop = true
        @routing_table.enabled_failover = false
        Messaging::ConnectionPool.instance.close_all
        Event::EMConnectionPool.instance.close_all
        EventMachine.stop_event_loop
        res[@stats.my_node_id] = 'RESTARTED'
        send_data("#{res}\r\n")
      end

      def ev_rrestart(_s)
        $roma.eventloop = true
        @routing_table.enabled_failover = false
        Messaging::ConnectionPool.instance.close_all
        Event::EMConnectionPool.instance.close_all
        EventMachine.stop_event_loop
        send_data("RESTARTED\r\n")
      end

      # set_log_level [ 'debug' | 'info' | 'warn' | 'error' ]
      def ev_set_log_level(s)
        return send_data("CLIENT_ERROR number of arguments (0 for 1)\r\n") if s.length < 2

        case s[1].downcase
        when 'debug'
          @log.level = Roma::Logging::RLogger::Severity::DEBUG
        when 'info'
          @log.level = Roma::Logging::RLogger::Severity::INFO
        when 'warn'
          @log.level = Roma::Logging::RLogger::Severity::WARN
        when 'error'
          @log.level = Roma::Logging::RLogger::Severity::ERROR
        else
          return send_data("CLIENT_ERROR no match log-level string\r\n")
        end

        @stats.log_level = s[1].downcase

        send_data("STORED\r\n")
      end

      # out <key> <vnode>
      def ev_out(s)
        key, hash_name = s[1].split("\e")
        hash_name ||= @default_hash_name
        if s.length >= 3
          vnode = s[2].to_i
        else
          d = @routing_table.digest(key)
          vnode = @routing_table.vnode_id(d)
        end
        res = @storages[hash_name].out(vnode, key, 0)
        @stats.out_message_count += 1
        return send_data("NOT_DELETED\r\n") unless res

        send_data("DELETED\r\n")
      end

      # rset <key> <hash value> <timelimit> <length>
      # "set" means "store this data".
      # <command name> <key> <digest> <exptime> <bytes> [noreply]\r\n
      # <data block>\r\n
      def ev_rset(s)
        key, hash_name = s[1].split("\e")
        hash_name ||= @default_hash_name
        d = s[2].to_i
        d = @routing_table.digest(key) if d == 0
        data = read_value(s[5].to_i)
        vnode = @routing_table.vnode_id(d)
        unless @storages.key?(hash_name)
          send_data("SERVER_ERROR #{hash_name} does not exists.\r\n")
          return
        end
        if @storages[hash_name].rset(vnode, key, d, s[3].to_i, s[4].to_i, data)
          send_data("STORED\r\n")
        else
          @log.error("rset NOT_STORED:#{@storages[hash_name].error_message} #{vnode} #{s[1]} #{d} #{s[3]} #{s[4]}")
          send_data("NOT_STORED\r\n")
        end
        @stats.redundant_count += 1
      end

      # <command name> <key> <digest> <exptime> <bytes> [noreply]\r\n
      # <compressed data block>\r\n
      def ev_rzset(s)
        key, hash_name = s[1].split("\e")
        hash_name ||= @default_hash_name
        d = s[2].to_i
        d = @routing_table.digest(key) if d == 0
        zdata = read_value(s[5].to_i)
        vnode = @routing_table.vnode_id(d)
        unless @storages.key?(hash_name)
          send_data("SERVER_ERROR #{hash_name} does not exists.\r\n")
          return
        end

        data = Zlib::Inflate.inflate(zdata)
        # @log.debug("data = #{data}")
        if @storages[hash_name].rset(vnode, key, d, s[3].to_i, s[4].to_i, data)
          send_data("STORED\r\n")
        else
          @log.error("rzset NOT_STORED:#{@storages[hash_name].error_message} #{vnode} #{s[1]} #{d} #{s[3]} #{s[4]}")
          send_data("NOT_STORED\r\n")
        end
        @stats.redundant_count += 1
      rescue Zlib::DataError => e
        @log.error("rzset NOT_STORED:#{e} #{vnode} #{s[1]} #{d} #{s[3]} #{s[4]}")
        send_data("NOT_STORED\r\n")
      end

      def ev_forcedly_start(_s)
        @log.info('ROMA forcedly start.')
        AsyncEvent.queue.clear
        @routing_table.enabled_failover = true
        Command::Receiver.make_event_list
        $roma.startup = false
        send_data("STARTED\r\n")
      end

      # switch_failover <on|off>
      def ev_switch_failover(s)
        return send_data("CLIENT_ERROR number of arguments\r\n") if s.length != 2

        res = broadcast_cmd("rswitch_failover #{s[1]}\r\n")
        if s[1] == 'on'
          Messaging::ConnectionPool.instance.close_all
          Event::EMConnectionPool.instance.close_all
          @routing_table.enabled_failover = true
          @log.info('failover enabled')
          res[@stats.my_node_id] = 'ENABLED'
        elsif s[1] == 'off'
          @routing_table.enabled_failover = false
          @log.info('failover disabled')
          res[@stats.my_node_id] = 'DISABLED'
        else
          res[@stats.my_node_id] = 'NOTSWITCHED'
        end
        send_data("#{res}\r\n")
      end

      # rswitch_failover <on|off>
      def ev_rswitch_failover(s)
        return send_data("CLIENT_ERROR number of arguments\r\n") if s.length != 2

        if s[1] == 'on'
          Messaging::ConnectionPool.instance.close_all
          Event::EMConnectionPool.instance.close_all
          @routing_table.enabled_failover = true
          @log.info('failover enabled')
          send_data("ENABLED\r\n")
        elsif s[1] == 'off'
          @routing_table.enabled_failover = false
          @log.info('failover disabled')
          send_data("DISABLED\r\n")
        else
          send_data("NOTSWITCHED\r\n")
        end
      end

      # set_descriptor_table_size <size>
      def_setting_command :descriptor_table_size, ->(v) { 'length must be greater than 1024' if v.to_i < 1024 } do |v|
        EM.set_descriptor_table_size(v.to_i)
      end

      # set_latency_avg_calc_rule <mode> <count> <command1> <command2>....
      # <mode> is on/off
      # <count> is denominator to calculate average.
      # <commandx> is target command
      def ev_set_latency_avg_calc_rule(s)
        # check argument
        if /^on$|^off$/ !~ s[1]
          return send_data("CLIENT_ERROR argument 1: please input \"on\" or \"off\"\r\n")
        elsif s[1] == 'on' && (s.length <= 3 || s[2].to_i < 1)
          return send_data("CLIENT_ERROR number of arguments (0 for 3) and <count> must be greater than zero\r\n")
        elsif s[1] == 'off' && !(s.length == 2)
          return send_data("CLIENT_ERROR number of arguments (0 for 1, or more 3)\r\n")
        end

        # check support commands
        s.each_index do |idx|
          if idx >= 3 && (!Event::Handler.event_list.include?(s[idx]) || Event::Handler.system_commands.include?(s[idx]))
            return send_data("NOT SUPPORT [#{s[idx]}] command\r\n")
          end
        end

        arg = 'rset_latency_avg_calc_rule'
        s.each_index do |idx|
          arg += " #{s[idx]}" if idx >= 1
        end
        res = broadcast_cmd("#{arg}\r\n")

        if s[1] == 'on'
          @stats.latency_check_cmd = [] # reset
          s.each_index do |idx|
            @stats.latency_check_cmd.push(s[idx]) if idx >= 3
          end
          @stats.latency_check_time_count = s[2].to_i
          @stats.latency_log = true
          res[@stats.my_node_id] = 'ACTIVATED'
        elsif s[1] == 'off'
          @stats.latency_check_cmd = [] # reset
          @stats.latency_check_time_count = false
          @stats.latency_log = false
          res[@stats.my_node_id] = 'DEACTIVATED'
        end
        @stats.latency_data = Hash.new { |hash, key| hash[key] = {} }
        send_data("#{res}\r\n")
      end

      def ev_rset_latency_avg_calc_rule(s)
        if /^on$|^off$/ !~ s[1]
          return send_data("CLIENT_ERROR argument 1: please input \"on\" or \"off\"\r\n")
        elsif s[1] == 'on' && (s.length <= 3 || s[2].to_i < 1)
          return send_data("CLIENT_ERROR number of arguments (0 for 3) and <count> must be greater than zero\r\n")
        elsif s[1] == 'off' && !(s.length == 2)
          return send_data("CLIENT_ERROR number of arguments (0 for 1, or more 3)\r\n")
        end

        s.each_index do |idx|
          if idx >= 3 && (!Event::Handler.event_list.include?(s[idx]) || Event::Handler.system_commands.include?(s[idx]))
            return send_data("NOT SUPPORT [#{s[idx]}] command\r\n")
          end
        end

        if s[1] == 'on'
          @latency_data = Hash.new { |hash, key| hash[key] = {} }
          @stats.latency_check_cmd = []
          s.each_index do |idx|
            @stats.latency_check_cmd.push(s[idx]) if idx >= 3
          end
          @stats.latency_check_time_count = s[2].to_i
          @stats.latency_log = true
          send_data("ACTIVATED\r\n")
        elsif s[1] == 'off'
          @latency_data = Hash.new { |hash, key| hash[key] = {} }
          @stats.latency_check_cmd = []
          @stats.latency_check_time_count = false
          @stats.latency_log = false
          send_data("DEACTIVATED\r\n")
        end
      end

      # add_calc_latency_average <command1> <command2>....
      def ev_add_latency_avg_calc_cmd(s)
        # check argument
        return send_data("CLIENT_ERROR number of arguments (0 for 2)\r\n") if s.length < 2

        # check support commands
        s.each_index do |idx|
          if idx >= 1 && (!Event::Handler.event_list.include?(s[idx]) || Event::Handler.system_commands.include?(s[idx]))
            return send_data("NOT SUPPORT [#{s[idx]}] command\r\n")
          end
          if idx >= 1 && @stats.latency_check_cmd.include?(s[idx])
            return send_data("ALREADY SET [#{s[idx]}] command\r\n")
          end
        end

        arg = 'radd_latency_avg_calc_cmd'
        s.each_index do |idx|
          arg += " #{s[idx]}" if idx >= 1
        end
        res = broadcast_cmd("#{arg}\r\n")

        s.each_index do |idx|
          @stats.latency_check_cmd.push(s[idx]) if idx >= 1
        end
        res[@stats.my_node_id] = 'SET'
        send_data("#{res}\r\n")
      end

      def ev_radd_latency_avg_calc_cmd(s)
        return send_data("CLIENT_ERROR number of arguments (0 for 2)\r\n") if s.length < 2

        s.each_index do |idx|
          if idx >= 1 && (!Event::Handler.event_list.include?(s[idx]) || Event::Handler.system_commands.include?(s[idx]))
            return send_data("NOT SUPPORT [#{s[idx]}] command\r\n")
          end
          if idx >= 1 && @stats.latency_check_cmd.include?(s[idx])
            return send_data("ALREADY SET [#{s[idx]}] command\r\n")
          end
        end

        s.each_index do |idx|
          @stats.latency_check_cmd.push(s[idx]) if idx >= 1
        end
        send_data("SET\r\n")
      end

      # del_calc_latency_average <command1> <command2>....
      def ev_del_latency_avg_calc_cmd(s)
        # check argument
        return send_data("CLIENT_ERROR number of arguments (0 for 2)\r\n") if s.length < 2

        # check support commands
        s.each_index do |idx|
          if idx >= 1 && !@stats.latency_check_cmd.include?(s[idx])
            return send_data("[#{s[idx]}] command is NOT set\r\n")
          end
        end

        arg = 'rdel_latency_avg_calc_cmd'
        s.each_index do |idx|
          arg += " #{s[idx]}" if idx >= 1
        end
        res = broadcast_cmd("#{arg}\r\n")

        s.each_index do |idx|
          @stats.latency_check_cmd.delete(s[idx]) if idx >= 1
          @stats.latency_data.delete(s[idx]) if idx >= 1
        end
        res[@stats.my_node_id] = 'DELETED'
        send_data("#{res}\r\n")
      end

      def ev_rdel_latency_avg_calc_cmd(s)
        return send_data("CLIENT_ERROR number of arguments (0 for 2)\r\n") if s.length < 2

        # reset
        s.each_index do |idx|
          if idx >= 1 && !@stats.latency_check_cmd.include?(s[idx])
            return send_data("[#{s[idx]}] command is NOT set\r\n")
          end
        end
        s.each_index do |idx|
          @stats.latency_check_cmd.delete(s[idx]) if idx >= 1
          @stats.latency_data.delete(s[idx]) if idx >= 1
        end
        send_data("DELETED\r\n")
      end

      # chg_calc_latency_average_denominator <count>
      def ev_chg_latency_avg_calc_time_count(s)
        # check argument
        if s.length != 2
          return send_data("CLIENT_ERROR number of arguments (0 for 2)\r\n")
        elsif s[1] != 'nil' && s[1].to_i < 1
          return send_data("<count> must be greater than zero or nil[DEACTIVATE]\r\n")
        end

        res = broadcast_cmd("rchg_latency_avg_calc_time_count #{s[1]}\r\n")

        if s[1] != 'nil'
          @stats.latency_check_time_count = s[1].to_i
          @stats.latency_log = true
        elsif s[1] == 'nil'
          @stats.latency_check_time_count = false
          @stats.latency_log = false
        end
        res[@stats.my_node_id] = 'CHANGED'
        send_data("#{res}\r\n")
      end

      def ev_rchg_latency_avg_calc_time_count(s)
        if s.length != 2
          return send_data("CLIENT_ERROR number of arguments (0 for 2)\r\n")
        elsif s[1] != 'nil' && s[1].to_i < 1
          return send_data("<count> must be greater than zero\r\n")
        end

        if s[1] != 'nil'
          @stats.latency_check_time_count = s[1].to_i
          @stats.latency_log = true
        elsif s[1] == 'nil'
          @stats.latency_check_time_count = false
          @stats.latency_log = false
        end
        send_data("CHANGED\r\n")
      end

      def ev_set_continuous_limit(s)
        return send_data("CLIENT_ERROR number of arguments (0 for 1)\r\n") if s.length < 2

        res = broadcast_cmd("rset_continuous_limit #{s[1]}\r\n")

        res[@stats.my_node_id] = if Event::Handler.update_continuous_limit(s[1])
                                   'STORED'
                                 else
                                   'NOT_STORED'
                                 end
        send_data("#{res}\r\n")
      end

      def ev_rset_continuous_limit(s)
        return send_data("CLIENT_ERROR number of arguments (0 for 1)\r\n") if s.length < 2

        if Event::Handler.update_continuous_limit(s[1])
          send_data("STORED\r\n")
        else
          send_data("NOT_STORED\r\n")
        end
      end

      # set_connection_pool_maxlength <length>
      def_setting_command :connection_pool_maxlength, POSITIVE_LENGTH do |v|
        Messaging::ConnectionPool.instance.maxlength = v.to_i
      end

      # set_emconnection_pool_maxlength <length>
      def_setting_command :emconnection_pool_maxlength, POSITIVE_LENGTH do |v|
        Event::EMConnectionPool.instance.maxlength = v.to_i
      end

      # set_accepted_connection_expire_time <sec>
      def_setting_command :accepted_connection_expire_time do |v|
        Event::Handler.connection_expire_time = v.to_i
      end

      # set_connection_pool_expire_time <sec>
      def_setting_command :connection_pool_expire_time do |v|
        Messaging::ConnectionPool.instance.expire_time = v.to_i
      end

      # set_emconnection_pool_expire_time <sec>
      def ev_set_emconnection_pool_expire_time(s)
        # chcking s incude command and value (NOT check digit)
        return send_data("CLIENT_ERROR number of arguments\r\n") if s.length != 2

        # if ARGV is 0, expire time become infinity(NOT happen expire)
        s[1] = '2147483647' if s[1].to_i == 0
        res = broadcast_cmd("rset_emconnection_pool_expire_time #{s[1]}\r\n")
        Event::EMConnectionPool.instance.expire_time = s[1].to_i
        res[@stats.my_node_id] = 'STORED'
        send_data("#{res}\r\n")
      end

      # rset_emconnection_pool_expire_time <sec>
      def ev_rset_emconnection_pool_expire_time(s)
        return send_data("CLIENT_ERROR number of arguments\r\n") if s.length != 2

        Event::EMConnectionPool.instance.expire_time = s[1].to_i
        send_data("STORED\r\n")
      end

      # switch_dns_caching <on|off|true|false>
      def ev_switch_dns_caching(s)
        return send_data("CLIENT_ERROR number of arguments\r\n") if s.length != 2

        res = broadcast_cmd("rswitch_dns_caching #{s[1]}\r\n")
        if %w(on true).include?(s[1])
          DNSCache.instance.enable_dns_cache
          @log.info('DNS caching enabled')
          res[@stats.my_node_id] = 'ENABLED'
        elsif %w(off false).include?(s[1])
          DNSCache.instance.disable_dns_cache
          @log.info('DNS caching disabled')
          res[@stats.my_node_id] = 'DISABLED'
        else
          res[@stats.my_node_id] = 'NOTSWITCHED'
        end
        send_data("#{res}\r\n")
      end

      # rswitch_dns_caching <on|off|true|false>
      def ev_rswitch_dns_caching(s)
        return send_data("CLIENT_ERROR number of arguments\r\n") if s.length != 2

        if %w(on true).include?(s[1])
          DNSCache.instance.enable_dns_cache
          @log.info('DNS caching enabled')
          send_data("ENABLED\r\n")
        elsif %w(off false).include?(s[1])
          DNSCache.instance.disable_dns_cache
          @log.info('DNS caching disabled')
          send_data("DISABLED\r\n")
        else
          send_data("NOTSWITCHED\r\n")
        end
      end

      # set_hilatency_warn_time <sec>
      # A command that takes longer is logged as a warning.
      def_setting_command :hilatency_warn_time, POSITIVE_TIME do |v|
        @stats.hilatency_warn_time = v.to_f
      end

      # set_routing_trans_timeout <sec>
      def_setting_command :routing_trans_timeout, POSITIVE_TIME do |v|
        @stats.routing_transaction_timeout = v.to_f
      end

      # set_spushv_read_timeout <sec>
      def_setting_command :spushv_read_timeout, POSITIVE_INTEGER_TIME do |v|
        @stats.spushv_read_timeout = v.to_i
      end

      # set_reqpushv_timeout_count <count>
      def_setting_command :reqpushv_timeout_count, POSITIVE_INTEGER_TIME do |v|
        @stats.reqpushv_timeout_count = v.to_i
      end

      # set_spushv_klength_warn <bytes>
      def_setting_command :spushv_klength_warn, POSITIVE_SIZE do |v|
        @stats.spushv_klength_warn = v.to_i
      end

      # set_spushv_vlength_warn <bytes>
      def_setting_command :spushv_vlength_warn, POSITIVE_SIZE do |v|
        @stats.spushv_vlength_warn = v.to_i
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

      # set_wb_shift_size <size>
      def_setting_command :wb_shift_size, POSITIVE_LENGTH do |v|
        $roma.wb_writer.shift_size = v.to_i
      end

      # set_storage_status [number of file][safecopy|normal]{hash_name}
      def ev_set_storage_status(s)
        return send_data("CLIENT_ERROR number of arguments (#{s.length - 1} for 2)\r\n") if s.length < 3

        hash_name = if s.length >= 4
                      s[3]
                    else
                      'roma'
                    end
        st = @storages[hash_name]
        return send_data("CLIENT_ERROR hash_name = #{hash_name} does not found\r\n") unless st

        db_index = s[1].to_i
        return send_data("CLIENT_ERROR divnum <= #{db_index}\r\n") if st.divnum <= db_index

        if s[2] == 'safecopy'
          return send_data("CLIENT_ERROR storage[#{db_index}] != :normal status\r\n") if st.dbs[db_index] != :normal
          if st.update_db_status(db_index, :safecopy_flushing) == false
            return send_data("CLIENT_ERROR storage[#{db_index}] status can't changed\r\n")
          end

          Roma::AsyncEvent.queue.push(Roma::AsyncMessage.new('start_storage_flush_process', [hash_name, db_index]))
        elsif s[2] == 'normal'
          if st.dbs[db_index] != :safecopy_flushed
            return send_data("CLIENT_ERROR storage[#{db_index}] != :safecopy_flushed status\r\n")
          end
          if st.update_db_status(db_index, :cachecleaning) == false
            return send_data("CLIENT_ERROR storage[#{db_index}] status can't changed\r\n")
          end

          Roma::AsyncEvent.queue.push(Roma::AsyncMessage.new('start_storage_cachecleaning_process',
                                                             [hash_name, db_index]))
        else
          return send_data("CLIENT_ERROR status parse error\r\n")
        end

        send_data("PUSHED\r\n")
      end

      # set_gui_run_snapshot [true|false]
      def ev_set_gui_run_snapshot(s)
        return send_data("CLIENT_ERROR number of arguments\r\n") if s.length != 2

        case s[1]
        when 'true'
          @stats.gui_run_snapshot = true
          send_data("STORED\r\n")
        when 'false'
          @stats.gui_run_snapshot = false
          send_data("STORED\r\n")
        else
          send_data("CLIENT_ERROR value must be true or false\r\n")
        end
      end

      # set_gui_last_snapshot <%Y/%m/%dT%H:%M:%S>
      def_setting_command :gui_last_snapshot,
                          ->(v) { 'format is [%Y/%m/%dT%H:%M:%S]' if v !~ %r{^\d+/\d+/\d+T\d+:\d+:\d+$} },
                          reply: 'PUSHED' do |v|
        @stats.gui_last_snapshot = v
      end

      # set_cleanup_regexp <regexp>
      def ev_set_cleanup_regexp(s)
        return send_data("CLIENT_ERROR number of arguments #{s.length - 1} to 1\r\n") if s.length != 2

        # failover check
        return send_data("CLIENT_ERROR failover disable now!!\r\n") unless @routing_table.enabled_failover

        @storages.each do |_hash_name, st|
          st.cleanup_regexp = s[1]
          st.stop_clean_up
          send_data("STORED\r\n")
        end
      end

      # set_log_shift_size <size>
      def_setting_command :log_shift_size, POSITIVE_LENGTH do |v|
        @log.shift_size = v.to_i
        @stats.log_shift_size = v.to_i
      end

      # set_log_shift_age <age>
      # The age is a number of files, or min, hour, daily, weekly or monthly.
      def_setting_command :log_shift_age, LOG_SHIFT_AGE do |v|
        age = v.to_i > 0 || v == '0' ? v.to_i : v
        @log.shift_age = age
        @stats.log_shift_age = age
      end

      private

      # What is wrong with the arguments +s+ of a setting command, or nil.
      def setting_error(s, check)
        return 'number of arguments' if s.length != 2

        check&.call(s[1])
      end

      def dcnice(p)
        case p
        when 1 # highest priority
          @stats.stream_copy_wait = 0.001
          @storages.each_value do |st|
            st.each_vn_dump_sleep = 0.001
            st.each_vn_dump_sleep_count = 1000
          end
        when 2
          @stats.stream_copy_wait = 0.005
          @storages.each_value do |st|
            st.each_vn_dump_sleep = 0.005
            st.each_vn_dump_sleep_count = 100
          end
        when 3 # default priority
          @stats.stream_copy_wait = 0.01
          @storages.each_value do |st|
            st.each_vn_dump_sleep = 0.001
            st.each_vn_dump_sleep_count = 10
          end
        when 4
          @stats.stream_copy_wait = 0.01
          @storages.each_value do |st|
            st.each_vn_dump_sleep = 0.005
            st.each_vn_dump_sleep_count = 10
          end
        when 5 # lowest priority
          @stats.stream_copy_wait = 0.01
          @storages.each_value do |st|
            st.each_vn_dump_sleep = 0.01
            st.each_vn_dump_sleep_count = 10
          end
        else
          return 'CLIENT_ERROR You sholud input a priority from 1 to 5.'
        end
        @stats.dcnice = p
        'STORED'
      end

      def config_stat
        config = Roma.config
        ret = {}
        ret['config.routing.lost_action'] = config.routing.lost_action
        ret['config.log.shift_age'] = config.log.shift_age
        ret['config.log.shift_size'] = config.log.shift_size
        ret['config.log.path'] = File.expand_path(config.log.path)
        ret['config.routing.path'] = File.expand_path(config.routing.path)
        ret['config.storage.delete_mark_expire_time'] = config.storage.delete_mark_expire_time
        ret['config.storage.exception_action'] = config.storage.exception_action
        ret['config.data_copy.stream_copy_wait'] = config.data_copy.stream_copy_wait
        ret['config.command_plugin_path'] = File.expand_path(config.command_plugin_path)
        ret['config.write_behind.path'] = File.expand_path(config.write_behind.path)
        ret['config.write_behind.shift_size'] = config.write_behind.shift_size
        ret['config.connection.descriptor_table_size'] = config.connection.descriptor_table_size
        ret
      end

      def storage_stat(st)
        ret = {}
        ret['storage.storage_path'] = File.expand_path(st.storage_path)
        ret['storage.st_class'] = st.st_class.name.delete_prefix('Roma::Storage::')
        ret['storage.divnum'] = st.divnum
        ret['storage.option'] = st.option
        ret['storage.each_vn_dump_sleep'] = st.each_vn_dump_sleep
        ret['storage.each_vn_dump_sleep_count'] = st.each_vn_dump_sleep_count
        ret['storage.each_vn_dump_files'] = st.each_vn_dump_files.inspect
        ret['storage.each_clean_up_sleep'] = st.each_clean_up_sleep
        ret['storage.cleanup_regexp'] = st.cleanup_regexp
        ret['storage.logic_clock_expire'] = st.logic_clock_expire
        ret['storage.safecopy_stats'] = st.dbs.inspect
        st.database_stats.each_with_index do |db, i|
          db.each { |k, v| ret["storage[#{i}].#{k}"] = v }
        end
        ret
      end
    end
  end
end
