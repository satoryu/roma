require 'test_helper'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'stringio'
require 'fake_node'
require 'roma/routing/routing_data'
require 'roma/storage/ruby_hash_storage'
require 'roma/tools/mkroute'
require 'roma/tools/ssroute'
require 'roma/tools/log_merger'
require 'roma/config'
require 'roma/tools/mkconfig'
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

  def mkroute(nodes, **opts)
    out = StringIO.new
    Roma::Tools::Mkroute.new(out: out, dir: @dir).create(nodes, **opts)
    out.string
  end

  def load_route(nid)
    Roma::Routing::RoutingData.load_snapshot(File.join(@dir, "#{nid}.route"))
  end

  def test_create
    out = mkroute(%w(host1:11211 host2_11211), divide_bits: 3)
    assert_equal "nodes => [\"host1_11211\", \"host2_11211\"]\nRouting table has created.\n", out
    %w(host1_11211 host2_11211).each do |nid|
      rd = load_route(nid)
      assert_equal %w(host1_11211 host2_11211), rd.nodes
      assert_equal [32, 3, 2], [rd.dgst_bits, rd.div_bits, rd.rn]
      assert_equal 8, rd.v_idx.size
    end
  end

  def test_options
    mkroute(%w(host1_1 host2_1 host3_1), hash_bits: 16, divide_bits: 4, redundancy: 3)
    rd = load_route('host1_1')
    assert_equal [16, 4, 3], [rd.dgst_bits, rd.div_bits, rd.rn]
  end

  def test_replication_in_host
    mkroute(%w(host1_1 host1_2), divide_bits: 3, replication_in_host: true)
    load_route('host1_1').v_idx.each_value { |nids| assert_equal 2, nids.size }
  end

  # Without replication_in_host, a host doesn't hold the same data twice.
  def test_without_replication_in_host
    mkroute(%w(host1_1 host1_2 host2_1), divide_bits: 3)
    load_route('host1_1').v_idx.each_value do |nids|
      assert_equal nids.size, nids.map { |nid| nid.split('_').first }.uniq.size
    end
  end

  data('hash bits less than divide bits' => [{ hash_bits: 8, divide_bits: 9 }, 'The hash bits should be divide bits or more.'],
       'divide bits over 32' => [{ hash_bits: 40, divide_bits: 33 }, 'The upper bound of divide bits is 32.'],
       'fewer nodes than redundancy' => [{ redundancy: 3 }, 'The node-id number should be redundant number or more.'])
  def test_invalid_arguments(data)
    opts, message = data
    error = assert_raise(Roma::Tools::Error) { mkroute(%w(host1_1 host2_1), **opts) }
    assert_equal message, error.message
    assert_equal [], Dir.children(@dir)
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

  def merged(**opts)
    out = StringIO.new
    Roma::Tools::LogMerger.new(out: out).merge(%w(a.log b.log).map { |f| File.join(@dir, f) }, **opts)
    out.string.lines.map { |l| l[/\A(\w)\.log,.*: (\w+)$/] ? "#{$1}:#{$2}" : l.chomp }
  end

  # Each line is prefixed with its file. A line without a date belongs to
  # the line before.
  def test_merge_in_time_order
    assert_equal ['a:a1', 'b:b1', 'a:a2', 'continued line of a2', 'b:b2', 'a:a3'], merged
  end

  def test_whole_line
    out = StringIO.new
    Roma::Tools::LogMerger.new(out: out).merge([File.join(@dir, 'b.log')])
    assert_equal "b.log,W, [2026-01-01T00:00:02.000001 #2]  WARN -- : b1\nb.log,I, [2026-01-01T00:00:04.000001 #2]  INFO -- : b2\n",
                 out.string
  end

  data('TRACE' => ['TRACE', ['a:a1', 'b:b1', 'a:a2', 'continued line of a2', 'b:b2', 'a:a3']],
       'INFO' => ['INFO', ['a:a1', 'b:b1', 'b:b2', 'a:a3']],
       'WARN' => ['WARN', ['b:b1', 'a:a3']],
       'ERROR' => ['ERROR', ['a:a3']],
       'FATAL' => ['FATAL', []])
  def test_level(data)
    level, expected = data
    assert_equal expected, merged(level: level)
  end

  def test_period
    assert_equal ['b:b1', 'a:a2', 'continued line of a2', 'b:b2'],
                 merged(start_date: '20260101000002', end_date: '20260101000004')
  end

  # A date is filled up to the start or the end of the period it names.
  def test_period_by_a_prefix
    assert_equal ['a:a1', 'b:b1', 'a:a2', 'continued line of a2', 'b:b2', 'a:a3'],
                 merged(start_date: '2026', end_date: '20260101')
    assert_equal [], merged(start_date: '20260102')
    assert_equal [], merged(end_date: '2025')
  end
end

class SsrouteTest < Test::Unit::TestCase
  include ToolTestHelper

  def setup
    super
    @fname = File.join(@dir, 'host1_1.route')
    Roma::Routing::RoutingData.create(32, 3, 1, ['host1_1']).save(@fname)
  end

  def write_log(n, line)
    File.write("#{@fname}.#{n}", "2026-01-01T00:00:00.1 #{line}\n")
  end

  def snapshot(node_id)
    out = StringIO.new
    Roma::Tools::Ssroute.new(out: out, dir: @dir).snapshot(node_id)
    out.string
  end

  def test_snapshot
    write_log(1, 'join host2_1')
    write_log(2, 'join host3_1')
    assert_equal "succeed\n", snapshot('host1:1')
    assert_equal %w(host1_1 host2_1), Roma::Routing::RoutingData.load_snapshot(@fname).nodes
    assert_equal %w(host1_1.route host1_1.route.1~ host1_1.route.2 host1_1.route~), Dir.children(@dir).sort
  end

  # The last log is still being written.
  def test_without_enough_logs
    write_log(1, 'join host2_1')
    error = assert_raise(Roma::Tools::Error) { snapshot('host1_1') }
    assert_equal 'Routing-log file does not found.', error.message
  end

  data('missing route' => ['host2_1', /\Aerror:No such file or directory/],
       'broken log' => ['host1_1', /\Aerror:.*parse error/])
  def test_error(data)
    node_id, message = data
    write_log(1, 'unknown host2_1')
    write_log(2, 'join host3_1')
    assert_raise_message(message) { snapshot(node_id) }
  end
end

class MkconfigTest < Test::Unit::TestCase
  include ToolTestHelper

  # Gives the lines, then the end of the input.
  class Input
    def initialize(lines)
      @lines = lines
    end

    def get_line
      @lines.shift
    end
  end

  def setup
    super
    @path = File.join(@dir, 'config.rb')
  end

  def mkconfig(*lines, mode: :no_menu)
    out = StringIO.new
    Roma::Tools::Mkconfig.new(input: Input.new(lines), out: out, path: @path).run(mode)
    out.string
  end

  def config
    File.read(@path)
  end

  def template
    File.read(Roma::Tools::Mkconfig::CONFIG_TEMPLATE_PATH)
  end

  # Ruby Hash, a wrong answer, the plugins by default, a Ruby client, and
  # the defaults for the machines.
  def test_ruby_hash
    out = mkconfig('1', '', '0', '2', '1', '', '')
    assert_match(/Please set FileDescriptor bigger than 10\./, out)
    assert_match(/After\r\n.*STORAGE_CLASS: Roma::Storage::RubyHashStorage/m, out)
    assert_match(/\Arequire "roma\/storage\/ruby_hash_storage"$/, config)
    assert_match(/^    STORAGE_CLASS = Roma::Storage::RubyHashStorage$/, config)
    assert_match(/^    STORAGE_OPTION = ""$/, config)
    assert_match(/^    PLUGIN_FILES = \["plugin_storage.rb"\]$/, config)
  end

  # The file can be loaded. In another process, not to change Roma::Config.
  def test_ruby_hash_config_loads
    mkconfig('1', '', '2', '1', '', '')
    out, err, status = Open3.capture3(RbConfig.ruby, '-I', File.expand_path('../lib', __dir__),
                                      '-e', 'load ARGV[0]; print Roma::Config::STORAGE_CLASS', @path)
    assert_true status.success?, err
    assert_equal 'Roma::Storage::RubyHashStorage', out
  end

  # Groonga asks the memory, the processes, the servers and the data, and
  # the options are calculated from them.
  def test_groonga
    out = mkconfig('2', '1.5', '2', '1', '100000000', '', '2', '2', '3')
    # 100000000 * 2 * 2 / 1 / 10, and (1.5GB - 1GB) / 2 / 10
    option = 'bnum=40000000#xmsiz=26843545#opts=d#dfunit=10'
    assert_match(/^    STORAGE_CLASS = Roma::Storage::GroongaStorage$/, config)
    assert_match(%r{\Arequire "roma/storage/groonga_storage"$}, config)
    assert_match(/^    STORAGE_OPTION = #{Regexp.escape(option.inspect)}$/, config)
    assert_match(/After\r\n.*STORAGE_OPTION: #{option}/m, out)
    assert_match(/After\r\n.*STORAGE_CLASS: Roma::Storage::GroongaStorage/m, out)
    # The servers asked for the storage: 1 * 30 + (3 - 1) * 12 * 2
    assert_match(/bigger than 78\./, out)
  end

  # The bnum is at least 5000000, and the xmsiz is half of the memory if it
  # is less than what the OS takes.
  def test_groonga_minimum
    mkconfig('2', '', '', '', '', '', '2', '3', '')
    assert_match(/^    STORAGE_OPTION = "bnum=5000000#xmsiz=16106127#/, config)
  end

  def test_plugins
    plugins = Roma::Tools::Mkconfig::Base.new['plugin']['choice']
    alist = plugins.index('plugin_alist.rb') + 1
    out = mkconfig('1', '1', '1', alist.to_s, '2', '1', '', '')
    assert_match(/After\r\n.*PLUGIN_FILES: \["plugin_storage.rb", "plugin_alist.rb"\]/m, out)
    assert_match(/^    PLUGIN_FILES = \["plugin_storage.rb", "plugin_alist.rb"\]$/, config)
  end

  # Without plugin_storage.rb, it asks to add it.
  def test_plugin_storage_added
    plugins = Roma::Tools::Mkconfig::Base.new['plugin']['choice']
    alist = plugins.index('plugin_alist.rb') + 1
    mkconfig('1', alist.to_s, '2', '1', '1', '', '')
    assert_match(/^    PLUGIN_FILES = \["plugin_storage.rb", "plugin_alist.rb"\]$/, config)
  end

  def test_all_plugins
    plugins = Roma::Tools::Mkconfig::Base.new['plugin']['choice']
    mkconfig('1', plugins.size.to_s, '1', '', '')
    assert_match(/^    PLUGIN_FILES = #{Regexp.escape(plugins[0..-2].to_s)}$/, config)
  end

  # Only what is chosen from the menu is set.
  def test_with_menu
    plugins = Roma::Tools::Mkconfig::Base.new['plugin']['choice']
    out = mkconfig('2', plugins.size.to_s, '4', mode: :with_menu)
    assert_match(/Please select by number\./, out)
    assert_equal template.sub(/PLUGIN_FILES = .*/, "PLUGIN_FILES = #{plugins[0..-2]}"), config
  end

  data('exit' => 'exit', 'quit' => 'quit', 'balse' => 'balse', 'end of input' => nil)
  def test_quit(line)
    out = mkconfig(*['1', line].compact)
    assert_match(/config.rb  were not created!/, out)
    assert_false File.exist?(@path)
  end

  def test_overwrite
    File.write(@path, 'old')
    assert_match(/were not created!/, mkconfig('n', '1', '', '2', '1', '', ''))
    assert_equal 'old', config
    mkconfig('y', '1', '', '2', '1', '', '')
    assert_match(/ruby_hash_storage/, config)
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
