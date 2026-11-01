
module Roma
  module CommandPlugin

    module PluginCmdAliases
      include ::Roma::CommandPlugin

      # Please add your self if you want.

    end

    # Deprecated: the old name of PluginCmdAliases.
    PluginCommandAliases = PluginCmdAliases
    deprecate_constant :PluginCommandAliases
  end
end
