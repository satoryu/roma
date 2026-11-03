require 'test_helper'
require 'open3'
require 'rbconfig'
require 'stringio'
require 'tmpdir'
require 'fake_node'
require 'fake_kvs'
require 'roma/cli'
require 'roma/routing/routing_data'

class CLITest < Test::Unit::TestCase
  ROMA = File.expand_path('../../bin/roma', __dir__)

  def setup
    @dir = Dir.mktmpdir('roma_cli')
    @fake_nodes = []
  end

  def teardown
    @fake_nodes.each(&:close)
    FileUtils.rm_rf(@dir)
  end

  # Runs roma with +args+ in @dir, and returns stdout, stderr and the exit
  # status (nil if it didn't exit).
  def roma(*args)
    saved = [$stdout, $stderr]
    $stdout = StringIO.new
    $stderr = StringIO.new
    status = nil
    begin
      Dir.chdir(@dir) { Roma::CLI.start(args) }
    rescue SystemExit => e
      status = e.status
    end
    [$stdout.string, $stderr.string, status]
  ensure
    $stdout, $stderr = saved
  end

  def load_route(node_id)
    Roma::Routing::RoutingData.load_snapshot(File.join(@dir, "#{node_id}.route"))
  end

  def test_commands
    out, _err, status = roma
    assert_nil status
    assert_match(/roma route SUBCOMMAND/, out)
    assert_no_match(/roma route create/, out)
  end

  def test_unknown_command
    _out, err, status = roma('unknown')
    assert_equal 1, status
    assert_match(/Could not find command "unknown"/, err)
  end

  data('group' => %w(route), 'help' => %w(help route), 'route help' => %w(route help))
  def test_group_commands(args)
    out, _err, status = roma(*args)
    assert_nil status
    assert_match(/roma route change-redundancy NUM NODE_ID.*roma route create NODE_ID\.\.\..*roma route snapshot NODE_ID/m, out)
  end

  def test_unknown_command_in_group
    _out, err, status = roma('route', 'unknown')
    assert_equal 1, status
    assert_match(/Could not find command "unknown"/, err)
  end

  # A command out of the groups takes --help after it too.
  data('after' => %w(benchmark host1_1 --help), 'before' => %w(--help benchmark))
  def test_benchmark_help(args)
    out, _err, status = roma(*args)
    assert_nil status
    assert_match(/Usage:\n  roma benchmark NODE_ID\.\.\..*--key-count=N/m, out)
  end

  def test_route_create
    out, _err, status = roma('route', 'create', 'host1:1', 'host2_1')
    assert_nil status
    assert_match(/Routing table has created/, out)
    routing_data = load_route('host1_1')
    assert_equal %w(host1_1 host2_1), routing_data.nodes
    assert_equal [32, 9, 2], [routing_data.digest_bits, routing_data.divide_bits, routing_data.redundancy]
  end

  data('short' => %w(--digest-bits 16 -d 4 -r 3),
       'long' => %w(--digest-bits 16 --divide-bits=4 --redundancy 3))
  def test_route_create_options(options)
    _out, _err, status = roma('route', 'create', 'host1_1', 'host2_1', *options, 'host3_1')
    assert_nil status
    routing_data = load_route('host1_1')
    assert_equal [16, 4, 3], [routing_data.digest_bits, routing_data.divide_bits, routing_data.redundancy]
  end

  # Both spellings, since mkroute of 1.x took --replication_in_host.
  data('hyphen' => '--replication-in-host', 'underscore' => '--replication_in_host')
  def test_route_create_replication_in_host(option)
    roma('route', 'create', '-d', '3', option, 'host1_1', 'host1_2')
    load_route('host1_1').routes.each_value { |node_ids| assert_equal 2, node_ids.size }
  end

  data('after' => %w(route create host1_1 --help), '-h' => %w(route create -h),
       'help' => %w(route help create))
  def test_route_create_help(args)
    out, _err, status = roma(*args)
    assert_nil status
    assert_match(/Usage:\n  roma route create NODE_ID\.\.\..*--digest-bits=BITS.*--replication-in-host/m, out)
    assert_equal [], Dir.children(@dir)
  end

  data('no nodes' => [%w(), /"roma route create" was called with no arguments/],
       'unknown option' => [%w(host1_1 host2_1 --unknown), /Unknown switches "--unknown"/],
       'not a number' => [%w(-d x host1_1 host2_1), /Expected numeric value for '--divide-bits'; got "x"/],
       'invalid combination' => [%w(-r 3 host1_1 host2_1), /\AThe number of the node IDs should be the redundancy or more\.\n\z/])
  def test_route_create_invalid_arguments(data)
    args, message = data
    out, err, status = roma('route', 'create', *args)
    assert_equal 1, status
    assert_equal '', out
    assert_match(message, err)
    assert_equal [], Dir.children(@dir)
  end

  def test_route_snapshot
    routing_data = Roma::Routing::RoutingData.create(32, 3, 1, ['host1_1'])
    routing_data.save(File.join(@dir, 'host1_1.route'))
    2.times { |i| File.write(File.join(@dir, "host1_1.route.#{i + 1}"), "2026-01-01T00:00:00.1 join host#{i + 2}_1\n") }
    out, _err, status = roma('route', 'snapshot', 'host1_1')
    assert_nil status
    assert_equal "succeed\n", out
    assert_equal %w(host1_1 host2_1), load_route('host1_1').nodes
  end

  def test_route_snapshot_error
    out, err, status = roma('route', 'snapshot', 'host1_1')
    assert_equal 1, status
    assert_equal '', out
    assert_match(/\Aerror:No such file or directory/, err)
  end

  # A FakeNode that answers routingdump with the routing table of itself and
  # +others+.
  def routing_node(*others, redundancy: 1)
    node = FakeNode.new
    @fake_nodes << node
    @routing_data = Roma::Routing::RoutingData.create(32, 3, redundancy, [node.node_id, *others], true)
    dump = Marshal.dump(@routing_data)
    node.replies['routingdump'] = "#{dump.bytesize}\r\n#{dump}\r\nEND\r\n"
    node
  end

  def test_route_change_redundancy
    node = routing_node('localhost_1', redundancy: 2)
    out, _err, status = roma('route', 'change-redundancy', '1', node.node_id)
    assert_nil status
    routing_data = YAML.unsafe_load(out)
    assert_equal 1, routing_data.redundancy
    assert_equal [1], routing_data.routes.values.map(&:size).uniq
  end

  data('not a number' => [%w(one localhost_1), /The redundancy should be 1 or more/],
       'zero' => [%w(0 localhost_1), /The redundancy should be 1 or more/],
       'node down' => [%w(1 localhost_1), /\Alocalhost_1: /],
       'missing node' => [%w(1), /was called with arguments \["1"\]/])
  def test_route_change_redundancy_errors(data)
    args, message = data
    out, err, status = roma('route', 'change-redundancy', *args)
    assert_equal 1, status
    assert_equal '', out
    assert_match(message, err)
  end

  def test_cluster_command
    other = FakeNode.new
    @fake_nodes << other
    node = routing_node(other.node_id)
    out, _err, status = roma('cluster', 'command', node.node_id, 'stats', 'run')
    assert_nil status
    assert_equal @routing_data.nodes.map { |node_id| "****** #{node_id}\r\nSTORED\r\n" }.join, out
    assert_equal ['stats run'], other.commands
  end

  def test_cluster_command_error
    out, err, status = roma('cluster', 'command', 'localhost_1', 'whoami')
    assert_equal 1, status
    assert_equal '', out
    assert_match(/\Alocalhost_1: /, err)
  end

  def fake_node
    FakeNode.new.tap { |node| @fake_nodes << node }
  end

  def test_node_command
    node = fake_node
    # FakeNode answers the line of the value.
    node.replies['set'] = proc { '' }
    out, _err, status = roma('node', 'command', 'set', 'key1', '0', '0', '5', '-p', node.node_id.split('_')[1], '-v', 'value')
    assert_nil status
    assert_equal "STORED\n", out
    assert_equal ['set key1 0 0 5', 'value'], node.commands
  end

  def test_node_command_host
    node = fake_node
    out, _err, _status = roma('node', 'command', 'whoami', '--host', '127.0.0.1', '--port', node.node_id.split('_')[1])
    assert_equal "ROMA\n", out
  end

  def test_node_command_balse
    node = fake_node
    node.replies['balse'] = "BYE\r\n"
    out, _err, status = roma('node', 'command', 'balse', '-y', '-p', node.node_id.split('_')[1])
    assert_nil status
    assert_equal "BYE\nSTORED\nSTORED\n", out
  end

  # The confirmation is read from the standard input.
  def test_node_command_rejected
    out, err, status = run_roma('node', 'command', 'balse', '-p', '1', stdin: "no\n")
    assert_equal 1, status.exitstatus
    assert_equal "Are you sure?(yes/no)\n", out
    assert_equal "The confirmation was rejected.\n", err
  end

  def test_node_command_node_down
    _out, err, status = roma('node', 'command', 'whoami', '-p', '1')
    assert_equal 1, status
    assert_match(/\Alocalhost_1: /, err)
  end

  # Records how the class of a tool is made and called, instead of running it.
  def spy_tool(klass, *methods)
    calls = []
    spy = Object.new
    # They return 0, such as the number of errors.
    methods.each { |m| spy.define_singleton_method(m) { |*args, **opts| calls << [m, args, opts]; 0 } }
    klass.define_singleton_method(:new) { |*args, **opts| calls << [:new, *args, opts]; spy }
    yield
    calls
  ensure
    klass.singleton_class.send(:remove_method, :new)
  end

  def test_storage_keys
    require 'roma/tools/key_list'
    calls = spy_tool(Roma::Tools::KeyList, :list) { roma('storage', 'keys', 'path', '-w', '0') }
    assert_equal [[:new, { wait: 0 }], [:list, ['path'], {}]], calls
  end

  data('short' => '-v', 'long' => '--value')
  def test_storage_key(option)
    require 'roma/tools/key_access'
    calls = spy_tool(Roma::Tools::KeyAccess, :access) { roma('storage', 'key', 'path', 'key1', option) }
    assert_equal [[:new, {}], [:access, %w(path key1), { value: true }]], calls
  end

  def test_storage_merge
    require 'roma/tools/storage_merger'
    out = nil
    calls = spy_tool(Roma::Tools::StorageMerger, :merge) do
      out, = roma('storage', 'merge', 'a', 'b', 'recent', '--digest-bits', '16', '-d', '4', '-n', '5')
    end
    assert_equal [[:new, {}], [:merge, %w(a b recent), { digest_bits: 16, divide_bits: 4, division_count: 5 }]], calls
    assert_equal "Make recent data process has succeed.\n", out
  end

  data('keys' => [%w(keys), /has no directories of storage files/],
       'key' => [%w(key key1), /has no directories of storage files/],
       'merge' => [%w(merge b recent), /has no directories of storage files/])
  def test_storage_tool_errors(data)
    args, message = data
    out, err, status = roma('storage', args[0], @dir, *args[1..])
    assert_equal 1, status
    assert_equal '', out
    assert_match(message, err)
  end

  def test_cluster_check
    node = fake_node
    node.replies['nodelist'] = "#{node.node_id}\r\n"
    out, _err, status = roma('cluster', 'check', node.node_id)
    assert_nil status
    assert_equal "#{node.node_id} => #{node.node_id} (1 nodes)\n", out
  end

  def test_cluster_check_failed
    node = fake_node
    node.replies['nodelist'] = "#{node.node_id}\r\n"
    out, err, status = roma('cluster', 'check', node.node_id, 'localhost_1')
    assert_equal 1, status
    assert_match(/\Aerror: localhost_1: /, out)
    assert_equal "The nodes don't answer the same nodes.\n", err
  end

  data('default' => [[], [:random], {}],
       'set and get' => [%w(-g -s), %i(set get), {}],
       'set and random' => [%w(--set --random), %i(set random), {}],
       'options' => [%w(-s -n 5 -t 2 -v 100 -D 3), [:set], { key_count: 5, threads: 2, value_size: 100, duration: 3 }])
  def test_benchmark(data)
    args, modes, opts = data
    require 'roma/tools/benchmark'
    calls = spy_tool(Roma::Tools::Benchmark, :run) { roma('benchmark', 'host1_1', 'host2_1', *args) }
    expected = { key_count: 10_000, threads: 1, value_size: nil, duration: nil }.merge(opts)
    assert_equal [[:new, %w(host1_1 host2_1), {}], [:run, [modes], expected]], calls
  end

  # romad parses the options, and tells its usage.
  data('--help' => '--help', '-h' => '-h')
  def test_server_help(option)
    out, _err, status = run_roma('server', option)
    assert_true status.success?
    assert_match(/\Ausage:roma server \[options\] address\n\s+-d, --daemon\n/, out)
  end

  data('no address' => [[], /\Aparse error: \nusage:roma server/],
       'unknown option' => [%w(--unknown localhost), /\Ainvalid option: --unknown\nusage:roma server/],
       'wrong port' => [%w(localhost -p abc), /\Aparse error: Port number is not numeric\./])
  def test_server_errors(data)
    args, message = data
    _out, err, status = run_roma('server', *args)
    assert_equal 1, status.exitstatus
    assert_match(message, err)
  end

  def test_server_in_help
    out, _err, _status = roma('help', 'server')
    assert_match(/roma server ADDRESS \[OPTIONS\]/, out)
  end

  # Records how RecoverLost is called, instead of recovering.
  def spy_recover_lost
    calls = []
    spy = Object.new
    spy.define_singleton_method(:recover) { |*args, **opts| calls << [:recover, args, opts] }
    spy.define_singleton_method(:recover_keys) { |*args| calls << [:recover_keys, args] }
    require 'roma/tools/recover_lost'
    Roma::Tools::RecoverLost.define_singleton_method(:new) { |**opts| calls << [:new, opts]; spy }
    yield
    calls
  ensure
    Roma::Tools::RecoverLost.singleton_class.send(:remove_method, :new)
  end

  data('lost' => [[], [:recover, ['host1_1', 'path'], { since: nil, all: false }]],
       'since' => [%w(-s 20260101000000), [:recover, ['host1_1', 'path'], { since: '20260101000000', all: false }]],
       'all' => [%w(--all --alist), [:recover, ['host1_1', 'path'], { since: nil, all: true }]],
       'keys' => [%w(--keys keys.txt), [:recover_keys, ['host1_1', 'path', %w(key1 key2)]]])
  def test_storage_recover_lost(data)
    args, call = data
    File.write(File.join(@dir, 'keys.txt'), "key1\n\nkey2\n")
    out = nil
    calls = spy_recover_lost { out, _err, _status = roma('storage', 'recover-lost', 'host1_1', 'path', *args) }
    assert_equal [[:new, { alist: args.include?('--alist') }], call], calls
    assert_equal "Recover process has succeed.\n", out
  end

  def test_storage_recover_lost_keys_from_stdin
    saved = $stdin
    $stdin = StringIO.new("key1\n")
    calls = spy_recover_lost { roma('storage', 'recover-lost', 'host1_1', 'path', '-k', '-') }
    assert_equal [:recover_keys, ['host1_1', 'path', %w(key1)]], calls.last
  ensure
    $stdin = saved
  end

  data('since and all' => [%w(-s 20260101000000 -a), /--since and --all can't be used together/],
       'all and keys' => [%w(-a -k -), /--all and --keys can't be used together/],
       'wrong time' => [%w(-s 2026), /The time should be YYYYMMDDHHMMSS/],
       'node down' => [[], /\Alocalhost_1: /])
  def test_storage_recover_lost_errors(data)
    args, message = data
    out, err, status = roma('storage', 'recover-lost', 'localhost_1', 'path', *args)
    assert_equal 1, status
    assert_equal '', out
    assert_match(message, err)
  end

  def write_logs
    File.write(File.join(@dir, 'a.log'), "W, [2026-01-01T00:00:01.000001 #1]  WARN -- : a1\n" \
                                         "E, [2026-01-01T00:00:03.000001 #1] ERROR -- : a2\n" \
                                         "E, [2026-01-01T00:00:05.000001 #1] ERROR -- : a3\n")
    File.write(File.join(@dir, 'b.log'), "W, [2026-01-01T00:00:02.000001 #2]  WARN -- : b1\n" \
                                         "I, [2026-01-01T00:00:04.000001 #2]  INFO -- : b2\n")
  end

  def test_log_merge
    write_logs
    out, _err, status = roma('log', 'merge', 'a.log', 'b.log')
    assert_nil status
    assert_equal %w(a1 b1 a2 b2 a3), out.lines.map { |l| l.split.last }
  end

  # Each option leaves out a line: a1 by the start, b2 by the level and a3
  # by the end.
  data('short' => %w(-l WARN -s 20260101000002 -e 20260101000004),
       'long' => %w(--level=WARN --start=20260101000002 --end=20260101000004))
  def test_log_merge_options(options)
    write_logs
    out, _err, _status = roma('log', 'merge', 'a.log', 'b.log', *options)
    assert_equal %w(b1 a2), out.lines.map { |l| l.split.last }
  end

  data('short' => '-o', 'long' => '--output')
  def test_log_merge_output(option)
    write_logs
    out, _err, status = roma('log', 'merge', 'a.log', option, 'merged.log')
    assert_nil status
    assert_equal '', out
    assert_equal %w(a1 a2 a3), File.readlines(File.join(@dir, 'merged.log')).map { |l| l.split.last }
  end

  data('no files' => [%w(), /"roma log merge" was called with no arguments/],
       'missing file' => [%w(nofile.log), /\ANo such file or directory @ rb_sysopen - nofile.log\n\z/],
       'unknown level' => [%w(-l BOGUS a.log), /Expected '--level' to be one of TRACE, DEBUG, .*; got BOGUS/])
  def test_log_merge_invalid_arguments(data)
    args, message = data
    write_logs
    out, err, status = roma('log', 'merge', *args)
    assert_equal 1, status
    assert_equal '', out
    assert_match(message, err)
  end

  def run_roma(*args, stdin: '')
    cmd = [RbConfig.ruby]
    cmd.push('-r', File.expand_path('../start_coverage', __dir__)) if ENV['COVERAGE']
    Open3.capture3(*cmd, ROMA, *args, stdin_data: stdin, chdir: @dir)
  end

  # It reads the answers from the standard input.
  def test_config_create
    _out, err, status = run_roma('config', 'create', stdin: "1\n\n2\n1\n\n\n")
    assert_true status.success?, err
    assert_match(/^  config.storage.engine = :hash$/, File.read(File.join(@dir, 'config.rb')))
  end

  data('short' => '-m', 'long' => '--with-menu', 'underscore' => '--with_menu')
  def test_config_create_with_menu(option)
    out, err, status = run_roma('config', 'create', option, stdin: "4\n")
    assert_true status.success?, err
    assert_match(/Please select by number/, out)
    assert_true File.exist?(File.join(@dir, 'config.rb'))
  end

  # bin/roma runs the CLI and exits with its status.
  def test_command_to_nodes
    node = routing_node
    out, err, status = run_roma('cluster', 'command', node.node_id, 'whoami')
    assert_true status.success?, err
    assert_equal "****** #{node.node_id}\r\nROMA\r\n", out
  end

  def test_command
    out, _err, status = run_roma('route', 'create', '-d', '3', 'host1_1', 'host2_1')
    assert_true status.success?
    assert_match(/Routing table has created/, out)
    assert_equal %w(host1_1.route host2_1.route), Dir.children(@dir).sort
    _out, err, status = run_roma('route', 'create')
    assert_equal 1, status.exitstatus
    assert_match(/called with no arguments/, err)
  end
end
