require 'test_helper'
require 'tool_test_helper'
require 'roma/tools/tribunus'

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
