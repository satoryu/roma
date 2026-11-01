require 'roma/tools/error'
require 'roma/tools/storage_files'

module Roma
  module Tools
    # Merges the storage files of two nodes into new files, where the newer
    # data of each key is kept.
    class MkRecent
      def initialize(out: $stdout)
        @out = out
      end

      # Merges each hash under +path1+ with the one under +path2+, into
      # +recent_path+, which must not exist. The vnodes are made from
      # +hash_bits+ and +divide_bits+, as in the routing table, and the new
      # files are divided into +divnum+. Raises Error if it fails.
      def make(path1, path2, recent_path, hash_bits: 32, divide_bits: 9, divnum: 10)
        raise Error, "#{recent_path} exists." if File.exist?(recent_path)
        raise Error, "The hash bits should be divide bits or more." if hash_bits < divide_bits
        vnodes = Array.new(2**divide_bits) { |i| i << (hash_bits - divide_bits) }
        hashes = []
        StorageFiles.each_hash(path1) { |hname, dir| hashes << [hname, dir] }
        Dir.mkdir(recent_path)
        hashes.each do |hname, dir|
          merge(hname, [dir, File.join(path2, hname)], File.join(recent_path, hname), vnodes, divnum)
        end
      end

      private

      def open_storage(dir, vnodes, **opts)
        StorageFiles.open(dir, vnodes, **opts)
      end

      def merge(hname, dirs, recent_dir, vnodes, divnum)
        storages = []
        dirs.each do |dir|
          @out.puts "Open #{dir}"
          storages << open_storage(dir, vnodes)
        end
        raise Error, "#{dirs.join(' and ')} have different storages." if storages.map(&:class).uniq.size > 1

        @out.puts "Open #{recent_dir}"
        recent = open_storage(recent_dir, vnodes, divnum: divnum, storage_class: storages[0].class)
        storages << recent
        vnodes.each_with_index do |vn, i|
          @out.print "#{hname}:#{i}/#{vnodes.length}\r"
          storages[0, 2].each do |storage|
            dump = storage.dump(vn)
            recent.load(dump) if dump
          end
        end
        @out.puts
      ensure
        storages.each(&:closedb)
      end
    end
  end
end
