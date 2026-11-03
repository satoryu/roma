require 'roma/cli/common'

module Roma
  module Subcommands
    # roma storage: work with the storage files of a node.
    class Storage < Thor
      extend Common
      check_unknown_options!

      desc 'recover-lost NODE_ID STORAGE_PATH',
           'Push the data in the storage files under STORAGE_PATH back for the vnodes whose data was lost'
      option :since, aliases: '-s', banner: 'YYYYMMDDHHMMSS', desc: 'Also the vnodes lost since this time'
      option :all, aliases: '-a', type: :boolean, default: false, desc: 'Every vnode'
      option :keys, aliases: '-k', banner: 'FILE',
                    desc: 'Only the keys in FILE, one in each line, or in the standard input with -'
      option :alist, type: :boolean, default: false, desc: 'Push the data of the list plugin by alist_spushv'
      def recover_lost(node_id, storage_path)
        require 'roma/tools/recover_lost'
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

      desc 'keys STORAGE_PATH', 'Write the keys in the storage files under STORAGE_PATH'
      option :wait, aliases: '-w', type: :numeric, default: 0.001, banner: 'SEC', desc: 'Seconds to wait after each key'
      def keys(storage_path)
        require 'roma/tools/key_list'
        Roma::Tools::KeyList.new(wait: options[:wait]).list(storage_path)
      end

      desc 'key STORAGE_PATH KEY', 'Tell if a key is in the storage files under STORAGE_PATH'
      option :value, aliases: '-v', type: :boolean, default: false, desc: 'Tell the data of the key'
      def key(storage_path, key)
        require 'roma/tools/key_access'
        Roma::Tools::KeyAccess.new.access(storage_path, key, value: options[:value])
      end

      desc 'merge STORAGE_PATH1 STORAGE_PATH2 RECENT_PATH',
           'Merge the storage files of two nodes into RECENT_PATH, keeping the newer data of each key'
      option :digest_bits, type: :numeric, default: 32, banner: 'BITS', desc: 'Digest bit count'
      option :divide_bits, aliases: '-d', type: :numeric, default: 9, banner: 'BITS', desc: 'Dividing bit count'
      option :division_count, aliases: '-n', type: :numeric, default: 10, banner: 'NUM',
                              desc: 'Number of the new divided files'
      def merge(path1, path2, recent_path)
        require 'roma/tools/storage_merger'
        Roma::Tools::StorageMerger.new.merge(path1, path2, recent_path, digest_bits: options[:digest_bits],
                                       divide_bits: options[:divide_bits],
                                       division_count: options[:division_count])
        puts 'Make recent data process has succeed.'
      end
    end
  end
end
