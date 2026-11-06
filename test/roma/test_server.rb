require 'test_helper'
require 'stringio'
require 'tmpdir'
require 'logger'
require 'roma/server'
require 'fake_node'

# Unit tests for Roma::Server.
#
# Server.new loads the config file and replaces process-wide objects such as
# the logger, so each test makes a Server with allocate, sets what it needs,
# and calls the private methods. Other nodes are FakeNodes.
module ServerTestHelper
  NODE_ID = 'localhost_11211'
  OTHER_NODE_ID = 'localhost_11212'

  def setup
    @dir = Dir.mktmpdir('roma_server')
    @nodes = []
    @saved_event_list = Roma::Event::Handler.event_list.dup
    @saved_system_commands = Roma::Event::Handler.system_commands.dup
  end

  def teardown
    @server&.routing_table&.close_log
    @nodes&.each(&:close)
    Roma::Messaging::ConPool.instance.close_all
    Roma::AsyncProcess.queue.clear
    Roma::Event::Handler.event_list.replace(@saved_event_list)
    Roma::Event::Handler.system_commands.replace(@saved_system_commands)
    FileUtils.rm_rf(@dir)
  end

  def fake_node
    FakeNode.new.tap { |node| @nodes << node }
  end

  # A Server of +ap+ whose routing table has +nodes+, each vnode on all of
  # them.
  def server(ap: NODE_ID, nodes: [NODE_ID, OTHER_NODE_ID])
    @server = Roma::Server.allocate
    stats = Roma::Stats.send(:new)
    stats.address, stats.port = ap.split('_')
    stats.name = 'ROMA'
    routing_data = Roma::Routing::RoutingData.create(32, 3, 2, nodes)
    routing_data.routes.each_key { |vnode| routing_data.routes[vnode] = nodes.dup }
    set(stats: stats, log: Logger.new(nil), startup: true,
        routing_table: Roma::Routing::ChurnbasedRoutingTable.new(routing_data, File.join(@dir, 'test.route.yml')),
        storages: {})
    @server
  end

  def set(**ivars)
    ivars.each { |name, value| @server.instance_variable_set("@#{name}", value) }
  end

  def call(name, *)
    @server.send(name, *)
  end

  # Answers async_send_cmd from +replies+, by command name, and records the
  # commands.
  def stub_send_cmd(replies)
    sent = []
    @server.singleton_class.send(:remove_method, :async_send_cmd) if @server.singleton_methods.include?(:async_send_cmd)
    @server.define_singleton_method(:async_send_cmd) do |node_id, cmd, _tout = nil|
      sent << [node_id, cmd]
      reply = replies[cmd.split(' ').first]
      reply.respond_to?(:call) ? reply.call(node_id, cmd) : reply
    end
    sent
  end
end

class ServerOptionsTest < Test::Unit::TestCase
  include ServerTestHelper

  def setup
    super
    @server = Roma::Server.allocate
    set(stats: Roma::Stats.send(:new))
    @config = File.join(@dir, 'config.rb')
    File.write(@config, "Roma.configure { |config| config.name = 'test' }\n")
  end

  def teardown
    @server = nil
    Roma.reset_config
    super
  end

  def stats
    @server.stats
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
    assert_equal Roma.config.port.to_s, stats.port
    assert_equal 'test', stats.name
    assert_equal File.expand_path(@config), stats.config_path
    assert_false stats.daemon
    assert_false stats.verbose
    assert_false stats.replication_in_host
    assert_false stats.command_protection_disabled
    assert_nil stats.join_node_id
  end

  def test_options
    parse(['-d', '-p', '11300', '-n', 'cluster', '-j', 'roma1:11211',
           '--verbose', '--replication-in-host', '--disable-command-protection', 'roma0'])
    assert_equal '11300', stats.port
    assert_equal 'cluster', stats.name
    assert_equal 'roma1_11211', stats.join_node_id
    assert_true stats.daemon
    assert_true stats.verbose
    assert_true stats.replication_in_host
    assert_true stats.command_protection_disabled
  end

  # OptionParser takes the underscores too, as romad of ROMA 1.x had them.
  def test_options_with_underscores
    parse(['--replication_in_host', '--disable_command_protection', 'roma0'])
    assert_true stats.replication_in_host
    assert_true stats.command_protection_disabled
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

  # Without --config, the settings are kept.
  def test_without_config
    Roma.configure { |config| config.port = 11_300 }
    call(:options, ['roma0'])
    assert_equal '11300', stats.port
    assert_nil stats.config_path
  end

  def test_wrong_config
    File.write(@config, "Roma.configure { |config| config.port = 0 }\n")
    err = capture_stderr do
      assert_raise(SystemExit) { call(:options, ['--config', @config, 'roma0']) }
    end
    assert_equal "port should be a valid Integer: 0\n", err
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

class ServerInitializeTest < Test::Unit::TestCase
  include ServerTestHelper

  def setup
    super
    @server = Roma::Server.allocate
    stats = Roma::Stats.send(:new)
    # Files are made in Roma.config.routing.path and STORAGE_PATH, named
    # after this node.
    stats.address = 'servertest'
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
    @server.stats.my_node_id
  end

  # The routing file of this node, and its log, which the routing table
  # writes next to it.
  def routing_file
    fname = "#{Roma.config.routing.path}/#{ap}.route.yml"
    @files.push(fname, "#{Roma.config.routing.path}/#{ap}.route.1")
    fname
  end

  def save_routing(nodes)
    Roma::Routing::RoutingData.create(32, 3, 2, nodes).save(routing_file)
  end

  def test_initialize_stats
    call(:initialize_stats)
    assert_equal Roma.config.log.shift_age, @server.stats.log_shift_age
    assert_equal Roma.config.log.level, @server.stats.log_level
    assert_equal Roma.config.storage.clean_up_interval, @server.stats.clean_up_interval
  end

  def test_initialize_rttable
    save_routing([ap, OTHER_NODE_ID])
    call(:initialize_rttable)
    routing_table = @server.routing_table
    assert_equal [OTHER_NODE_ID, ap].sort, routing_table.nodes.sort
    assert_equal Roma.config.routing.lost_action, routing_table.lost_action
    assert_equal Roma.config.routing.failure_count_threshold, routing_table.failure_count_threshold
    assert_equal Roma.config.routing.event_limit_line, routing_table.event_limit_line
    assert_false routing_table.enabled_failover
    assert_equal 'start_get_routing_event', Roma::AsyncProcess.queue.pop.event
  end

  def test_initialize_rttable_without_a_file
    assert_raise_message(/not found/) { call(:initialize_rttable) }
  end

  def test_leave_proc
    save_routing([ap, OTHER_NODE_ID])
    call(:initialize_rttable)
    Roma::AsyncProcess.queue.clear
    @server.routing_table.enabled_failover = true
    @server.routing_table.leave(OTHER_NODE_ID)
    msg = Roma::AsyncProcess.queue.pop
    assert_equal ['broadcast_cmd', ["leave #{OTHER_NODE_ID}", [ap, OTHER_NODE_ID, 5]]], [msg.event, msg.args]
  end

  data('auto recover on' => [true, 1], 'auto recover off' => [false, 0])
  def test_recover_proc(data)
    auto_recover, messages = data
    save_routing([ap, OTHER_NODE_ID])
    call(:initialize_rttable)
    Roma::AsyncProcess.queue.clear
    @server.routing_table.auto_recover = auto_recover
    @server.routing_table.instance_variable_get(:@recover_proc).call('start_auto_recover_process')
    assert_equal messages, Roma::AsyncProcess.queue.size
  end

  def test_initialize_storages
    save_routing([ap, OTHER_NODE_ID])
    call(:initialize_rttable)
    path = "#{Roma.config.storage.path}/#{ap}"
    @files << path
    call(:initialize_storages)
    assert_equal ['roma'], @server.storages.keys
    assert_equal "#{path}/roma", @server.storages['roma'].instance_variable_get(:@storage_path)

    # A storage for each directory.
    FileUtils.mkdir_p(["#{path}/hash1", "#{path}/hash2"])
    call(:initialize_storages)
    assert_equal %w(hash1 hash2), @server.storages.keys.sort
  end

  # The bundled plugins and the ones in the plugin directory become commands.
  def test_initialize_plugin
    dir = File.join(@dir, 'command_plugins')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'server_test.rb'), <<~RUBY)
      module Roma::CommandPlugin::ServerTest
        include Roma::CommandPlugin
      end
    RUBY
    Roma.configure { |config| config.command_plugin_path = dir }
    call(:initialize_plugin)
    assert_include Roma::Command::Receiver.ancestors, Roma::CommandPlugin::Map
    assert_include Roma::Command::Receiver.ancestors, Roma::CommandPlugin::ServerTest
  ensure
    Roma.reset_config
  end

  def test_initialize_wb_writer
    call(:initialize_wb_writer)
    assert_kind_of Roma::WriteBehind::FileWriter, @server.wb_writer
    assert_kind_of Roma::WriteBehind::StreamWriter, @server.cluster_replication_writer
  end

  # Joining an existing cluster gets the routing table from a node of it.
  def test_initialize_rttable_join
    node = fake_node
    routing_data = Roma::Routing::RoutingData.create(32, 3, 2, [node.node_id])
    node.replies['routingdump'] = "#{routing_data.dump_binary.bytesize}\r\n#{routing_data.dump_binary}\r\nEND\r\n"
    node.replies['join'] = "ADDED\r\n"
    @server.stats.join_node_id = node.node_id
    fname = routing_file
    call(:initialize_rttable)
    assert_equal [node.node_id, ap].sort, @server.routing_table.nodes.sort
    assert_include node.commands, "join #{ap}"
    # The routing table is saved for the next start.
    assert_true File.exist?(fname)
  end

  def test_initialize_rttable_join_errors
    node = fake_node
    @server.stats.join_node_id = 'localhost_1'
    assert_raise_message(/No respons/) { call(:initialize_rttable_join) }

    @server.stats.join_node_id = node.node_id
    @server.stats.name = 'other'
    assert_raise_message(/diffarent name/) { call(:initialize_rttable_join) }

    @server.stats.name = 'ROMA'
    node.replies['routingdump'] = "0\r\n"
    assert_raise_message(/failed in getting the routing table/) { call(:initialize_rttable_join) }

    routing_file
    routing_data = Roma::Routing::RoutingData.create(32, 3, 2, [node.node_id, ap])
    node.replies['routingdump'] = "#{routing_data.dump_binary.bytesize}\r\n#{routing_data.dump_binary}\r\nEND\r\n"
    assert_raise_message(/already contained/) { call(:initialize_rttable_join) }

    routing_data = Roma::Routing::RoutingData.create(32, 3, 2, [node.node_id])
    node.replies['routingdump'] = "#{routing_data.dump_binary.bytesize}\r\n#{routing_data.dump_binary}\r\nEND\r\n"
    node.replies['join'] = "SERVER_ERROR busy\r\n"
    assert_raise_message(/Hotscale initialize failed/) { call(:initialize_rttable_join) }
  ensure
    @server.routing_table&.close_log
  end
end

class ServerTimerTest < Test::Unit::TestCase
  include ServerTestHelper

  def test_timer_event_10sec_at_startup
    # At startup, it first checks that the node accepts connections.
    node = fake_node
    server(nodes: [NODE_ID, node.node_id])
    stub_send_cmd('whoami' => 'ROMA')
    Roma::AsyncProcess.queue.push(Roma::AsyncMessage.new('start_get_routing_event'))
    call(:timer_event_10sec)
    # Once all the nodes answer, failover is enabled.
    assert_true @server.routing_table.enabled_failover
    assert_false @server.startup
    assert_true Roma::AsyncProcess.queue.empty?
  end

  def test_timer_event_10sec_waiting_for_nodes
    server
    call(:timer_event_10sec)
    # OTHER_NODE_ID isn't running.
    assert_false @server.routing_table.enabled_failover
    assert_true @server.startup
  end

  def test_timer_event_10sec_while_failover_is_disabled
    server
    set(startup: false, cluster_replication_writer: Struct.new(:run_replication).new(false))
    sent = stub_send_cmd({})
    call(:timer_event_10sec)
    assert_equal [], sent
  end

  def test_timer_event_10sec
    server
    cluster_replication_writer = Struct.new(:run_replication, :replica_nodelist, :updated) do
      def change_mklhash? = true
      def update_mklhash(node_id) = (self.updated = [node_id])
      def update_nodelist(node_id) = updated << node_id
      def update_rttable(node_id) = updated << node_id
    end.new(true, ['localhost_21211'])
    set(startup: false, cluster_replication_writer: cluster_replication_writer)
    @server.stats.last_clean_up = Time.at(0)
    @server.stats.run_sync_routing = true # Don't start syncing the routing table.
    @server.routing_table.enabled_failover = true
    # Counters are reset when they pass 32 bits.
    @server.stats.write_count = 0x100000000
    sent = stub_send_cmd('version' => 'VERSION ROMA-1.2.3')
    call(:timer_event_10sec)
    # Checks the versions of the nodes.
    assert_equal [[NODE_ID, "version\r\n"], [OTHER_NODE_ID, "version\r\n"]], sent
    assert_equal (1 << 16) + (2 << 8) + 3, @server.routing_table.min_version
    # Starts cleaning up the storages.
    assert_equal 'start_storage_clean_up_process', Roma::AsyncProcess.queue.pop.event
    # Updates the replica cluster's information.
    assert_equal ['localhost_21211'] * 3, cluster_replication_writer.updated
    assert_equal 0, @server.stats.write_count
  end

  def test_timer_event_1sec
    server
    @server.routing_table.enabled_failover = true
    sent = stub_send_cmd('whoami' => 'ROMA')
    set(startup: false)
    call(:timer_event_1sec)
    # Checks the other nodes.
    assert_equal [[OTHER_NODE_ID, "whoami\r\n"]], sent
  end

  def test_timer_event_1sec_stops_clean_up_while_joining
    server
    storage = Object.new
    def storage.stop_clean_up = (@stopped = true)
    def storage.stopped? = @stopped
    set(storages: { 'roma' => storage })
    @server.stats.run_join = true
    @server.stats.run_storage_clean_up = true
    Thread.new do
      Kernel.sleep 0.05
      @server.stats.run_storage_clean_up = false
    end
    call(:timer_event_1sec)
    assert_true storage.stopped?
  end

  def test_node_check
    server
    set(startup: false)
    stub_send_cmd('whoami' => 'ROMA')
    assert_true call(:node_check, OTHER_NODE_ID)
    stub_send_cmd('whoami' => 'OTHER')
    assert_false call(:node_check, OTHER_NODE_ID)
    stub_send_cmd('whoami' => nil)
    assert_false call(:node_check, OTHER_NODE_ID)
  end
end

class ServerRoutingSyncTest < Test::Unit::TestCase
  include ServerTestHelper

  def test_routing_hash_comparison_consistent
    server
    stub_send_cmd('mklhash' => ->(_nid, cmd) { @server.routing_table.merkle_tree.get(cmd.split(' ')[1].chomp) })
    assert_equal :consistent, call(:routing_hash_comparison, OTHER_NODE_ID)
  end

  # The other node has another route of one vnode, with a newer clock.
  def test_routing_hash_comparison_inconsistent
    server
    other = Roma::Routing::ChurnbasedRoutingTable.new(
      Marshal.load(Marshal.dump(@server.routing_table.instance_variable_get(:@routing_data))),
      File.join(@dir, 'other.route.yml')
    )
    vnode = other.routes.keys[3]
    other.set_route(vnode, 0, [OTHER_NODE_ID])
    sent = stub_send_cmd(
      'mklhash' => ->(_nid, cmd) { other.merkle_tree.get(cmd.split(' ')[1].chomp) },
      'getroute' => lambda { |_nid, _cmd|
        clock, node_ids = other.search_nodes_with_clk(vnode)
        "#{clock} #{node_ids.join(' ')}"
      }
    )
    assert_equal :inconsistent, call(:routing_hash_comparison, OTHER_NODE_ID)
    assert_equal [OTHER_NODE_ID], @server.routing_table.search_nodes(vnode)
    assert_include sent, [OTHER_NODE_ID, "getroute #{vnode}\r\n"]
  ensure
    other&.close_log
  end

  def test_sync_routing_with_an_older_route
    server
    vnode = @server.routing_table.routes.keys[0]
    @server.routing_table.set_route(vnode, 0, [NODE_ID])
    # The other node's route is older than ours (clock 1); send it ours, with
    # the clock to give setroute.
    sent = stub_send_cmd('getroute' => "0 #{OTHER_NODE_ID}", 'setroute' => 'STORED')
    # The id of a vnode's leaf in the Merkle tree: '0' and the vnode's bits.
    call(:sync_routing, OTHER_NODE_ID, "0#{(vnode >> 29).to_s(2).rjust(3, '0')}")
    assert_equal [NODE_ID], @server.routing_table.search_nodes(vnode)
    assert_equal [OTHER_NODE_ID, "setroute #{vnode} 0 #{NODE_ID}\r\n"], sent.last
  end

  def test_routing_hash_comparison_while_joining
    server
    @server.stats.run_join = true
    assert_equal :skip, call(:routing_hash_comparison, OTHER_NODE_ID)
  end

  def test_start_sync_routing_process
    server
    stub_send_cmd('mklhash' => ->(_nid, cmd) { @server.routing_table.merkle_tree.get(cmd.split(' ')[1].chomp) })
    call(:start_sync_routing_process)
    deadline = Time.now + 5
    Kernel.sleep 0.01 while @server.stats.run_sync_routing && Time.now < deadline
    assert_false @server.stats.run_sync_routing
  end

  def test_start_sync_routing_process_alone
    server(nodes: [NODE_ID])
    call(:start_sync_routing_process)
    assert_false @server.stats.run_sync_routing
  end
end

class ServerSendCmdTest < Test::Unit::TestCase
  include ServerTestHelper

  def setup
    super
    @node = fake_node
    server(nodes: [NODE_ID, @node.node_id])
  end

  def test_async_send_cmd
    assert_equal 'ROMA', call(:async_send_cmd, @node.node_id, "whoami\r\n")
    assert_equal 'ROMA', call(:async_send_cmd, @node.node_id, "whoami\r\n", 1)
    @node.replies['stat'] = "ERROR\r\n"
    assert_equal 'ERROR', call(:async_send_cmd, @node.node_id, "stat\r\n")
  end

  def test_async_send_cmd_to_a_node_that_is_down
    assert_nil call(:async_send_cmd, 'localhost_1', "whoami\r\n")
    assert_nil call(:async_send_cmd, 'localhost_1', "whoami\r\n", 1)
    assert_equal 2, @server.routing_table.failure_counts['localhost_1']
  end

  def test_async_send_cmd_without_a_reply
    @node.replies['quit'] = :close
    assert_nil call(:async_send_cmd, @node.node_id, "quit\r\n")
  end

  def test_async_broadcast_cmd
    # Not to this node.
    assert_equal({ @node.node_id => 'ROMA' }, call(:async_broadcast_cmd, "whoami\r\n"))
    assert_equal [NODE_ID], call(:async_broadcast_cmd, "whoami\r\n", [@node.node_id], 1).keys
  end

  def test_version_check
    @node.replies['version'] = "VERSION ROMA-1.2.3\r\n"
    call(:version_check)
    assert_equal({ @node.node_id => (1 << 16) + (2 << 8) + 3 }, @server.routing_table.version_of_nodes)
  end

  def test_receive_routing_dump
    routing_data = @server.routing_table.instance_variable_get(:@routing_data)
    @node.replies['routingdump'] = "#{routing_data.dump_binary.bytesize}\r\n#{routing_data.dump_binary}\r\nEND\r\n"
    got = call(:get_routedump, @node.node_id)
    assert_equal routing_data.routes, got.routes
  end

  def test_get_routedump_falls_back_to_marshal
    routing_data = @server.routing_table.instance_variable_get(:@routing_data)
    dump = Marshal.dump(routing_data)
    @node.replies['routingdump'] = lambda do |line|
      line.include?('bin') ? "0\r\n" : "#{dump.bytesize}\r\n#{dump}\r\nEND\r\n"
    end
    assert_equal routing_data.routes, call(:get_routedump, @node.node_id).routes
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
    @server.stats.run_storage_clean_up = false
    call(:stop_clean_up)
    assert_not_nil @server.stats.last_clean_up
  end

  def test_daemon
    @server.stats.daemon = true
    assert_true @server.daemon?
  end
end
