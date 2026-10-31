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
require 'roma/tools/recoverlost'
require 'roma/tools/chg_redundancy'
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

# Opening the storage files.
class RecoverLostStorageTest < Test::Unit::TestCase
  include ToolTestHelper

  def open_storage(*files)
    files.each { |f| File.write(File.join(@dir, f), '') }
    Roma::Tools::RecoverLost.new.send(:open_storage, @dir, [0])
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
    files = %w(0.mem 1.mem 0.cache.mem 0.mem-journal)
    storage = with_storage('mem' => ['roma/storage/ruby_hash_storage', :RubyHashStorage, 'roma-storage']) do
      open_storage(*files)
    end
    assert_equal [2, @dir], [storage.divnum, storage.instance_variable_get(:@storage_path)]
    assert_equal({ 0 => 0 }, storage.hdiv)
  end

  def with_storage(storages)
    saved = Roma::Tools::RecoverLost::STORAGES
    Roma::Tools::RecoverLost.send(:remove_const, :STORAGES)
    Roma::Tools::RecoverLost.const_set(:STORAGES, saved.merge(storages))
    yield
  ensure
    Roma::Tools::RecoverLost.send(:remove_const, :STORAGES)
    Roma::Tools::RecoverLost.const_set(:STORAGES, saved)
  end
end
