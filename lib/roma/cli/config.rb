require 'roma/cli/common'

module Roma
  module Subcommands
    # roma config: make the config file of romad.
    class Config < Thor
      extend Common

      check_unknown_options!

      desc 'create', 'Make config.rb in the current directory by asking questions'
      option :with_menu, aliases: '-m', type: :boolean, default: false,
                         desc: 'Show the menu to choose what to set'
      def create
        require 'roma/tools/config_creator'
        Roma::Tools::ConfigCreator.new.run(options[:with_menu] ? :with_menu : :no_menu)
      end
    end
  end
end
