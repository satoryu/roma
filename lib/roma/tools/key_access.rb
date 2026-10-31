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
        StorageFiles.each_hash(storage_path) do |hname, dir|
          @out.puts "hash : #{hname}"
          vn, last, clk, expt, val = get(dir, key)
          next unless vn && expt != 0 && Time.now.to_i <= expt

          if value
            @out.puts "vnode: #{vn}", "last : #{Time.at(last)}", "clock: #{clk}", "expt : #{Time.at(expt)}",
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
