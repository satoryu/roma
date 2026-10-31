module Roma
  module Tools
    # Merges the log files of romad in time order. Each line is prefixed with
    # the name of its file.
    class LogMerger
      # The first letters of the lines of each level and above.
      LEVEL_LETTERS = {
        'TRACE' => 'TDIWEFU', 'DEBUG' => 'DIWEFU', 'INFO' => 'IWEFU', 'WARN' => 'WEFU',
        'ERROR' => 'EFU', 'FATAL' => 'FU', 'UNKNOWN' => 'U'
      }.freeze

      class ReadLog
        def initialize(fn)
          @f = open(fn)
          @buff = ''
          @prev = @f.gets
          @s_date = ''
        end

        def read_line
          begin
            if /^#\sLogfile\screated\son.+/ =~ @prev then
              @prev = @f.gets
            end

            @buff = @prev
            @prev = @f.gets

            while !(match_line(@prev)) && !(@prev.nil?) do
              @buff << @prev
              @prev = @f.gets
            end

            match_line(@buff)
          rescue
            unless @f.closed?
              @f.close
            end
          end
        end

        def get_line
          @buff
        end

        def get_date
          @s_date
        end

        def match_line(l)
          if /^[TDIWEFU],\s\[(\d{4})\-(\d{2})\-(\d{2})T(\d{2}):(\d{2}):(\d{2})\.(\d+)\s#\d+\].+/ =~ l then
            @s_date = $1 << $2 << $3 << $4 << $5 << $6 << $7
            true
          else
            @s_date = nil
            false
          end
        end
      end

      def initialize(out: $stdout)
        @out = out
      end

      # Writes the lines of +files+ at +level+ and above, from +start_date+
      # to +end_date+ (YYYYMMDDHHMMSS, or a prefix of it).
      def merge(files, level: 'TRACE', start_date: nil, end_date: nil)
        e_lv = LEVEL_LETTERS.fetch(level, LEVEL_LETTERS['TRACE'])
        start_date = start_date ? start_date.ljust(20, '0') : '0' * 20
        end_date = end_date ? end_date.ljust(20, '9') : '9' * 20

        r = files.map do |file|
          log = ReadLog.new(file)
          log.read_line
          log.read_line while !log.get_date.nil? && start_date > log.get_date
          log
        end

        loop do
          tmp = {}
          files.each_index do |i|
            tmp[i] = r[i].get_date unless r[i].get_line.nil?
          end
          break if tmp.empty?

          i, date = tmp.min_by { |_, d| d }
          if /^[#{e_lv}],.+/ =~ r[i].get_line && start_date <= date && end_date >= date
            @out.write("#{File.basename(files[i])},#{r[i].get_line}")
          end
          r[i].read_line
        end
      end
    end
  end
end
