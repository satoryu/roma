require 'test_helper'
require 'stringio'
require 'tmpdir'
require 'logger'
require 'roma/romad'
require 'fake_node'

# Unit tests for Roma::Romad.
#
# Romad.new loads the config file and replaces process-wide objects such as
# the logger, so each test makes a Romad with allocate, sets what it needs,
# and calls the private methods. Other nodes are FakeNodes.
module RomadTestHelper
  NID = 'localhost_11211'
  OTHER_NID = 'localhost_11212'

  def setup
    @dir = Dir.mktmpdir('roma_romad')
    @nodes = []
    @saved_ev_list = Roma::Event::Handler.ev_list.dup
    @saved_system_commands = Roma::Event::Handler.system_commands.dup
  end

  def teardown
    @romad&.rttable&.close_log
    @nodes&.each(&:close)
    Roma::Messaging::ConPool.instance.close_all
    Roma::AsyncProcess.queue.clear
    Roma::Event::Handler.ev_list.replace(@saved_ev_list)
    Roma::Event::Handler.system_commands.replace(@saved_system_commands)
    FileUtils.rm_rf(@dir)
  end

  def fake_node
    FakeNode.new.tap { |node| @nodes << node }
  end

  # A Romad of +ap+ whose routing table has +nodes+, each vnode on all of
  # them.
  def romad(ap: NID, nodes: [NID, OTHER_NID])
    @romad = Roma::Romad.allocate
    stats = Roma::Stats.send(:new)
    stats.address, stats.port = ap.split('_')
    stats.name = 'ROMA'
    rd = Roma::Routing::RoutingData.create(32, 3, 2, nodes)
    rd.v_idx.each_key { |vn| rd.v_idx[vn] = nodes.dup }
    set(stats: stats, log: Logger.new(nil), startup: true,
        rttable: Roma::Routing::ChurnbasedRoutingTable.new(rd, File.join(@dir, 'test.route')),
        storages: {})
    @romad
  end

  def set(**ivars)
    ivars.each { |name, value| @romad.instance_variable_set("@#{name}", value) }
  end

  def call(name, *args)
    @romad.send(name, *args)
  end

  # Answers async_send_cmd from +replies+, by command name, and records the
  # commands.
  def stub_send_cmd(replies)
    sent = []
    @romad.singleton_class.send(:remove_method, :async_send_cmd) if @romad.singleton_methods.include?(:async_send_cmd)
    @romad.define_singleton_method(:async_send_cmd) do |nid, cmd, _tout = nil|
      sent << [nid, cmd]
      reply = replies[cmd.split(' ').first]
      reply.respond_to?(:call) ? reply.call(nid, cmd) : reply
    end
    sent
  end
end

class RomadOptionsTest < Test::Unit::TestCase
  include RomadTestHelper

  def setup
    super
    @romad = Roma::Romad.allocate
    set(stats: Roma::Stats.send(:new))
    # options requires the config file; this one is new, so it is loaded.
    @config = File.join(@dir, 'config.rb')
    File.write(@config, "# Roma::Config is loaded already.\n")
  end

  def teardown
    @romad = nil
    super
  end

  def stats
    @romad.stats
  end

  # options exits on invalid options; make that a failure, not the end of
  # the test run.
  def parse(args)
    err = StringIO.new
    saved = $stderr
    $stderr = err
    call(:options, ['--config', @config, *args])
  rescue SystemExit
    flunk("options exited: #{err.string}")
  ensure
    $stderr = saved
  end

  def test_defaults
    parse(['roma0'])
    assert_equal 'roma0', stats.address
    assert_equal Roma::Config::DEFAULT_PORT.to_s, stats.port
    assert_equal Roma::Config::DEFAULT_NAME, stats.name
    assert_equal File.expand_path(@config), stats.config_path
    assert_false stats.daemon
    assert_false stats.verbose
    assert_false stats.enabled_repetition_host_in_routing
    assert_false stats.disabled_cmd_protect
    assert_nil stats.join_ap
  end

  def test_options
    parse(['-d', '-p', '11300', '-n', 'cluster', '-j', 'roma1:11211',
           '--verbose', '--replication_in_host', '--disabled_cmd_protect', 'roma0'])
    assert_equal '11300', stats.port
    assert_equal 'cluster', stats.name
    assert_equal 'roma1_11211', stats.join_ap
    assert_true stats.daemon
    assert_true stats.verbose
    assert_true stats.enabled_repetition_host_in_routing
    assert_true stats.disabled_cmd_protect
  end

  def test_enabled_repeathost_is_deprecated
    out = capture_stdout { parse(['--enabled_repeathost', 'roma0']) }
    assert_true stats.enabled_repetition_host_in_routing
    assert_match(/deplicated/, out)
  end

  data('no address' => [],
       'port not numeric' => ['-p', 'abc', 'roma0'],
       'join without a port' => ['-j', 'roma1', 'roma0'])
  def test_invalid_options(args)
    err = capture_stderr do
      assert_raise(SystemExit) { call(:options, ['--config', @config, *args]) }
    end
    assert_match(/usage:/, err)
  end

  def test_config_loaded_already
    parse(['roma0'])
    @romad.instance_variable_set(:@stats, Roma::Stats.send(:new))
    assert_raise(RuntimeError) { call(:options, ['--config', @config, 'roma0']) }
  end

  def capture_stdout
    saved = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = saved
  end

  def capture_stderr
    saved = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = saved
  end
end

class RomadInitializeTest < Test::Unit::TestCase
  include RomadTestHelper

  def setup
    super
    @romad = Roma::Romad.allocate
    stats = Roma::Stats.send(:new)
    # Files are made in Roma::Config::RTTABLE_PATH and STORAGE_PATH, named
    # after this node.
    stats.address = 'romadtest'
    stats.port = Process.pid.to_s
    stats.name = 'ROMA'
    set(stats: stats, log: Logger.new(nil))
    @files = []
  end

  def teardown
    @files.each { |f| FileUtils.rm_rf(f) }
    super
  end

  def ap
    @romad.stats.ap_str
  end

  # The routing file of this node, and its log, which the routing table
  # writes next to it.
  def routing_file
    fname = "#{Roma::Config::RTTABLE_PATH}/#{ap}.route"
    @files.push(fname, "#{fname}.1")
    fname
  end

  def save_routing(nodes)
    Roma::Routing::RoutingData.create(32, 3, 2, nodes).save(routing_file)
  end

  def test_initialize_stats
    call(:initialize_stats)
    assert_equal Roma::Config::LOG_SHIFT_AGE, @romad.stats.log_shift_age if defined?(Roma::Config::LOG_SHIFT_AGE)
    assert_equal Roma::Config::LOG_LEVEL, @romad.stats.log_level if defined?(Roma::Config::LOG_LEVEL)
    assert_equal Roma::Config::STORAGE_CLEAN_UP_INTERVAL, @romad.stats.clean_up_interval
  end

  def test_initialize_rttable
    save_routing([ap, OTHER_NID])
    call(:initialize_rttable)
    rttable = @romad.rttable
    assert_equal [OTHER_NID, ap].sort, rttable.nodes.sort
    assert_equal Roma::Config::DEFAULT_LOST_ACTION, rttable.lost_action
    assert_equal Roma::Config::ROUTING_FAIL_CNT_THRESHOLD, rttable.fail_cnt_threshold
    assert_equal Roma::Config::ROUTING_EVENT_LIMIT_LINE, rttable.event_limit_line
    assert_false rttable.enabled_failover
    assert_equal 'start_get_routing_event', Roma::AsyncProcess.queue.pop.event
  end

  def test_initialize_rttable_without_a_file
    assert_raise_message(/not found/) { call(:initialize_rttable) }
  end

  def test_leave_proc
    save_routing([ap, OTHER_NID])
    call(:initialize_rttable)
    Roma::AsyncProcess.queue.clear
    @romad.rttable.enabled_failover = true
    @romad.rttable.leave(OTHER_NID)
    msg = Roma::AsyncProcess.queue.pop
    assert_equal ['broadcast_cmd', ["leave #{OTHER_NID}", [ap, OTHER_NID, 5]]], [msg.event, msg.args]
  end

  data('auto recover on' => [true, 1], 'auto recover off' => [false, 0])
  def test_recover_proc(data)
    auto_recover, messages = data
    save_routing([ap, OTHER_NID])
    call(:initialize_rttable)
    Roma::AsyncProcess.queue.clear
    @romad.rttable.auto_recover = auto_recover
    @romad.rttable.instance_variable_get(:@recover_proc).call('start_auto_recover_process')
    assert_equal messages, Roma::AsyncProcess.queue.size
  end

  def test_initialize_storages
    save_routing([ap, OTHER_NID])
    call(:initialize_rttable)
    path = "#{Roma::Config::STORAGE_PATH}/#{ap}"
    @files << path
    call(:initialize_storages)
    assert_equal ['roma'], @romad.storages.keys
    assert_equal "#{path}/roma", @romad.storages['roma'].instance_variable_get(:@storage_path)

    # A storage for each directory.
    FileUtils.mkdir_p(["#{path}/hash1", "#{path}/hash2"])
    call(:initialize_storages)
    assert_equal %w(hash1 hash2), @romad.storages.keys.sort
  end

  def test_initialize_wb_writer
    call(:initialize_wb_writer)
    assert_kind_of Roma::WriteBehind::FileWriter, @romad.wb_writer
    assert_kind_of Roma::WriteBehind::StreamWriter, @romad.cr_writer
  end

  # Joining an existing cluster gets the routing table from a node of it.
  def test_initialize_rttable_join
    node = fake_node
    rd = Roma::Routing::RoutingData.create(32, 3, 2, [node.nid])
    node.replies['routingdump'] = "#{rd.dump_binary.bytesize}\r\n#{rd.dump_binary}\r\nEND\r\n"
    node.replies['join'] = "ADDED\r\n"
    @romad.stats.join_ap = node.nid
    fname = routing_file
    call(:initialize_rttable)
    assert_equal [node.nid, ap].sort, @romad.rttable.nodes.sort
    assert_include node.commands, "join #{ap}"
    # The routing table is saved for the next start.
    assert_true File.exist?(fname)
  end

  def test_initialize_rttable_join_errors
    node = fake_node
    @romad.stats.join_ap = 'localhost_1'
    assert_raise_message(/No respons/) { call(:initialize_rttable_join) }

    @romad.stats.join_ap = node.nid
    @romad.stats.name = 'other'
    assert_raise_message(/diffarent name/) { call(:initialize_rttable_join) }

    @romad.stats.name = 'ROMA'
    node.replies['routingdump'] = "0\r\n"
    assert_raise_message(/failed in getting the routing table/) { call(:initialize_rttable_join) }

    routing_file
    rd = Roma::Routing::RoutingData.create(32, 3, 2, [node.nid, ap])
    node.replies['routingdump'] = "#{rd.dump_binary.bytesize}\r\n#{rd.dump_binary}\r\nEND\r\n"
    assert_raise_message(/already contained/) { call(:initialize_rttable_join) }

    rd = Roma::Routing::RoutingData.create(32, 3, 2, [node.nid])
    node.replies['routingdump'] = "#{rd.dump_binary.bytesize}\r\n#{rd.dump_binary}\r\nEND\r\n"
    node.replies['join'] = "SERVER_ERROR busy\r\n"
    assert_raise_message(/Hotscale initialize failed/) { call(:initialize_rttable_join) }
  ensure
    @romad.rttable&.close_log
  end
end

class RomadTimerTest < Test::Unit::TestCase
  include RomadTestHelper

  def test_timer_event_10sec_at_startup
    # At startup, it first checks that the node accepts connections.
    node = fake_node
    romad(nodes: [NID, node.nid])
    stub_send_cmd('whoami' => 'ROMA')
    Roma::AsyncProcess.queue.push(Roma::AsyncMessage.new('start_get_routing_event'))
    call(:timer_event_10sec)
    # Once all the nodes answer, failover is enabled.
    assert_true @romad.rttable.enabled_failover
    assert_false @romad.startup
    assert_true Roma::AsyncProcess.queue.empty?
  end

  def test_timer_event_10sec_waiting_for_nodes
    romad
    call(:timer_event_10sec)
    # OTHER_NID isn't running.
    assert_false @romad.rttable.enabled_failover
    assert_true @romad.startup
  end

  def test_timer_event_10sec_while_failover_is_disabled
    romad
    set(startup: false, cr_writer: Struct.new(:run_replication).new(false))
    sent = stub_send_cmd({})
    call(:timer_event_10sec)
    assert_equal [], sent
  end

  def test_timer_event_10sec
    romad
    cr_writer = Struct.new(:run_replication, :replica_nodelist, :updated) do
      def change_mklhash? = true
      def update_mklhash(nid) = (self.updated = [nid])
      def update_nodelist(nid) = updated << nid
      def update_rttable(nid) = updated << nid
    end.new(true, ['localhost_21211'])
    set(startup: false, cr_writer: cr_writer)
    @romad.stats.last_clean_up = Time.at(0)
    @romad.stats.run_sync_routing = true # Don't start syncing the routing table.
    @romad.rttable.enabled_failover = true
    # Counters are reset when they pass 32 bits.
    @romad.stats.write_count = 0x100000000
    sent = stub_send_cmd('version' => 'VERSION ROMA-1.2.3')
    call(:timer_event_10sec)
    # Checks the versions of the nodes.
    assert_equal [[NID, "version\r\n"], [OTHER_NID, "version\r\n"]], sent
    assert_equal (1 << 16) + (2 << 8) + 3, @romad.rttable.min_version
    # Starts cleaning up the storages.
    assert_equal 'start_storage_clean_up_process', Roma::AsyncProcess.queue.pop.event
    # Updates the replica cluster's information.
    assert_equal ['localhost_21211'] * 3, cr_writer.updated
    assert_equal 0, @romad.stats.write_count
  end

  def test_timer_event_1sec
    romad
    @romad.rttable.enabled_failover = true
    sent = stub_send_cmd('whoami' => 'ROMA')
    set(startup: false)
    call(:timer_event_1sec)
    # Checks the other nodes.
    assert_equal [[OTHER_NID, "whoami\r\n"]], sent
  end

  def test_timer_event_1sec_stops_clean_up_while_joining
    romad
    storage = Object.new
    def storage.stop_clean_up = (@stopped = true)
    def storage.stopped? = @stopped
    set(storages: { 'roma' => storage })
    @romad.stats.run_join = true
    @romad.stats.run_storage_clean_up = true
    Thread.new { Kernel.sleep 0.05; @romad.stats.run_storage_clean_up = false }
    call(:timer_event_1sec)
    assert_true storage.stopped?
  end

  def test_node_check
    romad
    set(startup: false)
    stub_send_cmd('whoami' => 'ROMA')
    assert_true call(:node_check, OTHER_NID)
    stub_send_cmd('whoami' => 'OTHER')
    assert_false call(:node_check, OTHER_NID)
    stub_send_cmd('whoami' => nil)
    assert_false call(:node_check, OTHER_NID)
  end
end

class RomadRoutingSyncTest < Test::Unit::TestCase
  include RomadTestHelper

  def test_routing_hash_comparison_consistent
    romad
    stub_send_cmd('mklhash' => ->(_nid, cmd) { @romad.rttable.mtree.get(cmd.split(' ')[1].chomp) })
    assert_equal :consistent, call(:routing_hash_comparison, OTHER_NID)
  end

  # The other node has another route of one vnode, with a newer clock.
  def test_routing_hash_comparison_inconsistent
    romad
    other = Roma::Routing::ChurnbasedRoutingTable.new(
      Marshal.load(Marshal.dump(@romad.rttable.instance_variable_get(:@rd))), File.join(@dir, 'other.route'))
    vn = other.v_idx.keys[3]
    other.set_route(vn, 0, [OTHER_NID])
    sent = stub_send_cmd(
      'mklhash' => ->(_nid, cmd) { other.mtree.get(cmd.split(' ')[1].chomp) },
      'getroute' => ->(_nid, _cmd) { clk, nids = other.search_nodes_with_clk(vn); "#{clk} #{nids.join(' ')}" }
    )
    assert_equal :inconsistent, call(:routing_hash_comparison, OTHER_NID)
    assert_equal [OTHER_NID], @romad.rttable.search_nodes(vn)
    assert_include sent, [OTHER_NID, "getroute #{vn}\r\n"]
  ensure
    other&.close_log
  end

  def test_sync_routing_with_an_older_route
    romad
    vn = @romad.rttable.v_idx.keys[0]
    @romad.rttable.set_route(vn, 0, [NID])
    # The other node's route is older than ours (clock 1); send it ours, with
    # the clock to give setroute.
    sent = stub_send_cmd('getroute' => "0 #{OTHER_NID}", 'setroute' => 'STORED')
    # The id of a vnode's leaf in the Merkle tree: '0' and the vnode's bits.
    call(:sync_routing, OTHER_NID, "0#{(vn >> 29).to_s(2).rjust(3, '0')}")
    assert_equal [NID], @romad.rttable.search_nodes(vn)
    assert_equal [OTHER_NID, "setroute #{vn} 0 #{NID}\r\n"], sent.last
  end

  def test_routing_hash_comparison_while_joining
    romad
    @romad.stats.run_join = true
    assert_equal :skip, call(:routing_hash_comparison, OTHER_NID)
  end

  def test_start_sync_routing_process
    romad
    stub_send_cmd('mklhash' => ->(_nid, cmd) { @romad.rttable.mtree.get(cmd.split(' ')[1].chomp) })
    call(:start_sync_routing_process)
    deadline = Time.now + 5
    Kernel.sleep 0.01 while @romad.stats.run_sync_routing && Time.now < deadline
    assert_false @romad.stats.run_sync_routing
  end

  def test_start_sync_routing_process_alone
    romad(nodes: [NID])
    call(:start_sync_routing_process)
    assert_false @romad.stats.run_sync_routing
  end
end

class RomadSendCmdTest < Test::Unit::TestCase
  include RomadTestHelper

  def setup
    super
    @node = fake_node
    romad(nodes: [NID, @node.nid])
  end

  def test_async_send_cmd
    assert_equal 'ROMA', call(:async_send_cmd, @node.nid, "whoami\r\n")
    assert_equal 'ROMA', call(:async_send_cmd, @node.nid, "whoami\r\n", 1)
    @node.replies['stat'] = "ERROR\r\n"
    assert_equal 'ERROR', call(:async_send_cmd, @node.nid, "stat\r\n")
  end

  def test_async_send_cmd_to_a_node_that_is_down
    assert_nil call(:async_send_cmd, 'localhost_1', "whoami\r\n")
    assert_nil call(:async_send_cmd, 'localhost_1', "whoami\r\n", 1)
    assert_equal 2, @romad.rttable.fail_cnt['localhost_1']
  end

  def test_async_send_cmd_without_a_reply
    @node.replies['quit'] = :close
    assert_nil call(:async_send_cmd, @node.nid, "quit\r\n")
  end

  def test_async_broadcast_cmd
    # Not to this node.
    assert_equal({ @node.nid => 'ROMA' }, call(:async_broadcast_cmd, "whoami\r\n"))
    assert_equal [NID], call(:async_broadcast_cmd, "whoami\r\n", [@node.nid], 1).keys
  end

  def test_version_check
    @node.replies['version'] = "VERSION ROMA-1.2.3\r\n"
    call(:version_check)
    assert_equal({ @node.nid => (1 << 16) + (2 << 8) + 3 }, @romad.rttable.version_of_nodes)
  end

  def test_receive_routing_dump
    rd = @romad.rttable.instance_variable_get(:@rd)
    @node.replies['routingdump'] = "#{rd.dump_binary.bytesize}\r\n#{rd.dump_binary}\r\nEND\r\n"
    got = call(:get_routedump, @node.nid)
    assert_equal rd.v_idx, got.v_idx
  end

  def test_get_routedump_falls_back_to_marshal
    rd = @romad.rttable.instance_variable_get(:@rd)
    dump = Marshal.dump(rd)
    @node.replies['routingdump'] = lambda do |line|
      line.include?('bin') ? "0\r\n" : "#{dump.bytesize}\r\n#{dump}\r\nEND\r\n"
    end
    assert_equal rd.v_idx, call(:get_routedump, @node.nid).v_idx
  end

  def test_stop
    storage = Object.new
    def storage.closedb = (@closed = true)
    def storage.closed? = @closed
    set(storages: { 'roma' => storage })
    call(:stop)
    assert_true storage.closed?
  end

  def test_stop_clean_up
    @romad.stats.run_storage_clean_up = false
    call(:stop_clean_up)
    assert_not_nil @romad.stats.last_clean_up
  end

  def test_daemon
    @romad.stats.daemon = true
    assert_true @romad.daemon?
  end
end
