require 'roma/command_plugin'

module Roma
  module CommandPlugin
    module Test
      include ::Roma::CommandPlugin

      def ev_echo(s)
        send_data("#{s.inspect}\r\n")
      end
    end
  end
end
