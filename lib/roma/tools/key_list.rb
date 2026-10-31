require 'roma/tools/storage_files'

module Roma
  module Tools
    # Lists the keys in the storage files of a node.
    class KeyList
      # The keys go to +out+, and the progress to +err+. +wait+ is the
      # seconds to wait after each key, not to load the machine.
      def initialize(out: $stdout, err: $stderr, wait: 0.001)
        @out = out
        @err = err
        @wait = wait
      end

      # Writes the keys under +storage_path+, one in each line. Expired and
      # deleted ones are left out. Raises Error if the files can't be opened.
      def list(storage_path)
        StorageFiles.each_hash(storage_path) do |hname, dir|
          @err.puts "### #{hname} #{dir}"
          storage = open_storage(dir)
          begin
            write_keys(storage)
          ensure
            storage.closedb
          end
          @err.puts "\ndone"
        end
      end

      private

      def open_storage(dir)
        StorageFiles.open(dir, [])
      end

      def write_keys(storage)
        count = 0
        total = storage.true_length
        step = [total / 100, 1].max
        storage.divnum.times do |i|
          storage.each_hdb_dump(i) do |data|
            count += 1
            @err.print "#{count}/#{total}\r" if count % step == 0
            # vn, last, clock, expt, the key length, the key, ...
            @out.puts data[20, data.unpack1('@16N')]
            sleep @wait
          end
        end
      end
    end
  end
end
