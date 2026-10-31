require 'test_helper'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'stringio'
require 'fake_node'
require 'fake_kvs'
require 'roma/routing/routing_data'
require 'roma/storage/ruby_hash_storage'
require 'roma/tools/mkroute'
require 'roma/tools/ssroute'
require 'roma/tools/log_merger'
require 'roma/config'
require 'roma/tools/mkconfig'
require 'roma/tools/recoverlost'
require 'roma/tools/key_list'
require 'roma/tools/key_access'
require 'roma/tools/mkrecent'
require 'roma/tools/roma_watcher'
require 'roma/tools/tribunus'
require 'roma/tools/check_nodes'
require 'roma/tools/bench'
require 'roma/tools/consistency_test'
require 'roma/tools/safecopy_test'
require 'roma/tools/test_scenario'
require 'roma/tools/chg_redundancy'
require 'roma/tools/multi_commander'
require 'roma/tools/adm'

module ToolTestHelper
  BIN_DIR = File.expand_path('../bin', __dir__)

  def setup
    @dir = Dir.mktmpdir('roma_tools')
    @nodes = []
  end

  def teardown
    @nodes.each(&:close)
    Roma::Messaging::ConPool.instance.close_all
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

  # A node id that nothing listens on.
  def down_node
    server = TCPServer.new(0)
    "localhost_#{server.addr[1]}"
  ensure
    server.close
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

  # The file can be loaded, and its version lets romad boot. In another
  # process, not to change Roma::Config.
  def test_ruby_hash_config_loads
    mkconfig('1', '', '2', '1', '', '')
    script = 'require "roma/version"; load ARGV[0]; ' \
             'print Roma::Config::STORAGE_CLASS, " ", Roma::Config::VERSION == Roma::VERSION'
    out, err, status = Open3.capture3(RbConfig.ruby, '-I', File.expand_path('../lib', __dir__),
                                      '-e', script, @path)
    assert_true status.success?, err
    assert_equal 'Roma::Storage::RubyHashStorage true', out
  end

  # Groonga asks the memory, the processes, the servers and the data, and
  # the options are calculated from them.
  def test_groonga
    out = mkconfig('2', '1.5', '2', '1', '100000000', '', '2', '2', '3')
    # 100000000 * 2 * 2 / 1 / 10, and (1.5GB - 1GB) / 2 / 10
    option = 'bnum=40000000#xmsiz=26843545#opts=d#dfunit=10'
    assert_match(/^    STORAGE_CLASS = Roma::Storage::GroongaStorage$/, config)
    assert_match(%r{\Arequire "roma/storage/groonga"$}, config)
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

class AdminClientTest < Test::Unit::TestCase
  include ToolTestHelper

  def client
    Roma::Tools::AdminClient.new(timeout: 0.5)
  end

  def test_routing_data
    node = fake_node
    rd = Roma::Routing::RoutingData.create(32, 3, 1, [node.nid])
    serve_routing(node, rd)
    assert_equal rd.v_idx, client.routing_data(node.nid).v_idx
  end

  data('no routing data' => ["0\r\n", /has no routing data/],
       'closed' => [:close, /has no routing data/],
       'stops sending' => ["10\r\nabc", /execution expired/],
       'no reply' => [proc { '' }, /execution expired/])
  def test_routing_data_errors(data)
    reply, message = data
    node = fake_node
    node.replies['routingdump'] = reply
    assert_raise_message(message) { client.routing_data(node.nid) }
  end

  def test_routing_data_cut
    server = TCPServer.new(0)
    thread = Thread.new do
      s = server.accept
      s.gets
      s.write("10\r\nabc")
      s.close
    end
    nid = "localhost_#{server.addr[1]}"
    assert_raise_message("#{nid} closed the connection.") { client.routing_data(nid) }
  ensure
    thread.join
    server.close
  end

  # The reply ends when no line comes for a while.
  def test_command
    node = fake_node
    node.replies['stats'] = "a 1\r\nb 2\r\nEND\r\n"
    assert_equal ['a 1', 'b 2', 'END'], client.command(node.nid, 'stats')
    assert_equal ['stats'], node.commands
  end

  def test_command_without_reply
    node = fake_node
    node.replies['stats'] = proc { '' }
    assert_raise_message("#{node.nid} didn't reply to stats.") { client.command(node.nid, 'stats') }
  end

  def test_request
    node = fake_node
    node.replies['stats'] = "a 1\r\nb 2\r\nEND\r\n"
    assert_equal 'a 1', client.request(node.nid, 'stats')
  end

  data('closed' => [:close, /closed the connection/],
       'no reply' => [proc { '' }, /execution expired/])
  def test_request_errors(data)
    reply, message = data
    node = fake_node
    node.replies['stats'] = reply
    assert_raise_message(message) { client.request(node.nid, 'stats') }
  end

  def test_node_down
    nid = down_node
    error = assert_raise(Roma::Tools::Error) { client.command(nid, 'whoami') }
    assert_match(/\A#{nid}: .*refused/i, error.message)
  end
end

class ChgRedundancyTest < Test::Unit::TestCase
  include ToolTestHelper

  def change(node_id, redundancy)
    out = StringIO.new
    Roma::Tools::ChgRedundancy.new(out: out).change(node_id, redundancy)
    YAML.unsafe_load(out.string)
  end

  def serve(redundancy)
    node = fake_node
    rd = Roma::Routing::RoutingData.create(32, 3, redundancy, [node.nid, 'localhost_1', 'localhost_0'], true)
    rd.v_clk.each_key { |vn| rd.v_clk[vn] = 5 }
    serve_routing(node, rd)
    [node, rd]
  end

  def test_lower
    node, rd = serve(2)
    assert_equal [2], rd.v_idx.values.map(&:size).uniq
    changed = change(node.nid.sub('_', ':'), 1)
    assert_equal 1, changed.rn
    assert_equal rd.v_idx.transform_values { |nids| nids.first(1) }, changed.v_idx
    # The clocks start over.
    assert_equal [0], changed.v_clk.values.uniq
    assert_equal rd.nodes.sort, changed.nodes
  end

  # The nodes are added by romad later.
  def test_higher
    node, rd = serve(1)
    changed = change(node.nid, 3)
    assert_equal 3, changed.rn
    assert_equal rd.v_idx, changed.v_idx
  end

  data('zero' => 0, 'negative' => -1)
  def test_redundancy_less_than_one(redundancy)
    assert_raise_message('The redundancy should be 1 or more.') { change('localhost_1', redundancy) }
  end
end

class MultiCommanderTest < Test::Unit::TestCase
  include ToolTestHelper

  def test_send_cmd_all
    nodes = [fake_node, fake_node]
    rd = Roma::Routing::RoutingData.create(32, 3, 1, nodes.map(&:nid))
    serve_routing(nodes[0], rd)
    commander = Roma::Tools::MultiCommander.new(nodes[0].nid.sub('_', ':'))
    assert_equal "ROMA\r\n", commander.send_cmd('whoami')
    assert_equal "ROMA\r\n", commander.send_cmd('whoami', nodes[1].nid)
    expected = rd.nodes.map { |nid| "****** #{nid}\r\nROMA\r\n" }.join
    assert_equal expected, commander.send_cmd_all('whoami')
  end

  # The other nodes still get the command.
  def test_node_down
    node = fake_node
    nid = down_node
    rd = Roma::Routing::RoutingData.create(32, 3, 1, [nid, node.nid])
    serve_routing(node, rd)
    out = Roma::Tools::MultiCommander.new(node.nid).send_cmd_all('whoami')
    assert_match(/\A\*{6} #{nid}\r\nERROR: #{nid}: .*\r\n\*{6} #{node.nid}\r\nROMA\r\n\z/, out)
  end

  def test_no_routing_data
    nid = down_node
    assert_raise(Roma::Tools::Error) { Roma::Tools::MultiCommander.new(nid) }
  end
end

class AdmTest < Test::Unit::TestCase
  include ToolTestHelper

  def run_adm(cmd, input: '', **opts)
    @out = StringIO.new
    Roma::Tools::Adm.new(input: StringIO.new(input), out: @out).run(@node.nid, cmd, **opts)
  end

  def setup
    super
    @node = fake_node
  end

  def test_command
    assert_equal ['ROMA'], run_adm('whoami')
    assert_equal '', @out.string
  end

  # Commands that store a value ask for it.
  data('set' => 'set', 'alist_include?' => 'alist_include?')
  def test_value(name)
    # FakeNode answers the line of the value.
    @node.replies[name] = proc { '' }
    assert_equal ['STORED'], run_adm("#{name} key1 0 0 5", input: "value\n")
    assert_equal "Please input value.\n", @out.string
    assert_equal ["#{name} key1 0 0 5", 'value'], @node.commands
  end

  def test_value_given
    run_adm('set key1 0 0 5', value: 'value')
    assert_equal '', @out.string
    assert_equal ['set key1 0 0 5', 'value'], @node.commands
  end

  def test_no_value
    assert_raise_message('No value was given.') { run_adm('set key1 0 0 5') }
    assert_empty @node.commands
  end

  # Not a command that stores a value, though it begins with one.
  def test_value_command_prefix
    @node.replies['settings'] = "OK\r\n"
    assert_equal ['OK'], run_adm('settings')
  end

  data('balse' => 'balse', 'shutdown' => 'shutdown')
  def test_halt(name)
    @node.replies[name] = "BYE\r\n"
    assert_equal %w(BYE STORED STORED), run_adm(name, input: "yes\n")
    assert_equal "Are you sure?(yes/no)\n", @out.string
    assert_equal [name, 'yes', 'yes'], @node.commands
  end

  def test_halt_with_yes
    @node.replies['balse'] = "BYE\r\n"
    run_adm('balse', yes: true)
    assert_equal '', @out.string
    assert_equal %w(balse yes yes), @node.commands
  end

  data('no' => "no\n", 'end of input' => '')
  def test_halt_rejected(input)
    assert_raise_message('The confirmation was rejected.') { run_adm('balse', input: input) }
    assert_empty @node.commands
  end
end

class RecoverLostTest < Test::Unit::TestCase
  include ToolTestHelper

  # Chooses the first node.
  class FirstNode
    def self.rand(_max)
      0
    end
  end

  def setup
    super
    @node = fake_node
    @node.replies['setroute'] = "STORED\r\n"
    @rd = Roma::Routing::RoutingData.create(32, 3, 1, [@node.nid])
    serve_routing(@node, @rd)
    @storage = Roma::Storage::RubyHashStorage.new
    @storage.vn_list = @rd.v_idx.keys
    @storage.each_vn_dump_sleep = 0
    @storage.opendb
    # A directory of a hash, as recoverlost finds in the storage path.
    FileUtils.mkdir_p(File.join(@dir, 'roma'))
    @out = StringIO.new
  end

  # The real one opens the storage files (dbm, sqlite3 or groonga).
  def tool(alist: false)
    tool = Roma::Tools::RecoverLost.new(out: @out, alist: alist, push_wait: 0, random: FirstNode)
    storage = @storage
    opened = @opened = []
    closed = @closed = []
    tool.define_singleton_method(:open_storage) { |dir, _vnodes| storage.tap { opened << dir } }
    storage.define_singleton_method(:closedb) { closed << :closed }
    tool
  end

  # Set twice, so that the clock is not 0.
  def store(key, value)
    d = Digest::SHA1.hexdigest(key).hex % (2**32)
    vn = d & @rd.search_mask
    2.times { @storage.set(vn, key, d, 0x7fffffff, value) }
    assert_equal 1, @storage.get_raw(vn, key, d)[2]
    vn
  end

  def lose(vn)
    @rd.v_idx[vn] = []
    serve_routing(@node, @rd)
    vn
  end

  def test_recover_lost_vnodes
    vn = lose(store('key1', 'value1'))
    tool.recover(@node.nid, @dir)
    assert_match(/\A1 vnodes where data was lost\.\nroma #{@dir}\/roma\n0\/1 #{vn} assign to \["#{@node.nid}"\]\n\z/, @out.string)
    # The vnode is pushed to a node, and it is told to own the vnode.
    assert_equal ['key1'], @node.dat[vn].keys
    # The clock of the data is reset.
    assert_equal [vn, 0, 'value1'], @node.dat[vn]['key1'].unpack('NNNNa*').values_at(0, 2, 4)
    assert_equal ["setroute #{vn} 0 #{@node.nid}"], @node.commands.grep(/\Asetroute/)
    assert_equal [File.join(@dir, 'roma')], @opened
    assert_equal [:closed], @closed
  end

  # The other nodes are told that the node now owns the vnode, even if one
  # of them is down.
  def test_tell_the_other_nodes
    other = fake_node
    down = down_node
    @rd.nodes.push(other.nid, down)
    vn = lose(store('key1', 'value1'))
    tool.recover(@node.nid, @dir)
    assert_include other.commands, "setroute #{vn} 0 #{@node.nid}"
    assert_match(/^#{down}: .*refused/i, @out.string)
  end

  def test_setroute_refused
    @node.replies['setroute'] = "SERVER_ERROR busy\r\n"
    vn = lose(store('key1', 'value1'))
    assert_raise_message("#{@node.nid} replied to setroute #{vn} 0 #{@node.nid}: SERVER_ERROR busy") do
      tool.recover(@node.nid, @dir)
    end
  end

  # A vnode that has a node now, but lost data since the time.
  def test_since
    vn = store('key1', 'value1')
    @node.replies['history_of_lost'] = "#{vn}\r\nEND\r\n"
    tool.recover(@node.nid, @dir, since: '20260101000000')
    assert_include @node.commands, 'history_of_lost 20260101000000'
    assert_match(/^0\/1 #{vn} was auto assigned at \["#{@node.nid}"\]$/, @out.string)
    assert_equal ['key1'], @node.dat[vn].keys
    assert_empty @node.commands.grep(/\Asetroute/)
  end

  data('short' => '2026', 'not digits' => '2026010100000x')
  def test_since_format(since)
    assert_raise_message('The time should be YYYYMMDDHHMMSS.') { tool.recover(@node.nid, @dir, since: since) }
    assert_empty @node.commands
  end

  def test_history_of_lost_error
    @node.replies['history_of_lost'] = "CLIENT_ERROR\r\n"
    assert_raise_message("#{@node.nid} replied to history_of_lost: CLIENT_ERROR") do
      tool.recover(@node.nid, @dir, since: '20260101000000')
    end
  end

  def test_nothing_lost
    tool.recover(@node.nid, @dir)
    assert_equal "0 vnodes where data was lost.\n", @out.string
    assert_empty @opened
  end

  def test_all
    vn = store('key1', 'value1')
    tool.recover(@node.nid, @dir, all: true)
    assert_equal ['key1'], @node.dat[vn].keys
    assert_equal @rd.v_idx.keys.sort, @node.dat.keys.sort
    assert_not_match(/vnodes where data was lost/, @out.string)
  end

  # The storage is closed even then.
  def test_push_failed
    @node.replies['spushv'] = "SERVER_ERROR busy\r\n"
    assert_raise_message("Pushing vnode 0 to #{@node.nid} failed: SERVER_ERROR busy") do
      tool.recover(@node.nid, @dir, all: true)
    end
    assert_equal [:closed], @closed
  end

  def test_alist
    @node.replies['alist_spushv'] = "SERVER_ERROR busy\r\n"
    assert_raise(Roma::Tools::Error) { tool(alist: true).recover(@node.nid, @dir, all: true) }
    assert_equal ['alist_spushv roma 0'], @node.commands.grep(/spushv/)
  end

  def test_recover_keys
    vn = store('key1', 'value1')
    lost = lose(store('キー', 'value2'))
    tool.recover_keys(@node.nid, @dir, %w(key1 key2 キー))
    assert_equal "roma #{@dir}/roma\nhit => key1\n#{@node.nid}=>STORED\nhit => キー\n", @out.string
    assert_equal ['key1'], @node.dat[vn].keys
    # The data is pushed with the clock reset.
    assert_equal [vn, 0, 0x7fffffff, 'value1'], @node.dat[vn]['key1'].unpack('NNNNa*').values_at(0, 2, 3, 4)
    assert_nil @node.dat[lost]
  end

  # A multibyte key is packed by its bytes.
  def test_recover_multibyte_key
    vn = store('キー', '値')
    tool.recover_keys(@node.nid, @dir, ['キー'])
    assert_equal ['キー'.b], @node.dat[vn].keys
  end

  def test_recover_keys_refused
    store('key1', 'value1')
    @node.replies['spushv'] = "SERVER_ERROR busy\r\n"
    tool.recover_keys(@node.nid, @dir, ['key1'])
    assert_match(/^#{@node.nid}=>SERVER_ERROR busy$/, @out.string)
  end

  def test_no_directories
    FileUtils.rm_rf(File.join(@dir, 'roma'))
    assert_raise_message("#{@dir} has no directories of storage files.") { tool.recover(@node.nid, @dir, all: true) }
  end

  def test_node_down
    assert_raise_message(/\Alocalhost_1: /) { tool.recover('localhost_1', @dir) }
  end
end

class StorageFilesTest < Test::Unit::TestCase
  include ToolTestHelper

  def open_storage(*files, **opts)
    files.each { |f| File.write(File.join(@dir, f), '') }
    Roma::Tools::StorageFiles.open(@dir, [0], **opts)
  end

  def test_each_hash
    %w(roma2 roma1).each { |h| FileUtils.mkdir_p(File.join(@dir, h)) }
    File.write(File.join(@dir, 'file'), '')
    hashes = []
    Roma::Tools::StorageFiles.each_hash(@dir) { |hname, dir| hashes << [hname, dir] }
    assert_equal [['roma1', File.join(@dir, 'roma1')], ['roma2', File.join(@dir, 'roma2')]], hashes
  end

  def test_no_hashes
    assert_raise_message("#{@dir} has no directories of storage files.") do
      Roma::Tools::StorageFiles.each_hash(@dir) { flunk }
    end
  end

  def test_no_files
    assert_raise_message("#{@dir} has no storage files.") { open_storage }
  end

  def test_unknown_storage
    assert_raise_message("#{@dir} has files of an unknown storage: tc") { open_storage('0.tc', '1.tc') }
  end

  # The cache file is not the storage.
  def test_storage_gem_missing
    message = "The files in #{@dir} need roma-storage-dbm. Install it by gem install roma-storage-dbm."
    assert_raise_message(message) { open_storage('0.cache.dbm', '0.dbm') }
  end

  # With a storage of a test, which keeps the data on memory.
  def test_open
    storage = with_mem_storage { open_storage('0.mem', '1.mem', '0.cache.mem', '0.mem-journal') }
    assert_equal [Roma::Storage::RubyHashStorage, 2, @dir],
                 [storage.class, storage.divnum, storage.instance_variable_get(:@storage_path)]
    assert_equal({ 0 => 0 }, storage.hdiv)
  end

  def test_open_with_divnum
    storage = with_mem_storage { open_storage('0.mem', divnum: 3) }
    assert_equal 3, storage.divnum
  end

  # New files, of the storage given.
  def test_open_new
    storage = open_storage(divnum: 4, storage_class: Roma::Storage::RubyHashStorage)
    assert_equal [Roma::Storage::RubyHashStorage, 4], [storage.class, storage.divnum]
  end

  def with_mem_storage
    saved = Roma::Tools::StorageFiles::STORAGES
    Roma::Tools::StorageFiles.send(:remove_const, :STORAGES)
    Roma::Tools::StorageFiles.const_set(:STORAGES,
                                        saved.merge('mem' => ['roma/storage/ruby_hash_storage', :RubyHashStorage, 'roma-storage']))
    yield
  ensure
    Roma::Tools::StorageFiles.send(:remove_const, :STORAGES)
    Roma::Tools::StorageFiles.const_set(:STORAGES, saved)
  end
end

# The storages are on memory, instead of the files.
module MemStorageHelper
  def setup
    super
    @storages = {}
    @closed = []
  end

  # A storage in +dir+, with +data+ as {key => [value, clock, expt]}.
  def mem_storage(dir, data = {}, divnum: 2, vnodes: [0, 1 << 31])
    FileUtils.mkdir_p(dir)
    storage = Roma::Storage::RubyHashStorage.new
    storage.divnum = divnum
    storage.vn_list = vnodes
    storage.each_vn_dump_sleep = 0
    storage.opendb
    data.each do |key, (value, clk, expt)|
      vn = vnodes[key.sum % vnodes.size]
      storage.set(vn, key, 0, expt || 0x7fffffff, value)
      storage.instance_variable_get(:@hdb)[storage.hdiv[vn]].tap do |hdb|
        vn_, last, _clk, ex, val = hdb[key].unpack('NNNNa*')
        hdb[key] = [vn_, last, clk || 0, ex, val].pack('NNNNa*')
      end
    end
    closed = @closed
    storage.define_singleton_method(:closedb) { closed << dir }
    @storages[dir] = storage
  end

  # Makes +tool+ open the storages of mem_storage.
  def use_mem_storages(tool)
    storages = @storages
    tool.define_singleton_method(:open_storage) { |dir, *| storages.fetch(dir) { raise Roma::Tools::Error, "#{dir} has no storage files." } }
    tool
  end
end

class KeyListTest < Test::Unit::TestCase
  include ToolTestHelper
  include MemStorageHelper

  def test_list
    mem_storage(File.join(@dir, 'roma'), { 'key1' => ['v1'], 'key2' => ['v2'], 'expired' => ['v3', 0, 1] })
    mem_storage(File.join(@dir, 'roma2'), { 'key3' => ['v4'] })
    out = StringIO.new
    err = StringIO.new
    use_mem_storages(Roma::Tools::KeyList.new(out: out, err: err, wait: 0)).list(@dir)
    assert_equal %w(key1 key2 key3), out.string.lines.map(&:chomp).sort
    assert_match(/\A### roma #{@dir}\/roma\n.*done\n### roma2 #{@dir}\/roma2\n.*done\n\z/m, err.string)
    assert_match(%r{1/3\r2/3\r}, err.string)
    assert_equal [File.join(@dir, 'roma'), File.join(@dir, 'roma2')], @closed
  end

  # The storage is closed even then.
  def test_error
    storage = mem_storage(File.join(@dir, 'roma'), { 'key1' => ['v1'] })
    def storage.true_length
      raise Roma::Tools::Error, 'broken'
    end
    tool = use_mem_storages(Roma::Tools::KeyList.new(out: StringIO.new, err: StringIO.new))
    assert_raise_message('broken') { tool.list(@dir) }
    assert_equal [File.join(@dir, 'roma')], @closed
  end
end

class KeyAccessTest < Test::Unit::TestCase
  include ToolTestHelper
  include MemStorageHelper

  def setup
    super
    mem_storage(File.join(@dir, 'roma'), { 'key1' => ['v1', 3], 'expired' => ['v2', 0, 1] })
    mem_storage(File.join(@dir, 'roma2'), { 'key2' => ['v3'] })
    @out = StringIO.new
  end

  def access(key, **opts)
    use_mem_storages(Roma::Tools::KeyAccess.new(out: @out)).access(@dir, key, **opts)
  end

  def test_exist
    assert_true access('key1')
    assert_equal "hash : roma\nexist\n", @out.string
    assert_equal [File.join(@dir, 'roma')], @closed
  end

  def test_in_another_hash
    assert_true access('key2')
    assert_equal "hash : roma\nhash : roma2\nexist\n", @out.string
  end

  def test_value
    access('key1', value: true)
    assert_match(/\Ahash : roma\nvnode: \d+\nlast : .+\nclock: 3\nexpt : .+\nvalue: v1\n\z/, @out.string)
  end

  data('missing' => 'key3', 'expired' => 'expired')
  def test_not_exist(key)
    assert_false access(key)
    assert_equal "hash : roma\nhash : roma2\nnot exist\n", @out.string
  end

  # A deleted key leaves a mark, whose expt is 0.
  def test_deleted
    storage = @storages[File.join(@dir, 'roma')]
    vn = [0, 1 << 31]['key1'.sum % 2]
    storage.delete(vn, 'key1', 0)
    assert_false access('key1')
  end
end

class MkRecentTest < Test::Unit::TestCase
  include ToolTestHelper
  include MemStorageHelper

  def setup
    super
    @vnodes = [0, 1 << 31]
    @recent = File.join(@dir, 'recent')
    @out = StringIO.new
  end

  def tool
    tool = use_mem_storages(Roma::Tools::MkRecent.new(out: @out))
    storages = @storages
    closed = @closed
    real = Roma::Tools::StorageFiles
    # The new files are on memory too.
    tool.define_singleton_method(:open_storage) do |dir, vnodes, divnum: nil, storage_class: nil|
      next storages.fetch(dir) { raise Roma::Tools::Error, "#{dir} has no storage files." } unless storage_class
      real.open(dir, vnodes, divnum: divnum, storage_class: storage_class).tap do |st|
        st.define_singleton_method(:closedb) { closed << dir }
        storages[dir] = st
      end
    end
    tool
  end

  def make(**opts)
    tool.make(File.join(@dir, 'a'), File.join(@dir, 'b'), @recent, hash_bits: 32, divide_bits: 1, **opts)
  end

  def get(storage, key)
    storage.get_raw2(key)&.values_at(2, 4)
  end

  # The newer data of a key, by its clock, is kept.
  def test_make
    mem_storage(File.join(@dir, 'a', 'roma'), { 'key1' => ['old', 1], 'key2' => ['a2', 5] })
    mem_storage(File.join(@dir, 'b', 'roma'), { 'key1' => ['new', 2], 'key3' => ['b3', 1] })
    make(divnum: 3)
    recent = @storages.fetch(File.join(@recent, 'roma'))
    assert_equal 3, recent.divnum
    assert_equal [[2, 'new'], [5, 'a2'], [1, 'b3']], %w(key1 key2 key3).map { |k| get(recent, k) }
    assert_equal [File.join(@dir, 'a', 'roma'), File.join(@dir, 'b', 'roma'), File.join(@recent, 'roma')].sort, @closed.sort
    assert_match(/\AOpen .*a\/roma\nOpen .*b\/roma\nOpen .*recent\/roma\nroma:0\/2\rroma:1\/2\r\n\z/, @out.string)
  end

  def test_recent_path_exists
    Dir.mkdir(@recent)
    assert_raise_message("#{@recent} exists.") { make }
  end

  def test_divide_bits_too_many
    assert_raise_message('The hash bits should be divide bits or more.') do
      tool.make('a', 'b', @recent, hash_bits: 8, divide_bits: 9)
    end
    assert_false File.exist?(@recent)
  end

  # Nothing is made then.
  def test_no_hashes
    assert_raise_message("#{File.join(@dir, 'a')} has no directories of storage files.") { make }
    assert_false File.exist?(@recent)
  end

  # The storages opened are closed.
  def test_missing_in_the_other
    mem_storage(File.join(@dir, 'a', 'roma'))
    assert_raise_message("#{File.join(@dir, 'b', 'roma')} has no storage files.") { make }
    assert_equal [File.join(@dir, 'a', 'roma')], @closed
  end

  def test_different_storages
    mem_storage(File.join(@dir, 'a', 'roma'))
    other = Class.new(Roma::Storage::RubyHashStorage)
    @storages[File.join(@dir, 'b', 'roma')] = other.new.tap do |st|
      st.divnum = 1
      st.vn_list = @vnodes
      st.opendb
      closed = @closed
      st.define_singleton_method(:closedb) { closed << :other }
    end
    assert_raise_message(/have different storages/) { make }
    assert_equal [File.join(@dir, 'a', 'roma'), :other], @closed
  end
end

class RomaWatcherTest < Test::Unit::TestCase
  include ToolTestHelper

  # Keeps the mails instead of sending them.
  class FakeMailer
    attr_reader :mails

    def initialize
      @mails = []
    end

    def send_mail(subject, body)
      @mails << [subject, body]
    end
  end

  def setup
    super
    @mailer = FakeMailer.new
    @log = StringIO.new
  end

  def config(nodes, count: 2)
    { 'roma' => nodes, 'timeout' => 0.5, 'retry' => { 'count' => count, 'period' => 0 },
      'mail' => { 'subject_prefix' => 'ROMA ' }, 'log' => {} }
  end

  def watch(nodes, **opts)
    Roma::Tools::RomaWatcher.new(config(nodes, **opts), logger: Logger.new(@log), mailer: @mailer).watch
  end

  def answering(nodelist)
    fake_node.tap { |node| node.replies['nodelist'] = "#{nodelist}\r\n" }
  end

  def addr(node)
    node.nid.sub('_', ':')
  end

  def test_all_right
    nodes = [answering('a b'), answering('a b')]
    assert_equal [], watch(nodes.map { |n| addr(n) })
    assert_empty @mailer.mails
    assert_equal ['nodelist'], nodes[0].commands
  end

  def test_split_brain
    nodes = [answering('a b'), answering('a b'), answering('c')]
    assert_equal ['ROMA Split brain'], watch(nodes.map { |n| addr(n) })
    assert_equal [['ROMA Split brain', "a,b\r\nc\r\n"]], @mailer.mails
  end

  # Tried as many times as the retry count.
  def test_node_down
    node = answering('a')
    down = down_node.sub('_', ':')
    assert_equal ['ROMA A node down'], watch([addr(node), down], count: 3)
    subject, body = @mailer.mails[0]
    assert_equal 'ROMA A node down', subject
    assert_match(/\ACatch an error when checking a node: #{down}: /, body)
    assert_equal 2, @log.string.scan(/retry: \d times/).size
  end

  # Not split, when the nodes that answer know the same nodes.
  def test_all_down
    assert_equal ['ROMA A node down'] * 2, watch([down_node, down_node], count: 1)
  end

  # Answers after it failed once.
  def test_retry
    node = fake_node
    tries = 0
    node.replies['nodelist'] = proc { (tries += 1) == 1 ? '' : "a\r\n" }
    assert_equal [], watch([addr(node)])
    assert_equal 2, tries
  end

  def test_mailer
    out = File.join(@dir, 'mail')
    sendmail = File.join(@dir, 'sendmail')
    File.write(sendmail, "#!/bin/sh\necho \"$@\" > #{out}.args\ncat > #{out}\n")
    File.chmod(0o755, sendmail)
    Roma::Tools::RomaWatcher::Mailer.new('from@example.com', 'to@example.com', sendmail).send_mail('subject', 'body')
    assert_equal "-f from@example.com -t\n", File.read("#{out}.args")
    assert_equal "From: from@example.com\nTo: to@example.com\nSubject: subject\nReply-To: from@example.com\n\nbody\n",
                 File.read(out)
  end

  def test_mailer_failed
    sendmail = File.join(@dir, 'sendmail')
    File.write(sendmail, "#!/bin/sh\ncat > /dev/null\nexit 1\n")
    File.chmod(0o755, sendmail)
    mailer = Roma::Tools::RomaWatcher::Mailer.new('from@example.com', 'to@example.com', sendmail)
    assert_raise_message(/\A#{sendmail} failed: .*exit 1/) { mailer.send_mail('subject', 'body') }
  end
end

class TribunusTest < Test::Unit::TestCase
  include ToolTestHelper

  def setup
    super
    @sent = []
    @spawned = []
  end

  # Records the messages and the processes instead of sending and spawning.
  def tribunus(ports = [11211, 11212], status: true)
    tribunus = Roma::Tools::Tribunus.new('host1', ports, romad_work_dir: @dir, ruby: 'ruby')
    sent = @sent
    spawned = @spawned
    tribunus.define_singleton_method(:unicast) { |ipaddr, msg| sent << [ipaddr, msg] }
    tribunus.define_singleton_method(:spawn) { |*cmd| spawned << cmd; 100 + spawned.size }
    tribunus.define_singleton_method(:wait) { |_pid| Struct.new(:success?).new(status) }
    tribunus.define_singleton_method(:prepare_to_start) {}
    tribunus.define_singleton_method(:sleep) { |_sec| }
    tribunus
  end

  def bin(name)
    File.join(Roma::Tools::Tribunus::BIN_DIR, name)
  end

  data('two' => ['11211-11212', [11211, 11212]],
       'hundred' => ['1-100', (1..100).to_a])
  def test_parse_ports(data)
    range, ports = data
    assert_equal ports, Roma::Tools::Tribunus.parse_ports(range)
  end

  data('one port' => ['11211-11211', /2 ports or more/],
       'too many' => ['1-101', /100 ports or less/],
       'not a range' => ['11211', /should be like 11211-11213/],
       'not numbers' => ['a-b', /should be like 11211-11213/])
  def test_parse_ports_error(data)
    range, message = data
    assert_raise_message(message) { Roma::Tools::Tribunus.parse_ports(range) }
  end

  def test_start_new_ring
    t = tribunus
    t.start_new_ring
    assert_equal [['ruby', bin('roma'), 'mkroute', 'host1_11211', 'host1_11212', '--replication_in_host'],
                  ['ruby', bin('romad'), '--replication_in_host', '-p', '11211', 'host1'],
                  ['ruby', bin('romad'), '--replication_in_host', '-p', '11212', 'host1']], @spawned
    assert_equal 'update:0: host1 11211 11212', t.update_message(0)
  end

  def test_mkroute_failed
    assert_raise_message('Failed to make the routing table.') { tribunus(status: false).start_new_ring }
    assert_equal 1, @spawned.size
  end

  def test_start_join
    tribunus.start_join('host2', 11211)
    assert_equal [['ruby', bin('romad'), '--replication_in_host', '-p', '11211', 'host1', '-j', 'host2_11211'],
                  ['ruby', bin('romad'), '--replication_in_host', '-p', '11212', 'host1', '-j', 'host2_11211']], @spawned
  end

  # A host that has romads answers the multicast.
  def test_start_discover
    t = tribunus
    t.define_singleton_method(:multicast) { |msg| t.run_command('10.0.0.2', 'update:0: host2 21211 21212') if msg == 'update:1: host1' }
    t.start_discover(wait: 0)
    assert_equal ['-j', 'host2_21211'], @spawned[0].last(2)
  end

  def test_start_discover_no_answer
    t = tribunus
    t.define_singleton_method(:multicast) { |_msg| }
    assert_raise_message('No server responded.') { t.start_discover(wait: 0) }
    assert_empty @spawned
  end

  # The receiver replies while the count is more than 0.
  def test_update
    t = tribunus
    t.run_command('10.0.0.2', 'update:1: host2 21211 21212')
    assert_equal ['host2', [21211, 21212]], t.remote_servers['10.0.0.2'].to_a[0, 2]
    assert_equal [['10.0.0.2', 'update:0: host1']], @sent
    t.run_command('10.0.0.3', 'update:0: host3')
    assert_equal [], t.remote_servers['10.0.0.3'].ports
    assert_equal 1, @sent.size
    # A host without romads is not chosen.
    assert_equal 'host2', t.choose_rhost.hostname
  end

  data('unknown command' => 'hello:1: host2 1', 'no hostname' => 'update:1: ', 'broken' => 'update')
  def test_ignored(msg)
    t = tribunus
    t.run_command('10.0.0.2', msg)
    assert_empty t.remote_servers
    assert_empty @sent
  end

  def test_heartbeat
    t = tribunus
    now = Time.now
    t.remote_servers.merge!(
      'old' => Roma::Tools::Tribunus::RomadHost.new('h1', [1], now - 601),
      'quiet' => Roma::Tools::Tribunus::RomadHost.new('h2', [1], now - 301),
      'no romads' => Roma::Tools::Tribunus::RomadHost.new('h3', [], now),
      'fresh' => Roma::Tools::Tribunus::RomadHost.new('h4', [1], now)
    )
    t.heartbeat(now)
    assert_equal %w(fresh no\ romads quiet), t.remote_servers.keys.sort
    assert_equal [['quiet', 'update:0: host1'], ['no romads', 'update:1: host1']], @sent
  end
end

class CheckNodesTest < Test::Unit::TestCase
  include ToolTestHelper

  def answering(nodelist)
    fake_node.tap { |node| node.replies['nodelist'] = "#{nodelist}\r\n" }
  end

  def check(*node_ids)
    @out = StringIO.new
    Roma::Tools::CheckNodes.new(out: @out, client: Roma::Tools::AdminClient.new(timeout: 0.5)).check(node_ids)
  end

  def test_same
    nodes = [answering('a b'), answering('a b')]
    assert_true check(*nodes.map(&:nid))
    assert_equal "#{nodes.map(&:nid).join(' ')} => a b (2 nodes)\n", @out.string
  end

  def test_split
    nodes = [answering('a b'), answering('c'), answering('a b')]
    assert_false check(*nodes.map(&:nid))
    assert_equal "#{nodes[0].nid} #{nodes[2].nid} => a b (2 nodes)\n#{nodes[1].nid} => c (1 nodes)\n", @out.string
  end

  def test_node_down
    node = answering('a')
    down = down_node
    assert_false check(node.nid, down)
    assert_match(/\Aerror: #{down}: .*\n#{node.nid} => a \(1 nodes\)\n\z/, @out.string)
  end
end

module FakeKVSHelper
  def fake_kvs
    FakeKVS.new.tap { |kvs| @nodes << kvs }
  end
end

class TextClientTest < Test::Unit::TestCase
  include ToolTestHelper
  include FakeKVSHelper

  def setup
    super
    @kvs = fake_kvs
    @client = Roma::Tools::TextClient.new([@kvs.nid], timeout: 0.5)
  end

  def teardown
    @client.close
    super
  end

  def test_set_get_delete
    assert_equal 'STORED', @client.set('key1', "va\r\nlue")
    assert_equal "va\r\nlue", @client.get('key1')
    assert_equal 'DELETED', @client.delete('key1')
    assert_nil @client.get('key1')
    assert_equal 'NOT_FOUND', @client.delete('key1')
    # One connection.
    assert_equal ['set key1 0 0 7', 'get key1', 'delete key1', 'get key1', 'delete key1'], @kvs.commands
  end

  def test_multibyte_value
    @client.set('key1', '値')
    assert_equal '値'.b, @client.get('key1')
  end

  def test_expt
    @client.set('key1', 'v', 100)
    assert_equal 'set key1 0 100 1', @kvs.commands[0]
  end

  def test_get_error
    @kvs.replies['get'] = "SERVER_ERROR busy\r\n"
    assert_raise_message('get key1: SERVER_ERROR busy') { @client.get('key1') }
  end

  def test_get_without_end
    @kvs.replies['get'] = "VALUE key1 0 1\r\nv\r\nVALUE\r\n"
    assert_raise_message('get key1: VALUE') { @client.get('key1') }
  end

  # The node may read the value as a command, so the connection is closed.
  data('set' => ['set', ->(c) { c.set('key1', 'v') }, 'set key1: ERROR'],
       'delete' => ['delete', ->(c) { c.delete('key1') }, 'delete key1: ERROR'])
  def test_unexpected_reply(data)
    name, call, message = data
    @kvs.replies[name] = "ERROR\r\n"
    assert_raise_message(message) { call.call(@client) }
    @kvs.replies.clear
    assert_equal 'STORED', @client.set('key2', 'v')
    assert_equal 2, @kvs.commands.size
  end

  def test_not_stored
    @kvs.replies['set'] = "NOT_STORED\r\n"
    assert_equal 'NOT_STORED', @client.set('key1', 'v')
  end

  def test_closed
    @kvs.replies['set'] = :close
    assert_raise_message('The connection was closed.') { @client.set('key1', 'v') }
  end

  def test_no_reply
    @kvs.replies['delete'] = ''
    assert_raise_message(/execution expired/) { @client.delete('key1') }
  end

  # The next node is used after an error.
  def test_next_node
    down = down_node
    client = Roma::Tools::TextClient.new([down, @kvs.nid], timeout: 0.5)
    assert_raise_message(/\A#{down}: /) { client.set('key1', 'v') }
    assert_equal 'STORED', client.set('key1', 'v')
  ensure
    client.close
  end

  def test_no_node
    assert_raise_message('No node is given.') { Roma::Tools::TextClient.new([]) }
  end
end

class BenchTest < Test::Unit::TestCase
  include ToolTestHelper
  include FakeKVSHelper

  def setup
    super
    @kvs = fake_kvs
    @out = StringIO.new
  end

  def bench(interval: 10)
    Roma::Tools::Bench.new([@kvs.nid], out: @out, interval: interval)
  end

  def test_set_and_get
    bench.run(%i(set get), num: 3, threads: 2)
    assert_equal({ 'key_0' => 'value_0', 'key_1' => 'value_1', 'key_2' => 'value_2' }, @kvs.data)
    assert_equal 6, @kvs.commands.grep(/\Aget /).size
    assert_equal "Start thread 0\nStart thread 1\n", @out.string.lines.grep(/Start/).join
    assert_empty @out.string.lines.grep(/failed/)
  end

  def test_value_size
    bench.run(%i(set get), num: 2, value_size: 5)
    assert_equal [5, 5], @kvs.data.values.map(&:size)
    assert_match(/\A[a-z]{5}\z/, @kvs.data['key_0'])
    assert_empty @out.string.lines.grep(/failed/)
  end

  def test_wrong_values
    @kvs.data['key_0'] = 'other'
    bench.run(%i(get), num: 2)
    assert_equal ["get k=0 failed\n", "get k=1 failed\n"], @out.string.lines.grep(/failed/)
  end

  def test_set_failed
    @kvs.replies['set'] = "NOT_STORED\r\n"
    bench.run(%i(set), num: 1)
    assert_include @out.string, "set k=0 failed\n"
  end

  def test_set_error
    @kvs.replies['set'] = "SERVER_ERROR busy\r\n"
    bench.run(%i(set), num: 1)
    assert_include @out.string, "set k=0 set key_0: SERVER_ERROR busy\n"
  end

  def test_stop
    b = bench
    t = Thread.new { b.run(%i(rand), num: 5) }
    sleep 0.1
    b.stop
    assert_not_nil t.join(5)
  end

  def test_node_down
    Roma::Tools::Bench.new([down_node], out: @out).run(%i(get), num: 1)
    assert_match(/^get k=0 localhost_\d+: .*refused/i, @out.string)
  end

  def test_rand
    bench.run(%i(rand), num: 5, duration: 0.2)
    names = @kvs.commands.map { |c| c.split.first }.uniq.sort
    assert_equal %w(delete get set), names
    assert_empty @out.string.lines.grep(/failed/)
  end

  def test_report
    bench(interval: 0.1).run(%i(rand), num: 5, duration: 0.35)
    assert_match(/^qps=\d+ max=\d+\.\d+ min=\d+\.\d+ ave=\d+\.\d+$/, @out.string)
  end

  def test_stats
    stats = Roma::Tools::Bench::Stats.new
    assert_equal 'qps=0 max=0.000000 min=0.000000 ave=0.000000', stats.report(10)
    [0.5, 0.1, 0.3].each { |t| stats.record(t) }
    assert_equal 'qps=1 max=0.500000 min=0.100000 ave=0.666667', stats.report(2)
    # It starts over.
    assert_equal 'qps=0 max=0.000000 min=0.000000 ave=0.000000', stats.report(10)
  end
end

class ConsistencyTestTest < Test::Unit::TestCase
  include ToolTestHelper
  include FakeKVSHelper

  def setup
    super
    @kvs = fake_kvs
    @out = StringIO.new
  end

  def consistency(**opts)
    Roma::Tools::ConsistencyTest.new([@kvs.nid], out: @out).run(**opts)
  end

  def test_rounds
    assert_equal 0, consistency(keys: 3, rounds: 2)
    assert_equal({ 'key_0' => '2', 'key_1' => '2', 'key_2' => '2' }, @kvs.data)
    assert_equal '', @out.string
  end

  def test_hundred_rounds
    consistency(keys: 1, rounds: 100)
    assert_equal "100 loop has finished.\n", @out.string
  end

  # The values are kept by the node, but not stored.
  def test_errors
    @kvs.replies['set'] = "NOT_STORED\r\n"
    assert_equal 2, consistency(keys: 2, rounds: 1)
    assert_match(/^set k=key_0 NOT_STORED$/, @out.string)
    assert_match(/^error k=key_1 nil$/, @out.string)
  end

  def test_node_down
    assert_equal 1, Roma::Tools::ConsistencyTest.new([down_node], out: @out).run(keys: 1, rounds: 1)
    assert_match(/^set k=key_0 localhost_\d+: /, @out.string)
    assert_match(/^error k=key_0 localhost_\d+: /, @out.string)
  end
end

class SafecopyTestTest < Test::Unit::TestCase
  include ToolTestHelper
  include FakeKVSHelper

  # Changes the statuses of the files as a node, when it is asked.
  class FakeAdmin
    attr_reader :requests, :statuses
    attr_accessor :reply

    def initialize(divnum)
      @statuses = [:normal] * divnum
      @requests = []
      @reply = 'PUSHED'
    end

    def request(_nid, cmd)
      @requests << cmd
      _, n, status, _hname = cmd.split
      @statuses[n.to_i] = status == 'safecopy' ? :safecopy_flushed : :normal if @reply == 'PUSHED'
      @reply
    end

    def command(_nid, cmd)
      ["storages[roma].storage.divnum #{@statuses.size}", "storages[roma].storage.safecopy_stats #{@statuses.inspect}", 'END']
        .tap { @last_stats = cmd }
    end
  end

  def setup
    super
    @kvs = fake_kvs
    @admin = FakeAdmin.new(2)
    @out = StringIO.new
  end

  def safecopy_test(**opts)
    kvs = @kvs
    Roma::Tools::SafecopyTest.new(kvs.nid, out: @out, admin: @admin, wait: 0,
                                  client: -> { Roma::Tools::TextClient.new([kvs.nid]) }).run(**opts)
  end

  def test_run
    assert_equal 0, safecopy_test(keys: 5)
    assert_equal ['set_storage_status 0 safecopy roma', 'set_storage_status 0 normal roma',
                  'set_storage_status 1 safecopy roma', 'set_storage_status 1 normal roma'], @admin.requests
    assert_equal [:normal, :normal], @admin.statuses
    assert_equal 10, @kvs.data.keys.grep(/\A(flushing|caching)_key_\d\z/).size
    assert_match(/\A1th test =+\n1th file \*+\n  \[:safecopy_flushed, :normal\]\n  \[:normal, :normal\]\n2th file/, @out.string)
  end

  def test_count
    safecopy_test(keys: 1, count: 2)
    assert_equal 8, @admin.requests.size
    assert_match(/^2th test/, @out.string)
  end

  # The keys are checked against what the writer has set. The client that
  # checks the caching keys, made after the two writers and the check of the
  # flushing keys, gets a wrong value.
  def test_wrong_value
    kvs = @kvs
    made = 0
    client = lambda do
      made += 1
      Roma::Tools::TextClient.new([kvs.nid]).tap do |c|
        next unless made == 4
        def c.get(key)
          key == 'caching_key_0' ? 'wrong' : super
        end
      end
    end
    errors = Roma::Tools::SafecopyTest.new(kvs.nid, out: @out, admin: @admin, wait: 0, client: client).run(keys: 2)
    assert_equal 1, errors
    assert_match(/^error k=caching_key_0 "wrong" \(expected \d+\)$/, @out.string)
  end

  def test_refused
    @admin.reply = 'CLIENT_ERROR storage[0] != :normal status'
    assert_raise_message('set_storage_status 0 safecopy: CLIENT_ERROR storage[0] != :normal status') do
      safecopy_test(keys: 1)
    end
    assert_equal 10, @admin.requests.size
  end

  def test_no_hash
    @admin.define_singleton_method(:command) { |_nid, _cmd| ['END'] }
    assert_raise_message("#{@kvs.nid} has no roma.") { safecopy_test(keys: 1) }
  end
end

class SafecopyWriterTest < Test::Unit::TestCase
  include ToolTestHelper
  include FakeKVSHelper

  def setup
    super
    @kvs = fake_kvs
  end

  def writer(keys)
    Roma::Tools::SafecopyTest::Writer.new(Roma::Tools::TextClient.new([@kvs.nid]), 'k', keys)
  end

  # The keys before the last one set have the round, and the others the
  # round before.
  def test_expected
    w = writer(3)
    w.instance_variable_set(:@round, 4)
    w.instance_variable_set(:@done, 1)
    assert_equal %w(4 4 3), (0..2).map { |i| w.expected(i) }
    w.instance_variable_set(:@done, 2)
    assert_equal %w(4 4 4), (0..2).map { |i| w.expected(i) }
  end

  def test_rounds
    w = writer(3).start
    assert_equal 1, w.wait_round
    assert_equal 2, w.wait_round
    w.stop
    assert_equal (0..2).map { |i| w.expected(i) }, (0..2).map { |i| @kvs.data["k_#{i}"] }
  end

  # The key that isn't stored is tried again, until it is stopped.
  def test_stop_while_retrying
    @kvs.replies['set'] = "NOT_STORED\r\n"
    w = writer(1).start
    sleep 0.3
    w.stop
    assert_operator @kvs.commands.size, :>, 1
    assert_equal '0', w.expected(0)
  end

  def test_thread_died
    w = writer(1)
    w.instance_variable_get(:@client).define_singleton_method(:set) { |*| raise ArgumentError, 'broken' }
    w.start
    assert_raise_message('broken') { w.wait_round }
  end
end

class TestScenarioTest < Test::Unit::TestCase
  include ToolTestHelper

  # Answers the stats as a ring whose nodes go down when they are killed.
  class FakeAdmin
    attr_accessor :started, :lengths

    def initialize
      @started = true
      @lengths = []
    end

    def command(_nid, cmd)
      case cmd
      when /enabled_failover/ then ["routing.enabled_failover #{@started}", 'END']
      when /nodes/ then ["routing.nodes.length #{@lengths.size > 1 ? @lengths.shift : @lengths.first}", 'END']
      end
    end
  end

  def setup
    super
    @admin = FakeAdmin.new
    @out = StringIO.new
    @spawned = []
    @signals = []
  end

  def scenario(nodes: 3)
    t = Roma::Tools::TestScenario.new(out: @out, work_dir: @dir, port: 11211, nodes: nodes, admin: @admin,
                                      timeout: 0.3, poll: 0.01, stop_timeout: 0.1)
    spawned = @spawned
    signals = @signals
    t.define_singleton_method(:spawn) { |*cmd| spawned << cmd; 100 + spawned.size }
    t.define_singleton_method(:kill) { |nid, sig| signals << [nid, sig] }
    t.define_singleton_method(:wait) { |_pid, _flags = 0| true }
    t
  end

  # No requests are sent.
  def without_bench
    Roma::Tools::Bench.class_eval do
      alias_method :real_run, :run
      define_method(:run) { |*, **| nil }
    end
    yield
  ensure
    Roma::Tools::Bench.class_eval do
      alias_method :run, :real_run
      remove_method :real_run
    end
  end

  def test_run
    @admin.lengths = [3, 3, 2]
    File.write(File.join(@dir, 'localhost_11211.log'), 'old')
    without_bench { scenario.run }
    assert_equal %w(localhost_11211.route localhost_11212.route localhost_11213.route), Dir.children(@dir).sort
    assert_equal [RbConfig.ruby, Roma::Tools::TestScenario::ROMAD, 'localhost', '-p', '11211', '--replication_in_host'],
                 @spawned[0]
    assert_equal 3, @spawned.size
    assert_equal [['localhost_11213', :KILL]] + %w(localhost_11211 localhost_11212 localhost_11213).map { |n| [n, :INT] },
                 @signals
    assert_match(/localhost_11211 knows 3 nodes\.\nkill localhost_11213\nlocalhost_11211 knows 2 nodes\.\nThe scenario has succeeded\.\n\z/,
                 @out.string)
  end

  # The romads are stopped even then.
  def test_not_found_down
    @admin.lengths = [3]
    error = assert_raise(Roma::Tools::Error) { without_bench { scenario.run } }
    assert_equal 'localhost_11211 knows 3 nodes, not 2.', error.message
    assert_equal [:INT] * 3, @signals.drop(1).map(&:last)
  end

  def test_not_started
    @admin.started = false
    assert_raise_message('Timed out: localhost_11211 has started.') { without_bench { scenario.run } }
    assert_equal [:INT] * 3, @signals.map(&:last)
  end

  def test_one_node
    assert_raise_message('The scenario needs 2 nodes or more.') { scenario(nodes: 1) }
  end

  # A romad that doesn't stop by INT is killed.
  def test_kill_on_stop
    @admin.lengths = [2, 1]
    t = scenario(nodes: 2)
    t.define_singleton_method(:wait) { |_pid, flags = 0| flags.zero? }
    without_bench { t.run }
    assert_equal [['localhost_11212', :KILL], ['localhost_11211', :INT], ['localhost_11212', :INT],
                  ['localhost_11211', :KILL], ['localhost_11212', :KILL]], @signals
    assert_match(/kill localhost_11211, which didn't stop/, @out.string)
  end
end
