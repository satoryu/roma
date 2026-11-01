require 'roma/async_process'
require 'roma/messaging/con_pool'
require 'roma/command/vnode_command_receiver'

module Roma
  module Command

    module BackgroundCommandReceiver
      include VnodeCommandReceiver

      def ev_balance(s)
        res = broadcast_cmd("rbalance\r\n")
        if @stats.run_join == false &&
            @stats.run_recover == false &&
            @stats.run_balance == false &&
            @routing_table.vnode_balance(@stats.my_node_id)==:less
          Roma::AsyncProcess::queue.push(Roma::AsyncMessage.new('start_balance_process'))
          res[@stats.my_node_id] = 'STARTED'
        else
          res[@stats.my_node_id] = 'SERVER_ERROR Not unbalance or othre process is already running.'
        end
        send_data("#{res}\r\n")
      end

      def ev_rbalance(s)
        if @stats.run_join == false &&
            @stats.run_recover == false &&
            @stats.run_balance == false &&
            @routing_table.vnode_balance(@stats.my_node_id)==:less
          Roma::AsyncProcess::queue.push(Roma::AsyncMessage.new('start_balance_process'))
          send_data("STARTED\r\n")
        else
          send_data("SERVER_ERROR Not unbalance or other process is already running.\r\n")
        end
      end

      def ev_release(s)
        if @stats.run_join == false &&
            @stats.run_recover == false &&
            @stats.run_balance == false &&
            @stats.run_release == false &&
            @stats.run_iterate_storage == false
          Roma::AsyncProcess::queue.push(Roma::AsyncMessage.new('start_release_process'))
          send_data("STARTED\r\n")
        else
          send_data("SERVER_ERROR Other process is already running.\r\n")
        end
      end

      # recover
      def ev_recover(s)
        if @routing_table.can_i_recover?
          cmd = "rrecover"
          res = broadcast_cmd("#{cmd}\r\n")
          unless @stats.run_recover
            Roma::AsyncProcess::queue.push(Roma::AsyncMessage.new('start_recover_process'))
            res[@my_node_id] = "STARTED"
          else
            res[@my_node_id] = "SERVER_ERROR Recover process is already running."
          end
          send_data("#{res}\r\n")
        else
          send_data("SERVER_ERROR nodes num < redundant num\r\n")
        end
      end

      # rrecover
      def ev_rrecover(s)
        if @routing_table.can_i_recover?
          unless @stats.run_recover
            Roma::AsyncProcess::queue.push(Roma::AsyncMessage.new('start_recover_process'))
            send_data("STARTED\r\n")
          else
            send_data("SERVER_ERROR Recover process is already running.\r\n")
          end
        else
          send_data("SERVER_ERROR nodes num < redundant num\r\n")
        end
      end

    end # module BackgroundCommandReceiver

  end # module Command
end # module Roma
