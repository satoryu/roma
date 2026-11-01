require 'test_helper'
require 'open3'
require 'rbconfig'
require 'stringio'
require 'tool_test_helper'
require 'roma/tools/mkconfig'

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

  # Ruby Hash, a wrong answer, the plugins by default, a Ruby client, and
  # the defaults for the machines.
  def test_hash
    out = mkconfig('1', '', '0', '2', '1', '', '')
    assert_match(/Please set FileDescriptor bigger than 10\./, out)
    assert_match(/After\r\n.*storage.engine: :hash/m, out)
    assert_match(/^  config.storage.engine = :hash$/, config)
    assert_match(/^  config.storage.option = ""$/, config)
    assert_match(/^  config.plugins = \["plugin_storage.rb"\]$/, config)
  end

  # romad can load the file. In another process, not to change Roma.config.
  def test_hash_config_loads
    mkconfig('1', '', '2', '1', '', '')
    script = 'require "roma/configuration"; Roma.load_config(ARGV[0]); print Roma.config.storage.engine_class'
    out, err, status = Open3.capture3(RbConfig.ruby, '-I', File.expand_path('../../../lib', __dir__),
                                      '-e', script, @path)
    assert_true status.success?, err
    assert_equal 'Roma::Storage::HashStorage', out
  end

  # Groonga asks the memory, the processes, the servers and the data, and
  # the options are calculated from them.
  def test_groonga
    out = mkconfig('2', '1.5', '2', '1', '100000000', '', '2', '2', '3')
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
    mkconfig('2', '', '', '', '', '', '2', '3', '')
    assert_match(/^  config.storage.option = "bnum=5000000#xmsiz=16106127#/, config)
  end

  def test_plugins
    plugins = Roma::Tools::Mkconfig::Base.new['plugin']['choice']
    alist = plugins.index('plugin_alist.rb') + 1
    out = mkconfig('1', '1', '1', alist.to_s, '2', '1', '', '')
    assert_match(/After\r\n.*plugins: \["plugin_storage.rb", "plugin_alist.rb"\]/m, out)
    assert_match(/^  config.plugins = \["plugin_storage.rb", "plugin_alist.rb"\]$/, config)
  end

  # Without plugin_storage.rb, it asks to add it.
  def test_plugin_storage_added
    plugins = Roma::Tools::Mkconfig::Base.new['plugin']['choice']
    alist = plugins.index('plugin_alist.rb') + 1
    mkconfig('1', alist.to_s, '2', '1', '1', '', '')
    assert_match(/^  config.plugins = \["plugin_storage.rb", "plugin_alist.rb"\]$/, config)
  end

  def test_all_plugins
    plugins = Roma::Tools::Mkconfig::Base.new['plugin']['choice']
    mkconfig('1', plugins.size.to_s, '1', '', '')
    assert_match(/^  config.plugins = #{Regexp.escape(plugins[0..-2].to_s)}$/, config)
  end

  # Only what is chosen from the menu is set.
  def test_with_menu
    plugins = Roma::Tools::Mkconfig::Base.new['plugin']['choice']
    out = mkconfig('2', plugins.size.to_s, '4', mode: :with_menu)
    assert_match(/Please select by number\./, out)
    assert_match(/^  config.plugins = #{Regexp.escape(plugins[0..-2].to_s)}$/, config)
    assert_match(/^  config.storage.engine = :hash$/, config)
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
    assert_match(/:hash/, config)
  end
end
