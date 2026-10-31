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

    desc 'mkconfig', 'Make config.rb in the current directory by asking questions'
    option :with_menu, aliases: '-m', type: :boolean, default: false,
                       desc: 'Show the menu to choose what to set'
    def mkconfig
      require 'roma/config'
      require 'roma/tools/mkconfig'
      Roma::Tools::Mkconfig.new.run(options[:with_menu] ? :with_menu : :no_menu)
    end

    desc 'adm COMMAND...', 'Send a command to a node, and print the reply'
    option :host, default: 'localhost', desc: 'The host of the node'
    option :port, aliases: '-p', type: :numeric, default: 12000, desc: 'The port of the node'
    option :value, aliases: '-v', desc: 'The value of a command that stores one, instead of asking for it'
    option :yes, aliases: '-y', type: :boolean, default: false, desc: 'Stop nodes by balse or shutdown without asking'
    def adm(command, *args)
      require 'roma/tools/adm'
      puts Roma::Tools::Adm.new.run("#{options[:host]}_#{options[:port]}", [command, *args].join(' '),
                                    value: options[:value], yes: options[:yes])
    end

    desc 'chg_redundancy NUM NODE_ID',
         'Write the routing table of a node in YAML, with NUM nodes to hold each data'
    def chg_redundancy(num, node_id)
      require 'roma/tools/chg_redundancy'
      Roma::Tools::ChgRedundancy.new.change(node_id, Integer(num, exception: false) || 0)
    end

    desc 'multi_commander NODE_ID COMMAND...', 'Send a command to every node in the routing table of a node'
    def multi_commander(node_id, command, *args)
      require 'roma/tools/multi_commander'
      puts Roma::Tools::MultiCommander.new(node_id).send_cmd_all([command, *args].join(' '))
    end

    desc 'recoverlost NODE_ID STORAGE_PATH',
         'Push the data in the storage files under STORAGE_PATH back for the vnodes whose data was lost'
    option :since, aliases: '-s', banner: 'YYYYMMDDHHMMSS', desc: 'Also the vnodes lost since this time'
    option :all, aliases: '-a', type: :boolean, default: false, desc: 'Every vnode'
    option :keys, aliases: '-k', banner: 'FILE',
                  desc: 'Only the keys in FILE, one in each line, or in the standard input with -'
    option :alist, type: :boolean, default: false, desc: 'Push the data of the list plugin by alist_spushv'
    def recoverlost(node_id, storage_path)
      require 'roma/tools/recoverlost'
      given = %i(since all keys).select { |name| options[name] }
      raise Roma::Tools::Error, "--#{given.join(' and --')} can't be used together." if given.size > 1

      tool = Roma::Tools::RecoverLost.new(alist: options[:alist])
      if options[:keys]
        keys = options[:keys] == '-' ? $stdin.readlines : File.readlines(options[:keys])
        tool.recover_keys(node_id, storage_path, keys.map(&:chomp).reject(&:empty?))
      else
        tool.recover(node_id, storage_path, since: options[:since], all: options[:all])
      end
      puts 'Recover process has succeed.'
    end

    desc 'key_list STORAGE_PATH', 'Write the keys in the storage files under STORAGE_PATH'
    option :wait, aliases: '-w', type: :numeric, default: 0.001, banner: 'SEC', desc: 'Seconds to wait after each key'
    def key_list(storage_path)
      require 'roma/tools/key_list'
      Roma::Tools::KeyList.new(wait: options[:wait]).list(storage_path)
    end

    desc 'key_access STORAGE_PATH KEY', 'Tell if a key is in the storage files under STORAGE_PATH'
    option :value, aliases: '-v', type: :boolean, default: false, desc: 'Tell the data of the key'
    def key_access(storage_path, key)
      require 'roma/tools/key_access'
      Roma::Tools::KeyAccess.new.access(storage_path, key, value: options[:value])
    end

    desc 'mkrecent STORAGE_PATH1 STORAGE_PATH2 RECENT_PATH',
         'Merge the storage files of two nodes into RECENT_PATH, keeping the newer data of each key'
    option :hash, aliases: '-h', type: :numeric, default: 32, banner: 'BITS', desc: 'Digest bit count'
    option :divide, aliases: '-d', type: :numeric, default: 9, banner: 'BITS', desc: 'Dividing bit count'
    option :divnum, aliases: '-n', type: :numeric, default: 10, banner: 'NUM', desc: 'Number of the new divided files'
    def mkrecent(path1, path2, recent_path)
      require 'roma/tools/mkrecent'
      Roma::Tools::MkRecent.new.make(path1, path2, recent_path, hash_bits: options[:hash],
                                     divide_bits: options[:divide], divnum: options[:divnum])
      puts 'Make recent data process has succeed.'
    end

    desc 'roma_watcher CONFIG_FILE',
         'Mail if a node is down or the nodes are split, as the YAML config file says'
    def roma_watcher(config_file)
      require 'yaml'
      require 'roma/tools/roma_watcher'
      Roma::Tools::RomaWatcher.new(YAML.load_file(config_file)).watch
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
