require 'roma/tools/error'

module Roma
  module Tools
    # The storage files that romad keeps for a node: a directory for each
    # hash, which has the divided files 0.dbm, 1.dbm, ...
    module StorageFiles
      # The storages by the extension of their files: the file to require,
      # the class and the gem.
      STORAGES = {
        'dbm' => ['roma/storage/dbm', :DbmStorage, 'roma-storage-dbm'],
        'sql3' => ['roma/storage/sqlite3', :SQLite3Storage, 'roma-storage-sqlite3'],
        'grn' => ['roma/storage/groonga', :GroongaStorage, 'roma-storage-groonga']
      }.freeze

      # Yields the name and the directory of each hash under +path+. Raises
      # Error if there is none.
      def self.each_hash(path)
        dirs = Dir.glob(File.join(path, '*')).select { |dir| File.directory?(dir) }.sort
        raise Error, "#{path} has no directories of storage files." if dirs.empty?
        dirs.each { |dir| yield File.basename(dir), dir }
      end

      # Opens the files in +dir+ for +vnodes+. The storage is found by the
      # files unless +storage_class+ is given, and the files are counted
      # unless +divnum+ is given. Raises Error if they can't be opened.
      def self.open(dir, vnodes, divnum: nil, storage_class: nil)
        unless storage_class
          file = Dir.glob(File.join(dir, '0.*')).first
          raise Error, "#{dir} has no storage files." unless file
          ext = File.extname(file).delete_prefix('.')
          storage_class = storage_class_of(ext, dir)
          # The files are 0.dbm, 1.dbm, ..., and maybe others such as
          # 0.cache.dbm and 0.sql3-journal.
          divnum ||= Dir.children(dir).count { |f| f.match?(/\A\d+\.#{ext}\z/) }
        end
        storage = storage_class.new
        storage.divnum = divnum
        storage.vn_list = vnodes
        storage.storage_path = dir
        storage.opendb
        storage
      end

      def self.storage_class_of(ext, dir)
        path, name, gem = STORAGES[ext]
        raise Error, "#{dir} has files of an unknown storage: #{ext}" unless path
        begin
          require path
        rescue LoadError
          raise Error, "The files in #{dir} need #{gem}. Install it by gem install #{gem}."
        end
        Roma::Storage.const_get(name)
      end
      private_class_method :storage_class_of
    end
  end
end
