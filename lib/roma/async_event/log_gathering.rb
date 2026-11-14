module Roma
  module AsyncEvent
    # The processes that gather the routing events and the logs of this node
    # for the GUI.
    module LogGathering
      private

      def asyncev_start_get_routing_event(args)
        @log.debug("#{__method__} #{args}")
        start_thread(__method__) do
          load_routing_events
        end
      end

      def load_routing_events
        @log.info("#{__method__}:start.")

        routing_path = Roma.config.routing.path
        # The storage files may be in a directory named like the routing logs.
        f_list = Dir.glob("#{routing_path}/#{@stats.my_node_id}*").select { |f| File.file?(f) }

        f_list.each do |fname|
          IO.foreach(fname) do |line|
            if line =~ /join|leave/
              @routing_table.event.shift if @routing_table.event.size >= @routing_table.event_limit_line
              @routing_table.event << line.chomp
            end
          end
        end

        @log.info("#{__method__} has done.")
      rescue StandardError => e
        @log.error("#{e}\n#{$ERROR_POSITION}")
      end

      def asyncev_start_get_logs(args)
        @log.debug("#{__method__} #{args}")
        start_thread(__method__) do
          load_logs(args)
        ensure
          @stats.gui_run_gather_logs = false
        end
      end

      def load_logs(args)
        @log.debug("#{__method__}:start.")

        log_path = Roma.config.log.path
        log_file = "#{log_path}/#{@stats.my_node_id}.log"

        target_logs = []
        File.open(log_file) do |f|
          start_point = find_point(f, args[0], 'start')
          end_point = find_point(f, args[1], 'end')

          ## read target logs
          f.seek(start_point, IO::SEEK_SET)
          target_logs = f.read(end_point - start_point)
          target_logs = target_logs.each_line.map(&:chomp)
          target_logs.delete('.')
        end

        @routing_table.logs = target_logs
        # set gathered date for expiration
        @routing_table.logs.unshift(Time.now)

        @log.debug("#{__method__} has done.")
      rescue StandardError => e
        @routing_table.logs = []
        @log.error("#{e}\n#{$ERROR_POSITION}")
      ensure
        @stats.gui_run_gather_logs = false
      end

      def find_point(f, target_time, type, latency_time = Time.now, current_pos = 0, new_pos = f.size / 2)
        # hilatency check
        ps = Time.now - latency_time
        if ps > 5
          @log.warn('gather_logs process was failed.')
          raise
        end

        # initialize read size
        read_size = 2048

        # first check
        unless target_time.class == Time
          # in case of not set end_date
          return f.size if target_time == 'current'

          target_time =~ /(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)/
          target_time = Time.mktime(Regexp.last_match[1], Regexp.last_match[2], Regexp.last_match[3],
                                    Regexp.last_match[4], Regexp.last_match[5], Regexp.last_match[6], 0o00000)

          # check outrange or not
          f.seek(0, IO::SEEK_SET)
          begining_log = f.read(read_size)
          # Regexp.last_match is the first time in the log.
          begining_log.index(/[IDEW],\s\[(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)\.(\d+)/)
          begining_time = Time.mktime(Regexp.last_match[1], Regexp.last_match[2], Regexp.last_match[3],
                                      Regexp.last_match[4], Regexp.last_match[5], Regexp.last_match[6],
                                      Regexp.last_match[7])

          f.seek(-read_size, IO::SEEK_END)
          end_log = f.read(read_size)
          # Regexp.last_match is the last time in the log.
          end_log.rindex(/[IDEW],\s\[(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)\.(\d+)/)
          end_time = Time.mktime(Regexp.last_match[1], Regexp.last_match[2], Regexp.last_match[3], Regexp.last_match[4],
                                 Regexp.last_match[5], Regexp.last_match[6], Regexp.last_match[7])

          case type
          when 'start'
            if target_time < begining_time
              return 0
            elsif target_time > end_time
              @log.error('irregular time was set.')
              raise
            end
          when 'end'
            if target_time > end_time
              return f.size
            elsif target_time < begining_time
              @log.error('irregular time was set.')
              raise
            end
          end
        end

        # read half sector size
        f.seek(new_pos, IO::SEEK_SET)
        sector_log = f.read(read_size)
        # grep date
        date_a = sector_log.scan(/[IDEW],\s\[(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)\.(\d+)/)

        time_a = []
        date_a.each do |time|
          time_a.push(Time.mktime(time[0], time[1], time[2], time[3], time[4], time[5], time[6]))
        end
        sector_time_first = time_a[0]
        sector_time_last = time_a[-1]

        if target_time.between?(sector_time_first, sector_time_last)
          time_a.each do |time|
            next unless target_time <= time

            time_string = time.strftime('%Y-%m-%dT%H:%M:%S')
            target_index = sector_log.index(/[IDEW],\s\[#{time_string}/)
            return new_pos + target_index
          end
        elsif sector_time_first > target_time
          target_pos = new_pos - ((new_pos - current_pos).abs / 2)
        elsif sector_time_first < target_time
          target_pos = new_pos + ((new_pos - current_pos).abs / 2)
        end

        find_point(f, target_time, type, latency_time, new_pos, target_pos)
      end
    end
  end
end
