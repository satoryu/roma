require 'roma/configuration'

module Roma
  module Command
    # Lets a module of commands, or a command plugin, name its commands that
    # need a connection authenticated by config.cluster_secret, such as the
    # commands between the nodes:
    #
    #   module MyPlugin
    #     include Roma::CommandPlugin
    #     extend Roma::Command::Authentication
    #
    #     def ev_rmy_command(s) = ...
    #     require_authentication :rmy_command
    #   end
    #
    # Without it, they reply "CLIENT_ERROR authentication required". See
    # AuthCommandReceiver.
    module Authentication
      # Whether the connection is authenticated, which AuthCommandReceiver
      # does. Any is without the secret.
      module Helpers
        private

        def authenticated?
          Roma.config.cluster_secret.nil? || @authenticated == true
        end

        def reply_authentication_required
          send_data("CLIENT_ERROR authentication required\r\n")
        end
      end

      # The names of the commands that need it.
      def self.commands = @commands ||= Set.new

      def require_authentication(*names)
        names = names.map(&:to_s)
        Authentication.commands.merge(names)
        prepend(Module.new do
          include Helpers

          names.each do |name|
            define_method(:"ev_#{name}") do |s|
              authenticated? ? super(s) : reply_authentication_required
            end
          end
        end)
      end
    end
  end
end
