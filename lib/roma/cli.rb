require 'thor'
require 'roma/tools/error'
require 'roma/tools/log_merger'

module Roma
  # The roma command. Each subcommand calls a class in Roma::Tools.
  class CLI < Thor
    check_unknown_options!

    def self.exit_on_failure?
      true
    end

    # The name in the usage, which is otherwise the name of the running script.
    def self.basename
      'roma'
    end

    # Thor only takes --help before the command (roma --help mkroute), so
    # "roma mkroute --help" is turned into "roma help mkroute". -h is not,
    # since a subcommand may use it, such as mkroute --hash.
    def self.start(given_args = ARGV, config = {})
      if given_args.include?('--help') && all_commands.key?(given_args.first)
        given_args = ['help', given_args.first]
      end
      super(given_args, config)
    end

    # A tool raises Roma::Tools::Error, or an error from the system such as
    # a missing file. Thor prints the message and exits with status 1.
    def self.dispatch(*)
      super
    rescue Roma::Tools::Error, SystemCallError => e
      raise Thor::Error, e.message
    end

    desc 'mkroute NODE_ID...', 'Make the routing table and write it into NODE_ID.route for each node'
    option :hash, aliases: '-h', type: :numeric, default: 32, banner: 'BITS', desc: 'Digest bit count'
    option :divide, aliases: '-d', type: :numeric, default: 9, banner: 'BITS',
                    desc: 'Dividing bit count, which makes 2^BITS virtual nodes'
    option :redundant, aliases: '-r', type: :numeric, default: 2, banner: 'NUM',
                       desc: 'Number of nodes that hold each data'
    option :replication_in_host, type: :boolean, default: false, desc: 'Permit a host to hold the same data twice'
    def mkroute(node_id, *node_ids)
      require 'roma/tools/mkroute'
      Roma::Tools::Mkroute.new.create([node_id, *node_ids],
                                      hash_bits: options[:hash], divide_bits: options[:divide],
                                      redundancy: options[:redundant],
                                      replication_in_host: options[:replication_in_host])
    end

    desc 'ssroute NODE_ID', 'Put the routing logs of a node, but the last one, into NODE_ID.route'
    def ssroute(node_id)
      require 'roma/tools/ssroute'
      Roma::Tools::Ssroute.new.snapshot(node_id)
    end

    desc 'check_tc_flag', 'Show the additional flags of the Tokyo Cabinet files in a storage directory'
    option :storage, default: '.', banner: 'DIR', desc: 'Directory of the *.tc files'
    option :library, default: '.', banner: 'DIR', desc: 'Directory of Tokyo Cabinet, which has bin/tchmgr'
    def check_tc_flag
      require 'roma/tools/check_tc_flag'
      Roma::Tools::CheckTcFlag.new(options[:storage], options[:library]).print_flags
    end

    desc 'mkconfig', 'Make config.rb in the current directory by asking questions'
    option :with_menu, aliases: '-m', type: :boolean, default: false,
                       desc: 'Show the menu to choose what to set'
    def mkconfig
      require 'roma/config'
      require 'roma/tools/mkconfig'
      Roma::Tools::Mkconfig.new.run(options[:with_menu] ? :with_menu : :no_menu)
    end

    desc 'log_merger LOG_FILE...', 'Merge the log files of romad in time order'
    option :output, aliases: '-o', banner: 'FILE', desc: 'Write into FILE instead of the standard output'
    option :level, aliases: '-l', enum: Roma::Tools::LogMerger::LEVEL_LETTERS.keys, default: 'TRACE',
                   desc: 'The lowest level to write'
    option :start, aliases: '-s', banner: 'YYYYMMDDHHMMSS', desc: 'Write from this time'
    option :end, aliases: '-e', banner: 'YYYYMMDDHHMMSS', desc: 'Write up to this time'
    def log_merger(log_file, *log_files)
      out = options[:output] ? File.open(options[:output], 'w') : $stdout
      Roma::Tools::LogMerger.new(out: out).merge([log_file, *log_files], level: options[:level],
                                                 start_date: options[:start], end_date: options[:end])
    ensure
      out.close if options[:output] && out
    end
  end
end
