require 'thread'

module Roma
  module WriteBehindProcess

    @@wb_queue = Queue.new

    def self.push(hname, cmd, key, val)
      @@wb_queue.push([hname, cmd, key, val])
    end

    def start_wb_process
      @wb_thread = Thread.new{
        wb_process_loop
      }
      @wb_thread[:name] = 'write_behind'
    rescue =>e
      @log.error("#{e}\n#{$@}")
    end

    def stop_wb_process
      until @@wb_queue.empty?
        sleep 0.01
      end
      @wb_thread.exit
      @wb_writer.close_all
      @cr_writer.close_all
    end

    def wb_rotate(hname)
      @wb_writer.rotate(hname)
    end

    def wb_get_path(hname)
      @wb_writer.wb_get_path(hname)
    end

    def wb_get_current_file_path(hname)
      @wb_writer.get_current_file_path(hname)
    end

    def wb_get_stat
      @wb_writer.get_stat.merge(@cr_writer.get_stat)
    end

    def wb_process_loop
      loop {
        while dat = @@wb_queue.pop
          # dat ====> [hname, cmd, key, value]
          @cr_writer.transmit(dat[1], dat[2], dat[3]) unless dat[0]
          @wb_writer.write(dat[0], dat[1], dat[2], dat[3])
        end
      }
    rescue =>e
      @log.error("#{e}\n#{$@}")
      retry
    end
    private :wb_process_loop

  end # module WriteBehindProcess
end # module Roma
