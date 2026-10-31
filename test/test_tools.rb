require 'test_helper'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'stringio'
require 'fake_node'
require 'roma/routing/routing_data'
require 'roma/storage/ruby_hash_storage'
require 'roma/tools/mkroute'
require 'roma/tools/recoverlost_lib'
require 'roma/tools/multi_commander'
require 'roma/tools/roma-adm'

module ToolTestHelper
  BIN_DIR = File.expand_path('../bin', __dir__)

  def setup
    @dir = Dir.mktmpdir('roma_tools')
    @nodes = []
  end

  def teardown
    @nodes.each(&:close)
    Roma::Messaging::ConPool.instance.close_all
    Roma::Client::ConPool.instance.close_all if defined?(Roma::Client::ConPool)
    FileUtils.rm_rf(@dir)
  end

  def fake_node
    FakeNode.new.tap { |node| @nodes << node }
  end

  # Runs a command in bin/ in another process, since the tools run when they
  # are loaded and some exit. With COVERAGE, it is measured too.
  def run_tool(name, *args, stdin: '')
    cmd = [RbConfig.ruby]
    cmd.push('-r', File.expand_path('start_coverage', __dir__)) if ENV['COVERAGE']
    cmd.push(File.join(BIN_DIR, name), *args)
    Open3.capture3(*cmd, stdin_data: stdin, chdir: @dir)
  end

  # Makes +node+ answer routingdump with +rd+.
  def serve_routing(node, rd)
    dump = Marshal.dump(rd)
    node.replies['routingdump'] = "#{dump.bytesize}\r\n#{dump}\r\nEND\r\n"
  end

  def capture_stdout
    saved = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = saved
  end
end

class MkrouteTest < Test::Unit::TestCase
  include ToolTestHelper

  def mkroute(*args)
    out = StringIO.new
    err = StringIO.new
    status = Roma::Tools::Mkroute.new(out: out, err: err, dir: @dir).run(args)
    [out.string, err.string, status]
  end

  def load_route(nid)
    Roma::Routing::RoutingData.load_snapshot(File.join(@dir, "#{nid}.route"))
  end

  def test_mkroute
    out, _err, status = mkroute('-d', '3', 'host1:11211', 'host2_11211')
    assert_equal 0, status
    assert_match(/Routing table has created/, out)
    %w(host1_11211 host2_11211).each do |nid|
      rd = load_route(nid)
      assert_equal %w(host1_11211 host2_11211), rd.nodes
      assert_equal 8, rd.v_idx.size
      assert_equal 2, rd.rn
      assert_equal 32, rd.dgst_bits
    end
  end

  def test_options
    _out, _err, status = mkroute('-h', '16', '-d', '4', '-r', '3', 'host1_1', 'host2_1', 'host3_1')
    assert_equal 0, status
    rd = load_route('host1_1')
    assert_equal [16, 4, 3], [rd.dgst_bits, rd.div_bits, rd.rn]
  end

  data('replication_in_host' => [%w(--replication_in_host), ''],
       'enabled_repeathost' => [%w(--enabled_repeathost), 'Warning: "--enabled_repeathost" is deprecated.'])
  def test_replication_in_host(data)
    option, warning = data
    out, _err, status = mkroute('-d', '3', '-r', '2', *option, 'host1_1', 'host1_2')
    assert_equal 0, status
    assert_true out.start_with?(warning), out
    load_route('host1_1').v_idx.each_value { |nids| assert_equal 2, nids.size }
  end

  # Without the option, a host doesn't hold the same data twice.
  def test_without_replication_in_host
    mkroute('-d', '3', '-r', '2', 'host1_1', 'host1_2', 'host2_1')
    load_route('host1_1').v_idx.each_value do |nids|
      assert_equal nids.size, nids.map { |nid| nid.split('_').first }.uniq.size
    end
  end

  def test_help
    out, _err, status = mkroute('--help')
    assert_equal 0, status
    assert_match(/usage:.*--replication_in_host/m, out)
    assert_equal [], Dir.children(@dir)
  end

  data('no nodes' => [[], /usage:/],
       'unknown option' => [%w(--unknown host1_1 host2_1), /invalid option: --unknown.*usage:/m],
       'hash bits less than divide bits' => [%w(-h 8 -d 9 host1_1 host2_1), /hash bits should be divide bits or more/],
       'divide bits over 32' => [%w(-h 40 -d 33 host1_1 host2_1), /upper bound of divide bits is 32/],
       'fewer nodes than redundancy' => [%w(-r 3 host1_1 host2_1), /node-id number should be redundant number or more/])
  def test_invalid_arguments(data)
    args, message = data
    out, err, status = mkroute(*args)
    assert_equal 1, status
    assert_equal '', out
    assert_match(message, err)
    assert_equal [], Dir.children(@dir)
  end

  # bin/mkroute runs the tool and exits with its status.
  def test_command
    out, _err, status = run_tool('mkroute', '-d', '3', 'host1_1', 'host2_1')
    assert_true status.success?
    assert_match(/Routing table has created/, out)
    assert_equal %w(host1_1.route host2_1.route), Dir.children(@dir).sort
    _out, err, status = run_tool('mkroute')
    assert_equal 1, status.exitstatus
    assert_match(/usage:/, err)
  end
end

class LogMergerTest < Test::Unit::TestCase
  include ToolTestHelper

  def setup
    super
    File.write(File.join(@dir, 'a.log'), <<~LOG)
      # Logfile created on 2026-01-01 00:00:00 by logger.rb
      I, [2026-01-01T00:00:01.000001 #1]  INFO -- : a1
      D, [2026-01-01T00:00:03.000001 #1] DEBUG -- : a2
      continued line of a2
      E, [2026-01-01T00:00:05.000001 #1] ERROR -- : a3
    LOG
    File.write(File.join(@dir, 'b.log'), <<~LOG)
      W, [2026-01-01T00:00:02.000001 #2]  WARN -- : b1
      I, [2026-01-01T00:00:04.000001 #2]  INFO -- : b2
    LOG
  end

  def merged(*args)
    out, err, status = run_tool('log_merger', 'a.log', 'b.log', *args)
    assert_true status.success?, err
    out.lines.map { |l| l[/\A(\w)\.log,.*: (\w+)$/] ? "#{$1}:#{$2}" : l.chomp }
  end

  # Each line is prefixed with its file. A line without a date belongs to
  # the line before.
  def test_merge_in_time_order
    assert_equal ['a:a1', 'b:b1', 'a:a2', 'continued line of a2', 'b:b2', 'a:a3'], merged
  end

  def test_log_level
    assert_equal ['b:b1', 'a:a3'], merged('-l', 'WARN')
  end

  def test_period
    assert_equal ['b:b1', 'a:a2', 'continued line of a2', 'b:b2'], merged('-s', '20260101000002', '-e', '20260101000004')
  end

  def test_output_file
    merged('-o', 'merged.log')
    assert_match(/a\.log,I, .* a1/, File.read(File.join(@dir, 'merged.log')))
  end

  def test_usage
    _out, err, _status = run_tool('log_merger')
    assert_match(/Usage/, err)
  end
end

class ChgRedundancyTest < Test::Unit::TestCase
  include ToolTestHelper

  def test_chg_redundancy
    node = fake_node
    rd = Roma::Routing::RoutingData.create(32, 3, 2, [node.nid, 'localhost_1'])
    rd.v_clk.each_key { |vn| rd.v_clk[vn] = 5 }
    serve_routing(node, rd)
    host, port = node.nid.split('_')
    out, err, status = run_tool('chg_redundancy', '1', host, port)
    assert_true status.success?, err
    changed = YAML.unsafe_load(out)
    assert_equal 1, changed.rn
    changed.v_idx.each_value { |nids| assert_equal 1, nids.size }
    # The clocks start over.
    assert_equal [0], changed.v_clk.values.uniq
  end

  data('wrong number of arguments' => [%w(1 localhost), /usage:/],
       'redundancy less than 1' => [%w(0 localhost 1), /must be n >= 1/],
       'no routing data' => [%w(1 localhost 1), /can not get the routing data/])
  def test_errors(data)
    args, message = data
    _out, err, _status = run_tool('chg_redundancy', *args)
    assert_match(message, err)
  end
end

class MultiCommanderTest < Test::Unit::TestCase
  include ToolTestHelper

  def test_send_cmd_all
    nodes = [fake_node, fake_node]
    rd = Roma::Routing::RoutingData.create(32, 3, 1, nodes.map(&:nid))
    serve_routing(nodes[0], rd)
    commander = Roma::MultiCommander.new(nodes[0].nid)
    assert_equal "ROMA\r\n", commander.send_cmd('whoami')
    expected = rd.nodes.map { |nid| "****** #{nid}\r\nROMA\r\n" }.join
    assert_equal expected, commander.send_cmd_all('whoami')
  end
end

class RomaAdmTest < Test::Unit::TestCase
  include ToolTestHelper

  def test_send_command
    node = fake_node
    adm = Roma::Adm.new('whoami', node.nid.split('_')[1])
    assert_equal ['ROMA'], adm.send_command
  end

  # Commands that store a value ask for it.
  def test_command_with_a_value
    node = fake_node
    adm = Roma::Adm.new('set key1 0 0 5', node.nid.split('_')[1])
    with_stdin("value\n") { capture_stdout { adm.check_type } }
    adm.send_command
    assert_equal ['set key1 0 0 5', 'value'], node.commands
  end

  def test_halt_command_rejected
    adm = Roma::Adm.new('balse', '1')
    out = capture_stdout do
      assert_raise_message('confirmation was rejected') { with_stdin("no\n") { adm.check_type } }
    end
    assert_match(/Are you sure/, out)
  end

  def with_stdin(input)
    io = StringIO.new(input)
    STDIN.define_singleton_method(:gets) { |*args| io.gets(*args) }
    yield
  ensure
    STDIN.singleton_class.send(:remove_method, :gets)
  end
end

class RecoverLostTest < Test::Unit::TestCase
  include ToolTestHelper

  def setup
    super
    @node = fake_node
    @node.replies['setroute'] = "STORED\r\n"
    @host, @port = @node.nid.split('_')
    @rd = Roma::Routing::RoutingData.create(32, 3, 1, [@node.nid])
    serve_routing(@node, @rd)
    @storage = Roma::Storage::RubyHashStorage.new
    @storage.vn_list = @rd.v_idx.keys
    @storage.each_vn_dump_sleep = 0
    @storage.opendb
    # A hash directory, as recoverlost finds in the storage path.
    FileUtils.mkdir_p(File.join(@dir, 'roma'))
  end

  def recover_lost(args = [@host, @port, @dir, '20260101000000'], alldata: false)
    r = Roma::RecoverLost.new('recoverlost', 'spushv', args, alldata)
    storage = @storage
    # The real one opens a file storage (tc, dbm or sqlite3).
    r.define_singleton_method(:open_storage) { |_path, _vn_list| storage }
    def storage.closedb; end
    r
  end

  def store(key, value)
    d = Digest::SHA1.hexdigest(key).hex % (2**32)
    vn = d & @rd.search_mask
    @storage.set(vn, key, d, 0x7fffffff, value)
    vn
  end

  def test_recover_lost_vnodes
    vn = store('key1', 'value1')
    @rd.v_idx[vn] = []
    serve_routing(@node, @rd)
    @node.replies['history_of_lost'] = "END\r\n"
    out = capture_stdout { recover_lost.suite }
    assert_match(/1 vnodes where data was lost/, out)
    # The vnode is pushed to a node, and it is told to own the vnode.
    assert_equal ['key1'], @node.dat[vn].keys
    # The clock of the data is reset.
    assert_equal 0, @node.dat[vn]['key1'].unpack('NNNN')[2]
    # Only one node, so the broadcast to the others sends nothing.
    assert_equal ["setroute #{vn} 0 #{@node.nid}"], @node.commands.grep(/\Asetroute/)
  end

  # The other nodes are told that the node now owns the vnode.
  def test_recover_lost_vnodes_tells_the_other_nodes
    other = fake_node
    vn = store('key1', 'value1')
    @rd.nodes << other.nid
    @rd.v_idx[vn] = []
    serve_routing(@node, @rd)
    @node.replies['history_of_lost'] = "END\r\n"
    r = recover_lost
    # Assign the vnode to the first node.
    r.define_singleton_method(:rand) { |_n| 0 }
    broadcasts = []
    real = r.method(:broadcast_cmd)
    r.define_singleton_method(:broadcast_cmd) { |cmd, without| broadcasts << without; real.call(cmd, without) }
    capture_stdout { r.suite }
    assert_include other.commands, "setroute #{vn} 0 #{@node.nid}"
    assert_equal [[@node.nid]], broadcasts
  end

  def test_history_of_lost
    vn = store('key1', 'value1')
    @node.replies['history_of_lost'] = "#{vn}\r\nEND\r\n"
    capture_stdout { recover_lost.suite }
    assert_include @node.commands, 'history_of_lost 20260101000000'
    # The vnode has a node now; the data is pushed there.
    assert_equal ['key1'], @node.dat[vn].keys
  end

  def test_nothing_lost
    @node.replies['history_of_lost'] = "END\r\n"
    out = capture_stdout { assert_raise(SystemExit) { recover_lost.suite } }
    assert_match(/0 vnodes/, out)
  end

  def test_all_data
    vn = store('key1', 'value1')
    capture_stdout { recover_lost([@host, @port, @dir], alldata: true).suite }
    assert_equal ['key1'], @node.dat[vn].keys
    assert_equal @rd.v_idx.keys.sort, @node.dat.keys.sort
  end

  def test_push_failed
    @node.replies['spushv'] = "SERVER_ERROR busy\r\n"
    out = capture_stdout { assert_raise(SystemExit) { recover_lost([@host, @port, @dir], alldata: true).suite } }
    assert_match(/roma/, out)
  end

  def test_suite_with_keys
    vn = store('key1', 'value1')
    out = capture_stdout { recover_lost([@host, @port, @dir], alldata: true).suite_with_keys(%w(key1 key2)) }
    assert_match(/hit => key1/, out)
    assert_not_match(/key2/, out)
    assert_equal ['key1'], @node.dat[vn].keys
  end

  def test_recover_with_keys_by_node
    vn = store('key1', 'value1')
    r = recover_lost([@host, @port, @dir], alldata: true)
    r.instance_variable_set(:@rd, @rd)
    r.instance_variable_set(:@storage, @storage)
    capture_stdout { r.start_recover_width_keys2('roma', %w(key1 key2)) }
    # Every key is sent in one stream, with its own vnode.
    assert_equal ['key1'], @node.dat[0].keys
    assert_equal vn, @node.dat[0]['key1'].unpack('N')[0]
  end

  def test_upload_refused
    @node.replies['spushv'] = "SERVER_ERROR busy\r\n"
    r = recover_lost([@host, @port, @dir], alldata: true)
    assert_equal 'SERVER_ERROR busy', r.upload_data('roma', 0, @node.nid, 'key1', [0, 0, 0, 0, 'v'])
    r.instance_variable_set(:@rd, @rd)
    assert_equal 'SERVER_ERROR busy', r.upload_data2('roma', @node.nid, ['key1'])
  end

  def test_send_cmd_to_a_node_that_is_down
    r = recover_lost([@host, @port, @dir], alldata: true)
    r.instance_variable_set(:@rd, @rd)
    assert_nil r.send_cmd('localhost_1', "whoami\r\n")
    assert_equal({ @node.nid => 'ROMA' }, r.broadcast_cmd("whoami\r\n"))
  end

  def test_clk_to_zero
    r = recover_lost([@host, @port, @dir], alldata: true)
    data = [1, 2, 3, 4, 2, 'k1', 1, 'v'].pack('NNNNNa2Na1')
    assert_equal [1, 2, 0, 4, 2, 'k1', 1, 'v'], r.clk_to_zero(data).unpack('NNNNNa2Na1')
    deleted = [1, 2, 3, 0, 2, 'k1', 0].pack('NNNNNa2N')
    assert_equal [1, 2, 0, 0, 2, 'k1', 0], r.clk_to_zero(deleted).unpack('NNNNNa2N')
  end

  data('too few arguments' => [%w(localhost 1), false],
       'all data with a time' => [%w(localhost 1 path 20260101000000), true])
  def test_usage(data)
    args, alldata = data
    out = capture_stdout do
      assert_raise(SystemExit) { Roma::RecoverLost.new('recoverlost', 'spushv', args, alldata) }
    end
    assert_match(/usage:recoverlost/, out)
  end

  # They are told on STDERR. (It exits with 0.)
  data('port not numeric' => [%w(localhost abc path 20260101000000), /port was not numeric/],
       'wrong time' => [%w(localhost 1 path 2026), /format mismatch/])
  def test_invalid_arguments(data)
    args, message = data
    _out, err, _status = run_tool('recoverlost', *args)
    assert_match(message, err)
  end
end
