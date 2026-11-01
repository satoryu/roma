require 'roma/tools/storage_files'

module Roma
  module Tools
    # Looks for a key in the storage files of a node.
    class KeyAccess
      def initialize(out: $stdout)
        @out = out
      end

      # Tells if +key+ is under +storage_path+, and returns true if it is.
      # With +value+, the data of the key is told. An expired or deleted key
      # is not there. Raises Error if the files can't be opened.
      def access(storage_path, key, value: false)
        StorageFiles.each_hash(storage_path) do |hash_name, dir|
          @out.puts "hash : #{hash_name}"
          vnode, last, clock, expire_time, val = get(dir, key)
          next unless vnode && expire_time != 0 && Time.now.to_i <= expire_time

          if value
            @out.puts "vnode: #{vnode}", "last : #{Time.at(last)}", "clock: #{clock}", "expt : #{Time.at(expire_time)}",
                      "value: #{val}"
          else
            @out.puts 'exist'
          end
          return true
        end
        @out.puts 'not exist'
        false
      end

      private

      def open_storage(dir)
        StorageFiles.open(dir, [])
      end

      def get(dir, key)
        storage = open_storage(dir)
        storage.get_raw2(key)
      ensure
        storage.closedb if storage
      end
    end
  end
end
