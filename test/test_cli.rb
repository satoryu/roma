require 'test_helper'
require 'open3'
require 'rbconfig'
require 'stringio'
require 'tmpdir'
require 'roma/cli'
require 'roma/routing/routing_data'

class CLITest < Test::Unit::TestCase
  ROMA = File.expand_path('../bin/roma', __dir__)

  def setup
    @dir = Dir.mktmpdir('roma_cli')
  end

  def teardown
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

  def load_route(nid)
    Roma::Routing::RoutingData.load_snapshot(File.join(@dir, "#{nid}.route"))
  end

  def test_commands
    out, _err, status = roma
    assert_nil status
    assert_match(/roma mkroute NODE_ID\.\.\./, out)
  end

  def test_unknown_command
    _out, err, status = roma('unknown')
    assert_equal 1, status
    assert_match(/Could not find command "unknown"/, err)
  end

  def test_mkroute
    out, _err, status = roma('mkroute', 'host1:1', 'host2_1')
    assert_nil status
    assert_match(/Routing table has created/, out)
    rd = load_route('host1_1')
    assert_equal %w(host1_1 host2_1), rd.nodes
    assert_equal [32, 9, 2], [rd.dgst_bits, rd.div_bits, rd.rn]
  end

  data('short' => %w(-h 16 -d 4 -r 3),
       'long' => %w(--hash 16 --divide=4 --redundant 3))
  def test_mkroute_options(options)
    _out, _err, status = roma('mkroute', 'host1_1', 'host2_1', *options, 'host3_1')
    assert_nil status
    rd = load_route('host1_1')
    assert_equal [16, 4, 3], [rd.dgst_bits, rd.div_bits, rd.rn]
  end

  # Both spellings, since the old mkroute took --replication_in_host.
  data('hyphen' => '--replication-in-host', 'underscore' => '--replication_in_host')
  def test_mkroute_replication_in_host(option)
    roma('mkroute', '-d', '3', option, 'host1_1', 'host1_2')
    load_route('host1_1').v_idx.each_value { |nids| assert_equal 2, nids.size }
  end

  data('after' => %w(mkroute host1_1 --help), 'before' => %w(--help mkroute), 'help' => %w(help mkroute))
  def test_mkroute_help(args)
    out, _err, status = roma(*args)
    assert_nil status
    assert_match(/Usage:\n  roma mkroute NODE_ID\.\.\..*--hash=BITS.*--replication-in-host/m, out)
    assert_equal [], Dir.children(@dir)
  end

  data('no nodes' => [%w(), /"roma mkroute" was called with no arguments/],
       'unknown option' => [%w(host1_1 host2_1 --unknown), /Unknown switches "--unknown"/],
       'not a number' => [%w(-d x host1_1 host2_1), /Expected numeric value for '--divide'; got "x"/],
       'invalid combination' => [%w(-r 3 host1_1 host2_1), /\AThe node-id number should be redundant number or more\.\n\z/])
  def test_mkroute_invalid_arguments(data)
    args, message = data
    out, err, status = roma('mkroute', *args)
    assert_equal 1, status
    assert_equal '', out
    assert_match(message, err)
    assert_equal [], Dir.children(@dir)
  end

  def test_ssroute
    rd = Roma::Routing::RoutingData.create(32, 3, 1, ['host1_1'])
    rd.save(File.join(@dir, 'host1_1.route'))
    2.times { |i| File.write(File.join(@dir, "host1_1.route.#{i + 1}"), "2026-01-01T00:00:00.1 join host#{i + 2}_1\n") }
    out, _err, status = roma('ssroute', 'host1_1')
    assert_nil status
    assert_equal "succeed\n", out
    assert_equal %w(host1_1 host2_1), load_route('host1_1').nodes
  end

  def test_ssroute_error
    out, err, status = roma('ssroute', 'host1_1')
    assert_equal 1, status
    assert_equal '', out
    assert_match(/\Aerror:No such file or directory/, err)
  end

  def write_logs
    File.write(File.join(@dir, 'a.log'), "W, [2026-01-01T00:00:01.000001 #1]  WARN -- : a1\n" \
                                         "E, [2026-01-01T00:00:03.000001 #1] ERROR -- : a2\n" \
                                         "E, [2026-01-01T00:00:05.000001 #1] ERROR -- : a3\n")
    File.write(File.join(@dir, 'b.log'), "W, [2026-01-01T00:00:02.000001 #2]  WARN -- : b1\n" \
                                         "I, [2026-01-01T00:00:04.000001 #2]  INFO -- : b2\n")
  end

  def test_log_merger
    write_logs
    out, _err, status = roma('log_merger', 'a.log', 'b.log')
    assert_nil status
    assert_equal %w(a1 b1 a2 b2 a3), out.lines.map { |l| l.split.last }
  end

  # Each option leaves out a line: a1 by the start, b2 by the level and a3
  # by the end.
  data('short' => %w(-l WARN -s 20260101000002 -e 20260101000004),
       'long' => %w(--level=WARN --start=20260101000002 --end=20260101000004))
  def test_log_merger_options(options)
    write_logs
    out, _err, _status = roma('log_merger', 'a.log', 'b.log', *options)
    assert_equal %w(b1 a2), out.lines.map { |l| l.split.last }
  end

  data('short' => '-o', 'long' => '--output')
  def test_log_merger_output(option)
    write_logs
    out, _err, status = roma('log_merger', 'a.log', option, 'merged.log')
    assert_nil status
    assert_equal '', out
    assert_equal %w(a1 a2 a3), File.readlines(File.join(@dir, 'merged.log')).map { |l| l.split.last }
  end

  data('no files' => [%w(), /"roma log_merger" was called with no arguments/],
       'missing file' => [%w(nofile.log), /\ANo such file or directory @ rb_sysopen - nofile.log\n\z/],
       'unknown level' => [%w(-l BOGUS a.log), /Expected '--level' to be one of TRACE, DEBUG, .*; got BOGUS/])
  def test_log_merger_invalid_arguments(data)
    args, message = data
    write_logs
    out, err, status = roma('log_merger', *args)
    assert_equal 1, status
    assert_equal '', out
    assert_match(message, err)
  end

  def test_check_tc_flag
    FileUtils.mkdir_p(["#{@dir}/tc/bin", "#{@dir}/ds"])
    File.write("#{@dir}/tc/bin/tchmgr", "#!/bin/sh\nprintf 'additional flags: open\\n'\n")
    File.chmod(0o755, "#{@dir}/tc/bin/tchmgr")
    FileUtils.touch("#{@dir}/ds/a.tc")
    out, _err, status = roma('check_tc_flag', '--storage', 'ds', '--library', 'tc')
    assert_nil status
    assert_equal "ds/a.tc :  open\n", out
  end

  # By default, both are the current directory.
  def test_check_tc_flag_defaults
    FileUtils.touch("#{@dir}/a.tc")
    out, err, status = roma('check_tc_flag')
    assert_equal 1, status
    assert_equal '', out
    assert_match(%r{No such file or directory - \./bin/tchmgr}, err)
  end

  def run_roma(*args, stdin: '')
    cmd = [RbConfig.ruby]
    cmd.push('-r', File.expand_path('start_coverage', __dir__)) if ENV['COVERAGE']
    Open3.capture3(*cmd, ROMA, *args, stdin_data: stdin, chdir: @dir)
  end

  # It reads the answers from the standard input.
  def test_mkconfig
    _out, err, status = run_roma('mkconfig', stdin: "1\n\n2\n1\n\n\n")
    assert_true status.success?, err
    assert_match(/^    STORAGE_CLASS = Roma::Storage::RubyHashStorage$/, File.read(File.join(@dir, 'config.rb')))
  end

  data('short' => '-m', 'long' => '--with-menu', 'underscore' => '--with_menu')
  def test_mkconfig_with_menu(option)
    out, err, status = run_roma('mkconfig', option, stdin: "4\n")
    assert_true status.success?, err
    assert_match(/Please select by number/, out)
    assert_true File.exist?(File.join(@dir, 'config.rb'))
  end

  # bin/roma runs the CLI and exits with its status.
  def test_command
    out, _err, status = run_roma('mkroute', '-d', '3', 'host1_1', 'host2_1')
    assert_true status.success?
    assert_match(/Routing table has created/, out)
    assert_equal %w(host1_1.route host2_1.route), Dir.children(@dir).sort
    _out, err, status = run_roma('mkroute')
    assert_equal 1, status.exitstatus
    assert_match(/called with no arguments/, err)
  end
end
