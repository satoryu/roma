require 'test_helper'
require 'rbconfig'
require 'stringio'
require 'tool_test_helper'
require 'roma/tools/bench'
require 'roma/tools/test_scenario'

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

  # Unless +stops_by_int+, the romads stop only when they are killed.
  def scenario(nodes: 3, stops_by_int: true)
    t = Roma::Tools::TestScenario.new(out: @out, work_dir: @dir, port: 11211, nodes: nodes, admin: @admin,
                                      timeout: 0.3, poll: 0.01, stop_timeout: 0.1)
    spawned = @spawned
    signals = @signals
    t.define_singleton_method(:spawn) { |*cmd| spawned << cmd; 100 + spawned.size }
    t.define_singleton_method(:kill) { |nid, sig| signals << [nid, sig] }
    t.define_singleton_method(:wait) { |_pid, flags = 0| stops_by_int || flags.zero? }
    t
  end

  # No requests are sent.
  def without_bench
    idle = Object.new
    def idle.run(*, **) = nil
    def idle.stop = nil
    Roma::Tools::Bench.define_singleton_method(:new) { |*, **| idle }
    yield
  ensure
    Roma::Tools::Bench.singleton_class.remove_method(:new)
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
    t = scenario(nodes: 2, stops_by_int: false)
    without_bench { t.run }
    assert_equal [['localhost_11212', :KILL], ['localhost_11211', :INT], ['localhost_11212', :INT],
                  ['localhost_11211', :KILL], ['localhost_11212', :KILL]], @signals
    assert_match(/kill localhost_11211, which didn't stop/, @out.string)
  end
end
