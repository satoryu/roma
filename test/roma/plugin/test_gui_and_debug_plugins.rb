require 'test_helper'
require 'command_test_harness'
require 'receiver_command_test_helper'
require 'roma/plugin/plugin_gui'
require 'roma/plugin/plugin_debug'
require 'roma/plugin/plugin_test'

class GuiAndDebugPluginsTest < Test::Unit::TestCase
  include ReceiverCommandTestHelper

  HARNESS = Class.new(CommandTestHarness) do
    include Roma::CommandPlugin::PluginGui
    include Roma::CommandPlugin::PluginOperation
    include Roma::CommandPlugin::PluginTest
  end

  def setup
    @conn = HARNESS.new
    @conn.stats.address = 'guiplugintest'
    @conn.stats.port = Process.pid.to_s
  end

  def test_get_routing_history
    fname = "#{Roma::Config::RTTABLE_PATH}/#{@conn.stats.ap_str}.route.1"
    File.write(fname, "2026-01-01T00:00:00.1 join hosta_1\n2026-01-01T00:00:01.1 setroute 0 1 hostb_1 hosta_1\n")
    assert_equal "hosta_1\r\nhostb_1\r\nEND\r\n", @conn.request('get_routing_history')
  ensure
    FileUtils.rm_f(fname)
  end

  def test_gather_logs
    assert_equal "STARTED\r\n", @conn.request('gather_logs 2026-01-01T00:00:00')
    msg = Roma::AsyncProcess.queue.pop
    assert_equal ['start_get_logs', ['2026-01-01T00:00:00', 'current']], [msg.event, msg.args]
    assert_true @conn.stats.gui_run_gather_logs

    assert_equal "CLIENT_ERROR gathering process is already going\r\n", @conn.request('gather_logs 2026-01-01T00:00:00')
    assert_equal "CLIENT_ERROR number of arguments (0 for 2-3)\r\n", @conn.request('gather_logs')
  end

  def test_show_logs
    @conn.stats.gui_run_gather_logs = true
    assert_equal "Not finished gathering\r\n", @conn.request('show_logs')

    @conn.stats.gui_run_gather_logs = false
    @conn.stats.stream_show_wait_param = 0
    @conn.rttable.logs = %w(log1 log2)
    assert_equal "log1\r\nlog2\r\nEND\r\n", @conn.request('show_logs')
    # Shown once.
    assert_equal "END\r\n", @conn.request('show_logs')
  end

  def test_eval
    assert_equal "2\r\n", @conn.request('eval 1 + 1')
    assert_equal "boom\r\n", @conn.request("eval raise 'boom'")
  end

  def test_get_key_info
    @conn.instance_variable_set(:@wbuf, String.new)
    assert_equal 'END', @conn.get_key_info('key1')
    assert_match(/\Ad = \d+ 0x\h+\r\nvn = \d+ 0x\h+\r\nnodes = \[.*\]\r\n\z/, @conn.instance_variable_get(:@wbuf))
  end

  def test_echo
    assert_equal "#{%w(echo a b).inspect}\r\n", @conn.request('echo a b')
  end
end
