require 'roma/stats'
require 'roma/version'
require 'roma/event/handler'
require 'roma/messaging/con_pool'
require 'roma/command/background_command_receiver'
require 'roma/command/routing_command_receiver'
require 'roma/command/util_command_receiver'
require 'roma/command/multi_hash_command_receiver'
require 'roma/command/system_command_receiver'

module Roma
  module Command

    class Receiver < Roma::Event::Handler

      include BackgroundCommandReceiver
      include RoutingCommandReceiver
      include UtilCommandReceiver
      include MultiHashCommandReceiver
      include SystemCommandReceiver

      def initialize(storages, routing_table)
        super(storages, routing_table)
        @stats = Roma::Stats.instance
        @my_node_id = @stats.my_node_id
        @default_hash_name = 'roma'
      end

      def self.make_starting_event_list
        Event::Handler.event_list.clear
        each_system_commands{|m|
          Event::Handler.event_list[m.to_s[3..-1]] = m
          Event::Handler.system_commands[m.to_s[3..-1]] = nil
        }
      end

      def self.each_system_commands
        methods = RoutingCommandReceiver::public_instance_methods
        methods << BackgroundCommandReceiver::public_instance_methods
        methods << SystemCommandReceiver::public_instance_methods

        if Receiver::public_instance_methods.include?(:ev_eval)
          methods << :ev_eval
        end
        methods.flatten.each{|m|
           yield m if m.to_s.start_with?('ev_')
        }
      end

      def self.make_event_list
        each_system_commands{|m|
          Event::Handler.system_commands[m.to_s[3..-1]] = nil
        }
        Receiver::public_instance_methods.each{|m|
          if m.to_s.start_with?('ev_')
            Event::Handler.event_list[m.to_s[3..-1]] = m
          end
        }
      end

    end # class Receiver < Roma::Event::Handler

  end # module Command
end # module Roma
