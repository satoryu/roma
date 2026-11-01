require 'test_helper'
require 'stringio'

# The old names of the plugins and of the errors of Definition still work,
# with a warning.
class DeprecatedNamesTest < Test::Unit::TestCase
  # Returns the value of the block and the deprecation warnings it printed.
  def capture_deprecation
    saved_stderr = $stderr
    saved = Warning[:deprecated]
    Warning[:deprecated] = true
    $stderr = StringIO.new
    [yield, $stderr.string]
  ensure
    $stderr = saved_stderr
    Warning[:deprecated] = saved
  end

  data('plugin_alist' => ['plugin_alist', :PluginAshiatoList, :PluginAlist],
       'plugin_cmd_aliases' => ['plugin_cmd_aliases', :PluginCommandAliases, :PluginCmdAliases],
       'plugin_debug' => ['plugin_debug', :PluginOperation, :PluginDebug],
       'plugin_mapcount' => ['plugin_mapcount', :PluginMapCount, :PluginMapcount])
  def test_plugin(data)
    file, old_name, name = data
    require "roma/plugin/#{file}"
    assert_include $LOADED_FEATURES.map { |f| f[%r{roma/command_plugin/\w+\.rb\z}] }, "roma/command_plugin/#{file}.rb"
    plugin, warning = capture_deprecation { Roma::CommandPlugin.const_get(old_name) }
    assert_same Roma::CommandPlugin.const_get(name), plugin
    assert_match(/#{old_name} is deprecated/, warning)
  end

  data('ClientErrorException' => [:ClientErrorException, :ClientError],
       'ServerErrorException' => [:ServerErrorException, :ServerError])
  def test_error(data)
    old_name, name = data
    require 'roma/command/definition'
    error, warning = capture_deprecation { Roma::Command::Definition.const_get(old_name) }
    assert_same Roma::Command::Definition.const_get(name), error
    assert_operator error, :<, StandardError
    assert_match(/#{old_name} is deprecated/, warning)
  end
end
