require 'roma/tools/admin_client'
require 'roma/tools/error'

module Roma
  module Tools
    # Sends a command to a node, asking for what the command needs.
    class Adm
      # The commands that store a value, which is sent in the next line.
      VALUE_COMMANDS = %w(
        set add replace append prepend cas
        alist_delete alist_include? alist_insert alist_sized_insert alist_swap_and_insert
        alist_swap_and_sized_insert alist_join_with_time alist_join alist_push alist_sized_push
        alist_swap_and_push alist_update_at
      ).freeze
      # The commands that stop nodes, which ask for confirmation.
      HALT_COMMANDS = %w(balse shutdown).freeze

      # Questions are written to +out+, and answered from +input+.
      def initialize(input: $stdin, out: $stdout, client: AdminClient.new)
        @input = input
        @out = out
        @client = client
      end

      # Sends +cmd+ to the node +nid+, and returns the lines of the reply.
      # The value of a command that stores one is asked for unless +value+
      # is given, and a command that stops nodes is confirmed unless +yes+.
      # Raises Error if it is not confirmed, or the node doesn't reply.
      def run(nid, cmd, value: nil, yes: false)
        name = cmd.split.first
        if HALT_COMMANDS.include?(name)
          confirm unless yes
          # The node asks twice for a shutdown.
          cmd = "#{cmd}\r\nyes\r\nyes"
        elsif VALUE_COMMANDS.include?(name)
          cmd = "#{cmd}\r\n#{value || ask_value}"
        end
        @client.command(nid, cmd)
      end

      private

      def confirm
        @out.puts 'Are you sure?(yes/no)'
        raise Error, 'The confirmation was rejected.' unless @input.gets.to_s.chomp == 'yes'
      end

      def ask_value
        @out.puts 'Please input value.'
        value = @input.gets
        raise Error, 'No value was given.' unless value
        value.chomp
      end
    end
  end
end
