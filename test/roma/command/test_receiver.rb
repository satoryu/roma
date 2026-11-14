require 'test_helper'
require 'roma/command/receiver'

class ReceiverTest < Test::Unit::TestCase
  def setup
    @saved_event_list = Roma::Event::Handler.event_list.dup
    @saved_system_commands = Roma::Event::Handler.system_commands.dup
  end

  def teardown
    Roma::Event::Handler.event_list.replace(@saved_event_list)
    Roma::Event::Handler.system_commands.replace(@saved_system_commands)
  end

  # The commands of the modules that SystemCommandReceiver includes are
  # system commands too: they run while the node starts.
  def test_starting_event_list
    Roma::Command::Receiver.make_starting_event_list
    %w(balse set_latency_avg_calc_rule rchg_latency_avg_calc_time_count switch_replication wb_command_map
       writebehind_rotate).each do |command|
      assert_true Roma::Event::Handler.event_list.key?(command), command
      assert_true Roma::Event::Handler.system_commands.key?(command), command
    end
    assert_false Roma::Event::Handler.event_list.key?('createhash')
  end
end
