require 'roma/cli/common'

module Roma
  module Subcommands
    # roma node: work with a node.
    class Node < Thor
      extend Common

      check_unknown_options!

      # The method of send is send_command, since send is Object#send.
      map 'send' => :send_command

      desc 'send COMMAND...', 'Send a command to a node, and print the reply'
      option :host, default: 'localhost', desc: 'The host of the node'
      option :port, aliases: '-p', type: :numeric, default: 12_000, desc: 'The port of the node'
      option :value, aliases: '-v', desc: 'The value of a command that stores one, instead of asking for it'
      option :yes, aliases: '-y', type: :boolean, default: false, desc: 'Stop nodes by balse or shutdown without asking'
      def send_command(command, *args)
        require 'roma/tools/node_command'
        puts Roma::Tools::NodeCommand.new.run("#{options[:host]}_#{options[:port]}", [command, *args].join(' '),
                                              value: options[:value], yes: options[:yes])
      end
    end
  end
end
