require 'test_helper'
require 'stringio'
require 'fake_node'
require 'tool_test_helper'
require 'roma/tools/node_command'

class NodeCommandTest < Test::Unit::TestCase
  include ToolTestHelper

  def run_adm(cmd, input: '', **opts)
    @out = StringIO.new
    Roma::Tools::NodeCommand.new(input: StringIO.new(input), out: @out).run(@node.node_id, cmd, **opts)
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
