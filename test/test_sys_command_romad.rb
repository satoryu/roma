require 'test_helper'
require 'zlib'
require 'command_test_harness'

# Unit tests for the system commands that work on this node's romad: the
# write-behind files, cluster replication, storages and node information.
class SysCommandRomadTest < Test::Unit::TestCase
  NID = CommandTestHarness::NID
  OTHER_NID = CommandTestHarness::OTHER_NID

  def setup
    @conn = CommandTestHarness.new
  end

  def teardown
    @conn.close
    Roma::AsyncProcess.queue.clear
  end

  def replies(reply, other: 'STORED')
    "#{{ OTHER_NID => other, NID => reply }}\r\n"
  end

  def test_version
    assert_equal "VERSION ROMA-#{Roma::VERSION}\r\n", @conn.request('version')
  end

  def test_whoami
    @conn.stats.name = 'ROMA'
    assert_equal "ROMA\r\n", @conn.request('whoami')
  end

  def test_stat
    lines = @conn.request('stat').split("\r\n")
    assert_equal 'END', lines.last
    keys = lines[0..-2].map { |line| line.split(' ', 2).first }
    assert_include keys, 'version'
    assert_include keys, 'config.LOG_PATH'
    assert_include keys, 'stats.address'
    assert_include keys, 'storages[roma].storage.divnum'
    assert_include keys, 'write-behind.run_replication'
    assert_include keys, 'routing.nodes'
    assert_include keys, 'connection.count'
    assert_include keys, 'dns_caching'
  end

  def test_stat_with_regexp
    assert_equal "stats.hilatency_warn_time 5.0\r\nEND\r\n", @conn.request('stat hilatency')
    assert_equal "routing.redundant 2\r\nEND\r\n", @conn.request('stats routing.redundant')
    assert_equal "END\r\n", @conn.request('stat no_such_key')
  end

  def test_writebehind_rotate
    @conn.romad.wb_current_files['roma'] = 'wb/0.wb'
    @conn.relay_reply = 'ROTATED'
    assert_equal replies('ROTATED', other: 'ROTATED'), @conn.request('writebehind_rotate roma')
    assert_equal ["rwritebehind_rotate roma\r\n"], @conn.broadcasts
    assert_equal ['roma'], @conn.romad.rotated

    # Nothing to rotate once the file is closed.
    assert_equal "NOT_OPEND\r\n", @conn.request('rwritebehind_rotate roma')
  end

  def test_writebehind_get_path
    @conn.relay_reply = 'wb/localhost_11212/roma'
    assert_equal replies("wb/#{NID}/roma", other: 'wb/localhost_11212/roma'),
                 @conn.request('writebehind_get_path roma')
    assert_equal ["rwritebehind_get_path roma\r\n"], @conn.broadcasts
    assert_equal "wb/#{NID}/roma\r\n", @conn.request('rwritebehind_get_path roma')
  end

  def test_writebehind_get_current_file
    @conn.relay_reply = 'NOT_OPEND'
    assert_equal replies('NOT_OPEND', other: 'NOT_OPEND'), @conn.request('writebehind_get_current_file roma')
    @conn.romad.wb_current_files['roma'] = 'wb/0.wb'
    assert_equal replies('wb/0.wb', other: 'NOT_OPEND'), @conn.request('writebehind_get_current_file roma')
    assert_equal "wb/0.wb\r\n", @conn.request('rwritebehind_get_current_file roma')
  end

  data('writebehind_rotate' => 'writebehind_rotate',
       'writebehind_get_path' => 'writebehind_get_path',
       'writebehind_get_current_file' => 'writebehind_get_current_file')
  def test_writebehind_commands_need_a_hash_name(command)
    assert_equal "CLIENT_ERROR number of arguments (0 for 1)\r\n", @conn.request(command)
    assert_equal "CLIENT_ERROR number of arguments (0 for 1)\r\n", @conn.request("r#{command}")
    assert_equal [], @conn.broadcasts
  end

  def test_switch_replication_on_and_off
    cr = @conn.romad.cr_writer
    @conn.relay_reply = 'ACTIVATED'
    assert_equal replies('ACTIVATED', other: 'ACTIVATED'), @conn.request('switch_replication true localhost_21211')
    assert_equal ["rswitch_replication true localhost_21211 \r\n"], @conn.broadcasts
    assert_true cr.run_replication
    assert_false cr.run_existing_data_replication
    assert_equal 'mklhash of localhost_21211', cr.replica_mklhash
    assert_equal ['localhost_21211'], cr.replica_nodelist
    assert_true Roma::AsyncProcess.queue.empty?

    @conn.relay_reply = 'DEACTIVATED'
    assert_equal replies('DEACTIVATED', other: 'DEACTIVATED'), @conn.request('switch_replication false')
    assert_false cr.run_replication
    assert_nil cr.replica_mklhash
    assert_equal [], cr.replica_nodelist
    assert_nil cr.replica_rttable
  end

  def test_switch_replication_with_existing_data
    @conn.relay_reply = 'ACTIVATED'
    @conn.request('switch_replication true localhost_21211 all')
    assert_true @conn.romad.cr_writer.run_existing_data_replication
    assert_equal 1, Roma::AsyncProcess.queue.size
    msg = Roma::AsyncProcess.queue.pop
    assert_equal 'start_replicate_existing_data_process', msg.event
    assert_equal ['rttable of localhost_21211'], msg.args
  end

  def test_rswitch_replication
    cr = @conn.romad.cr_writer
    assert_equal "ACTIVATED\r\n", @conn.request('rswitch_replication true localhost_21211')
    assert_true cr.run_replication
    assert_equal "DEACTIVATED\r\n", @conn.request('rswitch_replication false')
    assert_false cr.run_replication
    assert_equal [], @conn.broadcasts
  end

  data('too many arguments' => ['true localhost_21211 hoge fuga', "CLIENT_ERROR number of arguments\r\n"],
       'copy target' => ['true localhost_21211 false', "CLIENT_ERROR [copy target] must be all or nil\r\n"],
       'value' => ['on localhost_21211', "CLIENT_ERROR value must be true or false\r\n"])
  def test_switch_replication_with_invalid_arguments(data)
    args, reply = data
    assert_equal reply, @conn.request("switch_replication #{args}")
    assert_equal reply, @conn.request("rswitch_replication #{args}")
    assert_equal [], @conn.broadcasts
    assert_false @conn.romad.cr_writer.run_replication
  end

  # priority => [stream_copy_wait_param, each_vn_dump_sleep, each_vn_dump_sleep_count]
  data(1 => [0.001, 0.001, 1000], 2 => [0.005, 0.005, 100], 3 => [0.01, 0.001, 10],
       4 => [0.01, 0.005, 10], 5 => [0.01, 0.01, 10])
  def test_dcnice(data)
    priority = data_label
    wait, sleep, count = data
    assert_equal replies('STORED'), @conn.request("dcnice #{priority}")
    assert_equal ["rdcnice #{priority}\r\n"], @conn.broadcasts
    assert_equal priority.to_i, @conn.stats.dcnice
    assert_equal wait, @conn.stats.stream_copy_wait_param
    assert_equal sleep, @conn.storage.each_vn_dump_sleep
    assert_equal count, @conn.storage.each_vn_dump_sleep_count
    assert_equal "STORED\r\n", @conn.request("rdcnice #{priority}")
  end

  def test_dcnice_with_invalid_priority
    error = 'CLIENT_ERROR You sholud input a priority from 1 to 5.'
    assert_equal replies(error), @conn.request('dcnice 6')
    assert_equal "#{error}\r\n", @conn.request('rdcnice 0')
    assert_equal "CLIENT_ERROR number of arguments (0 for 1)\r\n", @conn.request('dcnice')
    assert_equal 3, @conn.stats.dcnice
  end

  def test_out
    vn = @conn.rttable.get_vnode_id(Digest::SHA1.hexdigest('key1').hex % @conn.rttable.hbits)
    @conn.storage.set(vn, 'key1', 0, 0x7fffffff, 'value1')
    assert_equal "DELETED\r\n", @conn.request('out key1')
    assert_nil @conn.storage.get(vn, 'key1', 0)
    assert_equal "NOT_DELETED\r\n", @conn.request('out key1')
    assert_equal 2, @conn.stats.out_message_count
  end

  def test_rset
    assert_equal "STORED\r\n", @conn.request('rset key1 0 1 2147483647 6', 'value1')
    vn = @conn.rttable.get_vnode_id(Digest::SHA1.hexdigest('key1').hex % @conn.rttable.hbits)
    assert_equal 'value1', @conn.storage.get(vn, 'key1', 0)
    assert_equal 1, @conn.stats.redundant_count
  end

  def test_rset_does_not_overwrite_a_newer_clock
    @conn.request('rset key1 0 5 2147483647 6', 'value1')
    assert_equal "NOT_STORED\r\n", @conn.request('rset key1 0 4 2147483647 6', 'value2')
  end

  def test_rzset
    zdata = Zlib::Deflate.deflate('value1')
    assert_equal "STORED\r\n", @conn.request("rzset key1 0 1 2147483647 #{zdata.bytesize}", zdata)
    vn = @conn.rttable.get_vnode_id(Digest::SHA1.hexdigest('key1').hex % @conn.rttable.hbits)
    assert_equal 'value1', @conn.storage.get(vn, 'key1', 0)
    assert_equal "NOT_STORED\r\n", @conn.request('rzset key2 0 1 0 6', 'broken')
  end

  def test_rset_to_unknown_hash
    assert_equal "SERVER_ERROR nohash does not exists.\r\n", @conn.request("rset key1\enohash 0 1 0 6", 'value1')
  end

  def test_set_storage_status_with_invalid_arguments
    assert_equal "CLIENT_ERROR number of arguments (1 for 2)\r\n", @conn.request('set_storage_status 0')
    assert_equal "CLIENT_ERROR divnum <= 10\r\n", @conn.request('set_storage_status 10 safecopy')
    assert_equal "CLIENT_ERROR status parse error\r\n", @conn.request('set_storage_status 0 hoge')
    assert_equal "CLIENT_ERROR storage[0] != :safecopy_flushed status\r\n",
                 @conn.request('set_storage_status 0 normal')
    assert_true Roma::AsyncProcess.queue.empty?
  end

  def test_set_storage_status_with_unknown_hash
    assert_equal "CLIENT_ERROR hash_name = nohash does not found\r\n",
                 @conn.request('set_storage_status 0 safecopy nohash')
  end

  def test_set_gui_run_snapshot
    assert_equal "STORED\r\n", @conn.request('set_gui_run_snapshot true')
    assert_true @conn.stats.gui_run_snapshot
    assert_equal "STORED\r\n", @conn.request('set_gui_run_snapshot false')
    assert_false @conn.stats.gui_run_snapshot
    assert_equal "CLIENT_ERROR value must be true or false\r\n", @conn.request('set_gui_run_snapshot yes')
  end

  def test_set_gui_last_snapshot
    assert_equal replies('PUSHED'), @conn.request('set_gui_last_snapshot 2026/10/31T12:00:00')
    assert_equal ["rset_gui_last_snapshot 2026/10/31T12:00:00\r\n"], @conn.broadcasts
    assert_equal '2026/10/31T12:00:00', @conn.stats.gui_last_snapshot
    assert_equal "PUSHED\r\n", @conn.request('rset_gui_last_snapshot 2026/11/01T00:00:00')
    assert_equal '2026/11/01T00:00:00', @conn.stats.gui_last_snapshot
    assert_equal "CLIENT_ERROR format is [%Y/%m/%dT%H:%M:%S]\r\n", @conn.request('set_gui_last_snapshot today')
  end

  def test_set_cleanup_regexp
    assert_equal "CLIENT_ERROR failover disable now!!\r\n", @conn.request('set_cleanup_regexp ^tmp')
    @conn.rttable.enabled_failover = true
    assert_equal "STORED\r\n", @conn.request('set_cleanup_regexp ^tmp')
    assert_equal '^tmp', @conn.storage.cleanup_regexp
    assert_equal "CLIENT_ERROR number of arguments 0 to 1\r\n", @conn.request('set_cleanup_regexp')
  end

  def test_forcedly_start
    Roma::AsyncProcess.queue.push(Roma::AsyncMessage.new('start_join_process'))
    assert_equal "STARTED\r\n", @conn.request('forcedly_start')
    assert_true @conn.rttable.enabled_failover
    assert_false @conn.romad.startup
    assert_true Roma::AsyncProcess.queue.empty?
  end
end
