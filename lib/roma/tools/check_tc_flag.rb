require 'timeout'

module Roma
  module Tools
    # Shows the additional flags of the Tokyo Cabinet files in a storage
    # directory, such as "open" for a file that was not closed.
    class CheckTcFlag
      # +storage_path+ is the directory of the *.tc files, and +library_path+
      # the directory that has bin/tchmgr.
      def initialize(storage_path, library_path, out: $stdout)
        @storage_path = storage_path
        @library_path = library_path
        @out = out
      end

      # Returns a hash from each file to its flags.
      def check_flag
        status = {}
        Timeout.timeout(5){
          Dir.glob("#{@storage_path}/*.tc").each{|f|
            res = `#{@library_path}/bin/tchmgr inform #{f}`
            res =~ /additional flags:(.*)\n/
            status.store(f, $1)
          }
        }
        status
      end

      def print_flags
        check_flag.each do |f, flag|
          flag = "(no flag)" if flag.to_s.empty?
          @out.puts "#{f} : #{flag}"
        end
      end
    end
  end
end
