require 'thor'
require 'roma/tools/error'

module Roma
  # The groups of subcommands of the roma command, such as roma route. They
  # are out of Roma::CLI, since Thor lists the commands of every class in it
  # in roma help.
  module Subcommands
    # The behavior of the roma command and its groups.
    module Common
      # Thor's tree prints the class names, such as roma:subcommands:route.
      def self.extended(base)
        base.remove_command :tree
      end

      def exit_on_failure?
        true
      end

      # The name in the usage, which is otherwise the name of the running script.
      def basename
        'roma'
      end

      # A tool raises Roma::Tools::Error, or an error from the system such as
      # a missing file. Thor prints the message and exits with status 1.
      def dispatch(*)
        super
      rescue Roma::Tools::Error, SystemCallError => e
        raise Thor::Error, e.message
      end
    end
  end
end
