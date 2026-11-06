require 'roma/cli/common'
require 'roma/cli/route'
require 'roma/cli/config'
require 'roma/cli/node'
require 'roma/cli/cluster'
require 'roma/cli/storage'
require 'roma/cli/log'

module Roma
  # The roma command. Each subcommand calls a class in Roma::Tools, and most
  # of them are in groups, such as roma route create.
  class CLI < Thor
    extend Subcommands::Common

    # Roma::Server parses the options of server.
    check_unknown_options! except: [:server]
    stop_on_unknown_option! :server

    # Thor only takes --help before a command (roma --help benchmark), so
    # "roma benchmark --help" is turned into "roma help benchmark". A group
    # takes --help after its subcommands by itself, such as
    # roma route create --help.
    def self.start(given_args = ARGV, config = {})
      command = given_args.first
      if given_args.include?('--help') && all_commands.key?(command) && command != 'server' &&
         !subcommands.include?(command)
        given_args = ['help', command]
      end
      super
    end

    desc 'server ADDRESS [OPTIONS]', 'Run a ROMA node. See roma server --help'
    def server(*args)
      require 'roma/server'
      Roma::Server.run(args)
    end

    desc 'benchmark NODE_ID...', 'Send requests to the nodes, and write the queries per second every 10 seconds'
    option :get, aliases: '-g', type: :boolean, default: false, desc: 'Get key_0 ... in order'
    option :set, aliases: '-s', type: :boolean, default: false, desc: 'Set key_0 ... in order'
    option :random, aliases: '-r', type: :boolean, default: false,
                    desc: 'Send random set, get and delete requests (default without --get and --set)'
    option :key_count, aliases: '-n', type: :numeric, default: 10_000, desc: 'Number of keys'
    option :threads, aliases: '-t', type: :numeric, default: 1, desc: 'Number of threads'
    option :value_size, aliases: '-v', type: :numeric, banner: 'BYTES', desc: 'Set random values of this size'
    option :duration, aliases: '-D', type: :numeric, banner: 'SEC', desc: 'Stop the random requests after this time'
    def benchmark(node_id, *node_ids)
      require 'roma/tools/benchmark'
      modes = Roma::Tools::Benchmark::MODES.select { |mode| options[mode] }
      modes << :random if modes.empty?
      Roma::Tools::Benchmark.new([node_id, *node_ids]).run(modes, key_count: options[:key_count],
                                                                  threads: options[:threads],
                                                                  value_size: options[:value_size],
                                                                  duration: options[:duration])
    end

    desc 'route SUBCOMMAND', 'Make and change the routing tables'
    subcommand 'route', Subcommands::Route

    desc 'config SUBCOMMAND', 'Make the config file of roma server'
    subcommand 'config', Subcommands::Config

    desc 'node SUBCOMMAND', 'Send a command to a node'
    subcommand 'node', Subcommands::Node

    desc 'cluster SUBCOMMAND', 'Send a command to every node, or check the nodes'
    subcommand 'cluster', Subcommands::Cluster

    desc 'storage SUBCOMMAND', 'Read, merge and recover the data in the storage files'
    subcommand 'storage', Subcommands::Storage

    desc 'log SUBCOMMAND', 'Merge the log files of roma server'
    subcommand 'log', Subcommands::Log
  end
end
