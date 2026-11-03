require 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'roma/command_plugin'

class CommandPluginTest < Test::Unit::TestCase
  def setup
    @dir = Dir.mktmpdir('roma_command_plugin')
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # Writes a plugin file that defines +name+ in Roma::CommandPlugin.
  def write_plugin(file, name)
    FileUtils.mkdir_p(File.dirname(File.join(@dir, file)))
    File.write(File.join(@dir, file), <<~RUBY)
      module Roma::CommandPlugin::#{name}
        include Roma::CommandPlugin
      end
    RUBY
  end

  # The *.rb files in the directory, by their names. Files in the
  # subdirectories are for the plugins to require.
  def test_files
    write_plugin('plugin_b.rb', :PluginB)
    write_plugin('plugin_a.rb', :PluginA)
    write_plugin('lib/helper.rb', :Helper)
    File.write(File.join(@dir, 'README.md'), '')
    assert_equal [File.join(@dir, 'plugin_a.rb'), File.join(@dir, 'plugin_b.rb')],
                 Roma::CommandPlugin.files(@dir)
  end

  def test_files_without_the_directory
    assert_equal [], Roma::CommandPlugin.files(File.join(@dir, 'none'))
  end

  # The plugins in the directory come after the bundled ones, so that they
  # are included later and their commands win.
  def test_require_all
    write_plugin('plugin_command_plugin_test.rb', :PluginCommandPluginTest)
    paths = Roma::CommandPlugin.require_all(@dir)
    assert_equal Roma::CommandPlugin::BUNDLED.map { |name| "roma/command_plugin/#{name}" } +
                 [File.join(@dir, 'plugin_command_plugin_test.rb')], paths
    assert_equal Roma::CommandPlugin::PluginCommandPluginTest, Roma::CommandPlugin.plugins.last
  end

  # eval of plugin_debug runs any Ruby code, so it is not bundled.
  def test_debug_is_not_bundled
    assert_not_include Roma::CommandPlugin::BUNDLED, 'plugin_debug'
  end
end
