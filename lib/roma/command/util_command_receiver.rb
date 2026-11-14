require 'roma/messaging/connection_pool'

module Roma
  module Command
    # The helpers of the commands, private, since a connection dispatches
    # only the ev_ methods.
    module UtilCommandReceiver
      private

      def send_cmd(node_id, cmd)
        con = checkout_connection(node_id)
        con.write(cmd)
        res = con.gets
        if res.nil?
          @routing_table.proc_failed(node_id)
          return nil
        elsif res.start_with?('ERROR') || res == "\r\n"
          # An unknown command, whose reply may have more lines, such as the
          # one that starts with an empty line and suggests a command. They
          # would be read as the reply to the next command.
          con.close_connection
        else
          @routing_table.proc_succeed(node_id)
          checkin_connection(node_id, con)
        end
        res.chomp
      rescue StandardError => e
        @routing_table.proc_failed(node_id)
        @log.error("#{e}\n#{$@}")
        nil
      end

      def broadcast_cmd(cmd)
        res = {}
        @routing_table.nodes.each do |node_id|
          res[node_id] = send_cmd(node_id, cmd) if node_id != @stats.my_node_id
        end
        res
      end

      def async_send_cmd(node_id, cmd)
        con = Roma::Messaging::ConnectionPool.instance.checkout(node_id)
        con.write(cmd)
        res = con.gets
        Roma::Messaging::ConnectionPool.instance.checkin(node_id, con)
        if res
          res.chomp!
          @routing_table.proc_succeed(node_id)
        else
          @routing_table.proc_failed(node_id)
        end
        res
      rescue StandardError => e
        @routing_table.proc_failed(node_id)
        @log.error("#{e}\n#{$@}")
        nil
      end

      def async_broadcast_cmd(cmd, without_node_ids = nil)
        without_node_ids ||= [@stats.my_node_id]
        res = {}
        @routing_table.nodes.each do |node_id|
          res[node_id] = async_send_cmd(node_id, cmd) unless without_node_ids.include?(node_id)
        end
        res
      rescue StandardError => e
        @log.error("#{e}\n#{$@}")
        nil
      end

      # Forwards the request of the words +argv+, with its value +data+, to the node
      # +node_id+, which is the primary of the key, and replies its one-line
      # reply.
      def forward_and_one_line_receive(node_id, argv, data = nil)
        return send_data("SERVER_ERROR Routing table is inconsistent.\r\n") if argv.last == 'forward'

        @log.warn("forward #{argv} to #{node_id}")

        buf = "#{argv.join(' ')} forward\r\n"
        buf << "#{data}\r\n" if data
        res = send_cmd(node_id, buf)
        return send_data("SERVER_ERROR Message forward failed.\r\n") if res.nil? || res.start_with?('ERROR')

        send_data("#{res}\r\n")
      end

      # Forwards the request like forward_and_one_line_receive, and replies
      # its reply of VALUE lines and END.
      def forward_and_multi_line_receive(node_id, argv, data = nil)
        return send_data("SERVER_ERROR Routing table is inconsistent.\r\n") if argv.last == 'forward'

        @log.warn("forward #{argv} to #{node_id}")

        buf = "#{argv.join(' ')} forward\r\n"
        buf << "#{data}\r\n" if data

        con = checkout_connection(node_id)
        con.write(buf)

        buf = con.gets
        if buf.nil?
          @routing_table.proc_failed(node_id)
          @log.error("forward get failed:node_id=#{node_id} argv=#{argv} #{$@}")
          return send_data("SERVER_ERROR Message forward failed.\r\n")
        elsif buf.start_with?('ERROR')
          @routing_table.proc_succeed(node_id)
          con.close_connection
          @log.error("forward get failed:node_id=#{node_id} argv=#{argv} #{$@}")
          return send_data("SERVER_ERROR Message forward failed.\r\n")
        elsif buf.start_with?('VALUE') == false
          checkin_connection(node_id, con)
          @routing_table.proc_succeed(node_id)
          return send_data(buf)
        end

        res = +''
        loop do
          res << buf
          s = buf.split(/ /)
          if s[0] != 'VALUE'
            checkin_connection(node_id, con)
            @routing_table.proc_succeed(node_id)
            return send_data(buf)
          end
          res << con.read_bytes(s[3].to_i + 2)
          break if (buf = con.gets) == "END\r\n"
        end

        res << "END\r\n"

        checkin_connection(node_id, con)
        @routing_table.proc_succeed(node_id)

        send_data(res)
      rescue StandardError => e
        @routing_table.proc_failed(node_id) if e.message != 'no connection'
        @log.error("forward get failed:node_id=#{node_id} argv=#{argv} #{e} #{$@}")
        send_data("SERVER_ERROR Message forward failed.\r\n")
      end

      # Pushes +value+ of +key+ to write-behind if it records +command+.
      def push_to_write_behind(command, hash_name, key, value)
        return unless @stats.wb_command_map.key?(command)

        Roma::WriteBehind::Process.push(hash_name, @stats.wb_command_map[command], key, value)
      end

      # Replies +error+ as SERVER_ERROR in one line, and logs it.
      # Replies the message of +error+. Its backtrace, which has the paths
      # of the server, goes only to the log.
      def reply_server_error(error)
        send_data("#{"SERVER_ERROR #{error}".tr("\r\n", ' ')}\r\n")
        @log.error("#{error} #{error.backtrace&.join(' ')}")
      end

      # change to actual time for a memcached's expire time value
      #
      # The storages keep it in 32 bits, where 0 is a delete mark. A time
      # before 1970, as -1 - now gives, has expired; a later one than 32 bits
      # can hold, as one in milliseconds, is the latest that they can.
      def chg_time_expt(expire_time)
        if expire_time == 0
          expire_time = 0x7fffffff
        elsif expire_time < 2_592_000
          expire_time += Time.now.to_i
        end
        expire_time.clamp(1, 0xffffffff)
      end
    end
  end
end
