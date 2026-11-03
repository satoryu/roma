require 'roma/cli/common'
require 'roma/tools/log_merger'

module Roma
  module Subcommands
    # roma log: work with the log files of romad.
    class Log < Thor
      extend Common
      check_unknown_options!

      desc 'merge LOG_FILE...', 'Merge the log files of romad in time order'
      option :output, aliases: '-o', banner: 'FILE', desc: 'Write into FILE instead of the standard output'
      option :level, aliases: '-l', enum: Roma::Tools::LogMerger::LEVEL_LETTERS.keys, default: 'TRACE',
                     desc: 'The lowest level to write'
      option :start, aliases: '-s', banner: 'YYYYMMDDHHMMSS', desc: 'Write from this time'
      option :end, aliases: '-e', banner: 'YYYYMMDDHHMMSS', desc: 'Write up to this time'
      def merge(log_file, *log_files)
        out = options[:output] ? File.open(options[:output], 'w') : $stdout
        Roma::Tools::LogMerger.new(out: out).merge([log_file, *log_files], level: options[:level],
                                                   start_date: options[:start], end_date: options[:end])
      ensure
        out.close if options[:output] && out
      end
    end
  end
end
