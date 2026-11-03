require 'test_helper'
require 'open3'
require 'rbconfig'
require 'stringio'
require 'tool_test_helper'
require 'roma/tools/config_creator'

class ConfigCreatorTest < Test::Unit::TestCase
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

  def create_config(*lines, mode: :no_menu)
    out = StringIO.new
    Roma::Tools::ConfigCreator.new(input: Input.new(lines), out: out, path: @path).run(mode)
    out.string
  end

  def config
    File.read(@path)
  end

  # Ruby Hash, a wrong answer, a Ruby client, and the defaults for the
  # machines.
  def test_hash
    out = create_config('1', '0', '1', '', '')
    assert_match(/Please set FileDescriptor bigger than 10\./, out)
    assert_match(/After\r\n.*storage.engine: :hash/m, out)
    assert_match(/^  config.storage.engine = :hash$/, config)
    assert_match(/^  config.storage.option = ""$/, config)
    assert_match(/^  # config.command_plugin_path = "\.\/command_plugins"$/, config)
  end

  # romad can load the file. In another process, not to change Roma.config.
  def test_hash_config_loads
    create_config('1', '1', '', '')
    script = 'require "roma/configuration"; Roma.load_config(ARGV[0]); print Roma.config.storage.engine_class'
    out, err, status = Open3.capture3(RbConfig.ruby, '-I', File.expand_path('../../../lib', __dir__),
                                      '-e', script, @path)
    assert_true status.success?, err
    assert_equal 'Roma::Storage::HashStorage', out
  end

  # Groonga asks the memory, the processes, the servers and the data, and
  # the options are calculated from them.
  def test_groonga
    out = create_config('2', '1.5', '2', '1', '100000000', '2', '3')
    # 100000000 * 2 * 2 / 1 / 10, and (1.5GB - 1GB) / 2 / 10
    option = 'bnum=40000000#xmsiz=26843545#opts=d#dfunit=10'
    assert_match(/^  config.storage.engine = :groonga$/, config)
    assert_match(/^  config.storage.option = #{Regexp.escape(option.inspect)}$/, config)
    assert_match(/After\r\n.*storage.option: #{Regexp.escape(option.inspect)}/m, out)
    assert_match(/After\r\n.*storage.engine: :groonga/m, out)
    # The servers asked for the storage: 1 * 30 + (3 - 1) * 12 * 2
    assert_match(/bigger than 78\./, out)
  end

  # The bnum is at least 5000000, and the xmsiz is half of the memory if it
  # is less than what the OS takes.
  def test_groonga_minimum
    create_config('2', '', '', '', '', '3', '')
    assert_match(/^  config.storage.option = "bnum=5000000#xmsiz=16106127#/, config)
  end

  # Only what is chosen from the menu is set.
  def test_with_menu
    out = create_config('1', '2', '1.5', '2', '1', '100000000', '3', mode: :with_menu)
    assert_match(/Please select by number\./, out)
    assert_match(/^  config.storage.engine = :groonga$/, config)
    assert_not_match(/FileDescriptor/, out)
  end

  data('exit' => 'exit', 'quit' => 'quit', 'balse' => 'balse', 'end of input' => nil)
  def test_quit(line)
    out = create_config(*['1', line].compact)
    assert_match(/config.rb  were not created!/, out)
    assert_false File.exist?(@path)
  end

  def test_overwrite
    File.write(@path, 'old')
    assert_match(/were not created!/, create_config('n'))
    assert_equal 'old', config
    create_config('y', '1', '1', '', '')
    assert_match(/:hash/, config)
  end
end
