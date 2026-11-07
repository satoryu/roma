require 'roma/command_plugin'
require 'json'

module Roma
  module CommandPlugin
    module Gui
      include ::Roma::CommandPlugin

      # get_routing_history
      def ev_get_routing_history(_s)
        routing_path = get_config_stat['config.routing.path']
        contents = String.new
        Dir.glob("#{routing_path}/*").each do |fname|
          contents << File.read(fname) if !FileTest.directory?(fname) && fname =~ /#{@stats.my_node_id}\.route*/
        end
        routing_list = contents.scan(/[-.a-zA-Z\d]+_\d+/).uniq.sort
        routing_list.each do |routing|
          send_data("#{routing}\r\n")
        end
        send_data("END\r\n")
      end

      # gather_logs [start_date(YYYY-MM-DDThh:mm:ss)] <end_date(YYYY-MM-DDThh:mm:ss)>
      def ev_gather_logs(s)
        if s.length < 2 || s.length > 3
          return send_data("CLIENT_ERROR number of arguments (#{s.length - 1} for 2-3)\r\n")
        end

        start_date = s[1]
        end_date = s[2]
        end_date ||= 'current'

        return send_data("CLIENT_ERROR gathering process is already going\r\n") if @stats.gui_run_gather_logs

        begin
          @stats.gui_run_gather_logs = true
          Roma::AsyncEvent.queue.push(Roma::AsyncMessage.new('start_get_logs', [start_date, end_date]))

          send_data("STARTED\r\n")
        rescue StandardError
          @stats.gui_run_gather_logs = false
          @routing_table.logs = []
          send_data("CLIENT_ERROR\r\n")
        end
      end

      # show_logs
      def ev_show_logs(_s)
        if @stats.gui_run_gather_logs
          send_data("Not finished gathering\r\n")
        else
          @routing_table.logs.each_with_index do |log, index|
            send_data("#{log}\r\n")
            sleep @stats.stream_show_wait if index % 10 == 0
          end
          send_data("END\r\n")
          @routing_table.logs.clear
        end
      end
    end # end of module Gui
  end # end of module CommandPlugin
end # end of modlue Roma
