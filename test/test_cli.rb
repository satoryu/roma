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

  # bin/roma runs the CLI and exits with its status.
  def test_command
    cmd = [RbConfig.ruby]
    cmd.push('-r', File.expand_path('start_coverage', __dir__)) if ENV['COVERAGE']
    out, _err, status = Open3.capture3(*cmd, ROMA, 'mkroute', '-d', '3', 'host1_1', 'host2_1', chdir: @dir)
    assert_true status.success?
    assert_match(/Routing table has created/, out)
    assert_equal %w(host1_1.route host2_1.route), Dir.children(@dir).sort
    _out, err, status = Open3.capture3(*cmd, ROMA, 'mkroute', chdir: @dir)
    assert_equal 1, status.exitstatus
    assert_match(/called with no arguments/, err)
  end
end
