require 'test_helper'
require 'command_test_harness'
require 'fake_node'
require 'roma/plugin/plugin_gui'
require 'roma/plugin/plugin_debug'
require 'roma/plugin/plugin_test'

# Unit tests for the vnode, background and multi-hash commands, and the
# gui, debug and test plugins.
module ReceiverCommandTestHelper
  NID = CommandTestHarness::NID
  OTHER_NID = CommandTestHarness::OTHER_NID

  def setup
    @conn = CommandTestHarness.new
  end

  def teardown
    @conn.close
    Roma::AsyncProcess.queue.clear
  end

  # The other nodes' replies come first.
  def replies(reply, other: 'STORED')
    "#{{ OTHER_NID => other, NID => reply }}\r\n"
  end

  def queued_events
    queue = Roma::AsyncProcess.queue
    Array.new(queue.size) { queue.pop.event }
  end
end

class VnodeCommandTest < Test::Unit::TestCase
  include ReceiverCommandTestHelper

  # A vnode stream as spushv receives it: each key and value, and 20 zero
  # bytes at the end. A nil value is a deleted mark, whose expiry is 0.
  def stream(vn, pairs)
    data = pairs.map do |k, v|
      [vn, Time.now.to_i, 1, v ? 0x7fffffff : 0, k.bytesize, k, (v || '').bytesize, v || ''].pack("NNNNNa#{k.bytesize}Na*")
    end
    data.join + "\0" * 20
  end

  def test_spushv_protection
    assert_equal "false\r\n", @conn.request('spushv_protection')
    assert_equal "true\r\n", @conn.request('spushv_protection true')
    assert_true @conn.stats.spushv_protection
    assert_equal "false\r\n", @conn.request('spushv_protection no')
    assert_equal "COMMAND ERROR\r\n", @conn.request('spushv_protection true false')
  end

  def test_spushv
    reply = @conn.request('spushv roma 0', stream(0, 'key1' => 'value1', 'key2' => nil).chomp("\r\n"))
    assert_equal "READY\r\nSTORED\r\n", reply
    assert_equal 'value1', @conn.storage.get(0, 'key1', 0)
    # The deleted mark is stored, so get finds nothing.
    assert_nil @conn.storage.get(0, 'key2', 0)
    assert_not_nil @conn.storage.db_get(0, 'key2')
    # It stops the storage clean up, and is no longer receiving the vnode.
    assert_equal 1, @conn.romad.clean_up_stops
    assert_equal({}, @conn.stats.run_receive_a_vnode)
  end

  def test_spushv_rejects_older_data
    @conn.storage.set(0, 'key1', 0, 0x7fffffff, 'newer')
    @conn.storage.set(0, 'key1', 0, 0x7fffffff, 'newer')
    @conn.request('spushv roma 0', stream(0, 'key1' => 'older'))
    assert_equal 'newer', @conn.storage.get(0, 'key1', 0)
  end

  def test_spushv_warns_about_long_keys_and_values
    @conn.stats.spushv_klength_warn = 1
    @conn.stats.spushv_vlength_warn = 1
    assert_equal "READY\r\nSTORED\r\n", @conn.request('spushv roma 0', stream(0, 'key1' => 'value1'))
  end

  def test_spushv_in_protection
    @conn.stats.spushv_protection = true
    assert_equal "SERVER_ERROR In spushv_protection.\r\n", @conn.request('spushv roma 0', stream(0, 'key1' => 'v'))
    assert_nil @conn.storage.get(0, 'key1', 0)
  end

  def test_spushv_wrong_number_of_arguments
    assert_equal "CLIENT_ERROR Wrong number of arguments.\r\n", @conn.request('spushv roma')
  end

  def test_spushv_to_a_new_hash
    @conn.stats.address = 'vnodecommandtest'
    @conn.stats.port = Process.pid.to_s
    pend('spushv calls createhash with one argument, so it fails for a new hash') do
      assert_equal "READY\r\nSTORED\r\n", @conn.request('spushv newhash 0', stream(0, 'key1' => 'v'))
      assert_equal 'v', @conn.storages['newhash'].get(0, 'key1', 0)
    end
  ensure
    @conn.storages['newhash']&.closedb
    FileUtils.rm_rf("#{Roma::Config::STORAGE_PATH}/#{@conn.stats.ap_str}")
  end

  def test_reqpushv
    assert_equal "PUSHED\r\n", @conn.request("reqpushv 0 #{OTHER_NID} true")
    msg = Roma::AsyncProcess.queue.pop
    assert_equal ['reqpushv', ['0', OTHER_NID, 'true']], [msg.event, msg.args]
  end

  data('iterating storage' => :run_iterate_storage, 'joining' => :run_join, 'balancing' => :run_balance)
  def test_reqpushv_rejected(flag)
    @conn.stats.send("#{flag}=", true)
    assert_equal "REJECTED\r\n", @conn.request("reqpushv 0 #{OTHER_NID} true")
    assert_true Roma::AsyncProcess.queue.empty?
  end

  def test_reqpushv_usage
    assert_equal "CLIENT_ERROR usage:reqpushv vnode-id node-id primary-flag(true/false)\r\n",
                 @conn.request('reqpushv 0')
  end
end

class BackgroundCommandTest < Test::Unit::TestCase
  include ReceiverCommandTestHelper

  # Makes this node primary of fewer vnodes than its share.
  def unbalance
    @conn.rttable.each_vnode { |vn, _| @conn.rttable.set_route(vn, @conn.rttable.search_nodes_with_clk(vn)[0], [OTHER_NID, NID]) }
  end

  def test_balance
    unbalance
    @conn.relay_reply = 'STARTED'
    assert_equal replies('STARTED', other: 'STARTED'), @conn.request('balance')
    assert_equal ["rbalance\r\n"], @conn.broadcasts
    assert_equal ['start_balance_process'], queued_events
  end

  def test_balance_when_balanced
    @conn.relay_reply = 'SERVER_ERROR'
    assert_equal replies('SERVER_ERROR Not unbalance or othre process is already running.', other: 'SERVER_ERROR'),
                 @conn.request('balance')
    assert_equal [], queued_events
  end

  def test_rbalance
    assert_equal "SERVER_ERROR Not unbalance or other process is already running.\r\n", @conn.request('rbalance')
    unbalance
    assert_equal "STARTED\r\n", @conn.request('rbalance')
    @conn.stats.run_join = true
    assert_equal "SERVER_ERROR Not unbalance or other process is already running.\r\n", @conn.request('rbalance')
    assert_equal ['start_balance_process'], queued_events
  end

  def test_release
    assert_equal "STARTED\r\n", @conn.request('release')
    @conn.stats.run_release = true
    assert_equal "SERVER_ERROR Other process is already running.\r\n", @conn.request('release')
    assert_equal ['start_release_process'], queued_events
  end

  def test_recover
    @conn.relay_reply = 'STARTED'
    assert_equal replies('STARTED', other: 'STARTED'), @conn.request('recover')
    assert_equal ["rrecover\r\n"], @conn.broadcasts
    @conn.stats.run_recover = true
    assert_equal replies('SERVER_ERROR Recover process is already running.', other: 'STARTED'), @conn.request('recover')
    assert_equal ['start_recover_process'], queued_events
  end

  def test_rrecover
    assert_equal "STARTED\r\n", @conn.request('rrecover')
    @conn.stats.run_recover = true
    assert_equal "SERVER_ERROR Recover process is already running.\r\n", @conn.request('rrecover')
    assert_equal ['start_recover_process'], queued_events
  end

  # With fewer nodes than the redundancy, the vnodes can't be recovered.
  data('recover' => 'recover', 'rrecover' => 'rrecover')
  def test_recover_without_enough_nodes(command)
    @conn.rttable.instance_variable_get(:@rd).nodes.delete(OTHER_NID)
    assert_equal "SERVER_ERROR nodes num < redundant num\r\n", @conn.request(command)
  end
end

class MultiHashCommandTest < Test::Unit::TestCase
  include ReceiverCommandTestHelper

  def setup
    super
    # Hashes are made in Roma::Config::STORAGE_PATH, named after this node.
    @conn.stats.address = 'multihashcommandtest'
    @conn.stats.port = Process.pid.to_s
    @path = "#{Roma::Config::STORAGE_PATH}/#{@conn.stats.ap_str}"
  end

  def teardown
    @conn.storages.each { |name, st| st.closedb unless name == 'roma' }
    FileUtils.rm_rf(@path)
    super
  end

  # Relayed by def_command_with_relay, which puts this node's reply first.
  def replies(reply, other: 'STORED')
    "#{{ @conn.stats.ap_str => reply, OTHER_NID => other }}\r\n"
  end

  def test_defhash
    assert_equal replies('roma'), @conn.request('defhash')
    assert_equal replies('STORED'), @conn.request('defhash roma')
    assert_equal "CLIENT_ERROR none does not find.\r\n", @conn.request('defhash none')
    assert_equal ["rdefhash \r\n", "rdefhash roma\r\n"], @conn.broadcasts
  end

  def test_createhash_and_deletehash
    @conn.relay_reply = 'CREATED'
    assert_equal replies('CREATED', other: 'CREATED'), @conn.request('createhash hash1')
    assert_equal "roma hash1\r\n", @conn.request('hashlist')
    assert_equal "SERVER_ERROR hash1 already exists.\r\n", @conn.request('rcreatehash hash1')

    # The files of the hash are deleted too.
    FileUtils.mkdir_p("#{@path}/hash1")
    assert_equal "DELETED\r\n", @conn.request('rdeletehash hash1')
    assert_equal "roma\r\n", @conn.request('hashlist')
    assert_false File.exist?("#{@path}/hash1")
  end

  def test_mounthash_and_umounthash
    @conn.request('rcreatehash hash1')
    # RubyHashStorage keeps no files; make the directory a hash would have.
    FileUtils.mkdir_p("#{@path}/hash1")
    assert_equal "UNMOUNTED\r\n", @conn.request('rumounthash hash1')
    assert_equal "roma\r\n", @conn.request('hashlist')
    # The files stay, so it can be mounted again.
    assert_equal "MOUNTED\r\n", @conn.request('rmounthash hash1')
    assert_equal "roma hash1\r\n", @conn.request('hashlist')
    assert_equal "SERVER_ERROR hash1 already mounted.\r\n", @conn.request('rmounthash hash1')
  end

  def test_errors
    assert_equal "SERVER_ERROR nohash does not find.\r\n", @conn.request('rmounthash nohash')
    assert_equal "SERVER_ERROR nohash does not find.\r\n", @conn.request('rumounthash nohash')
    assert_equal "SERVER_ERROR nohash does not exists.\r\n", @conn.request('rdeletehash nohash')
    assert_equal "SERVER_ERROR default hash can't unmount.\r\n", @conn.request('rumounthash roma')
    %w(createhash deletehash mounthash umounthash).each do |command|
      assert_equal "CLIENT_ERROR usage:#{command} <name>\r\n", @conn.request("r#{command}")
    end
  end
end

class UtilCommandTest < Test::Unit::TestCase
  include ReceiverCommandTestHelper

  def test_chg_time_expt
    assert_equal 0x7fffffff, @conn.chg_time_expt(0)
    # Less than 30 days is relative.
    assert_in_delta Time.now.to_i + 100, @conn.chg_time_expt(100), 2
    assert_equal 2_592_000, @conn.chg_time_expt(2_592_000)
  end

  def test_async_send_cmd
    node = FakeNode.new
    assert_equal 'ROMA', @conn.async_send_cmd(node.nid, "whoami\r\n")
    # The node is down.
    assert_nil @conn.async_send_cmd('localhost_1', "whoami\r\n")
  ensure
    node&.close
    Roma::Messaging::ConPool.instance.close_all
  end

  def test_async_broadcast_cmd
    node = FakeNode.new
    @conn.rttable.add_node(node.nid)
    res = @conn.async_broadcast_cmd("whoami\r\n", [NID, OTHER_NID])
    assert_equal({ node.nid => 'ROMA' }, res)
  ensure
    node&.close
    Roma::Messaging::ConPool.instance.close_all
  end
end

class GuiAndDebugPluginTest < Test::Unit::TestCase
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
