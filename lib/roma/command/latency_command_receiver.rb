module Roma
  module Command
    # The commands that measure the latency of the commands, by Stats.
    # SystemCommandReceiver includes it, so that they are system commands.
    module LatencyCommandReceiver
      # set_latency_avg_calc_rule <mode> <count> <command1> <command2>....
      # <mode> is on/off
      # <count> is denominator to calculate average.
      # <commandx> is target command
      def ev_set_latency_avg_calc_rule(s)
        error = latency_rule_error(s)
        return send_data(error) if error

        res = broadcast_cmd("rset_latency_avg_calc_rule #{s[1..].join(' ')}\r\n")
        res[@stats.my_node_id] = apply_latency_rule(s)
        send_data("#{res}\r\n")
      end

      def ev_rset_latency_avg_calc_rule(s)
        error = latency_rule_error(s)
        return send_data(error) if error

        send_data("#{apply_latency_rule(s)}\r\n")
      end

      # add_latency_avg_calc_cmd <command1> <command2>....
      def ev_add_latency_avg_calc_cmd(s)
        error = latency_add_error(s)
        return send_data(error) if error

        res = broadcast_cmd("radd_latency_avg_calc_cmd #{s[1..].join(' ')}\r\n")
        @stats.watch_latency(s[1..])
        res[@stats.my_node_id] = 'SET'
        send_data("#{res}\r\n")
      end

      def ev_radd_latency_avg_calc_cmd(s)
        error = latency_add_error(s)
        return send_data(error) if error

        @stats.watch_latency(s[1..])
        send_data("SET\r\n")
      end

      # del_latency_avg_calc_cmd <command1> <command2>....
      def ev_del_latency_avg_calc_cmd(s)
        error = latency_del_error(s)
        return send_data(error) if error

        res = broadcast_cmd("rdel_latency_avg_calc_cmd #{s[1..].join(' ')}\r\n")
        @stats.unwatch_latency(s[1..])
        res[@stats.my_node_id] = 'DELETED'
        send_data("#{res}\r\n")
      end

      def ev_rdel_latency_avg_calc_cmd(s)
        error = latency_del_error(s)
        return send_data(error) if error

        @stats.unwatch_latency(s[1..])
        send_data("DELETED\r\n")
      end

      # chg_latency_avg_calc_time_count <count>
      def ev_chg_latency_avg_calc_time_count(s)
        error = latency_time_count_error(s, 'zero or nil[DEACTIVATE]')
        return send_data(error) if error

        res = broadcast_cmd("rchg_latency_avg_calc_time_count #{s[1]}\r\n")
        @stats.latency_time_count = s[1] == 'nil' ? nil : s[1].to_i
        res[@stats.my_node_id] = 'CHANGED'
        send_data("#{res}\r\n")
      end

      def ev_rchg_latency_avg_calc_time_count(s)
        error = latency_time_count_error(s, 'zero')
        return send_data(error) if error

        @stats.latency_time_count = s[1] == 'nil' ? nil : s[1].to_i
        send_data("CHANGED\r\n")
      end

      private

      # The error of set_latency_avg_calc_rule for the words +s+, or nil.
      def latency_rule_error(s)
        if /^on$|^off$/ !~ s[1]
          "CLIENT_ERROR argument 1: please input \"on\" or \"off\"\r\n"
        elsif s[1] == 'on' && (s.length <= 3 || s[2].to_i < 1)
          "CLIENT_ERROR number of arguments (0 for 3) and <count> must be greater than zero\r\n"
        elsif s[1] == 'off' && s.length != 2
          "CLIENT_ERROR number of arguments (0 for 1, or more 3)\r\n"
        else
          unsupported_latency_cmd_error(s[3..] || [])
        end
      end

      # Starts or stops the latency check by set_latency_avg_calc_rule, and
      # returns the reply.
      def apply_latency_rule(s)
        if s[1] == 'on'
          @stats.start_latency_check(s[3..], s[2].to_i)
          'ACTIVATED'
        else
          @stats.stop_latency_check
          'DEACTIVATED'
        end
      end

      def latency_add_error(s)
        return "CLIENT_ERROR number of arguments (0 for 2)\r\n" if s.length < 2

        s[1..].each do |cmd|
          error = unsupported_latency_cmd_error([cmd])
          return error if error
          return "ALREADY SET [#{cmd}] command\r\n" if @stats.latency_check_cmd.include?(cmd)
        end
        nil
      end

      def latency_del_error(s)
        return "CLIENT_ERROR number of arguments (0 for 2)\r\n" if s.length < 2

        cmd = s[1..].find { |c| !@stats.latency_check_cmd.include?(c) }
        "[#{cmd}] command is NOT set\r\n" if cmd
      end

      # A system command or an unknown one can't be checked.
      def unsupported_latency_cmd_error(cmds)
        cmd = cmds.find { |c| !Event::Handler.event_list.include?(c) || Event::Handler.system_commands.include?(c) }
        "NOT SUPPORT [#{cmd}] command\r\n" if cmd
      end

      def latency_time_count_error(s, allowed)
        if s.length != 2
          "CLIENT_ERROR number of arguments (0 for 2)\r\n"
        elsif s[1] != 'nil' && s[1].to_i < 1
          "<count> must be greater than #{allowed}\r\n"
        end
      end
    end
  end
end
