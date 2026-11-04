module Roma
  module WriteBehindProcess
    @@wb_queue = Queue.new

    def self.push(hash_name, cmd, key, val)
      @@wb_queue.push([hash_name, cmd, key, val])
    end

    def start_wb_process
      @wb_thread = Thread.new do
        wb_process_loop
      end
      @wb_thread[:name] = 'write_behind'
    rescue StandardError => e
      @log.error("#{e}\n#{$@}")
    end

    def stop_wb_process
      sleep 0.01 until @@wb_queue.empty?
      @wb_thread.exit
      @wb_writer.close_all
      @cluster_replication_writer.close_all
    end

    def wb_rotate(hash_name)
      @wb_writer.rotate(hash_name)
    end

    def wb_get_path(hash_name)
      @wb_writer.wb_get_path(hash_name)
    end

    def wb_get_current_file_path(hash_name)
      @wb_writer.get_current_file_path(hash_name)
    end

    def wb_get_stat
      @wb_writer.get_stat.merge(@cluster_replication_writer.get_stat)
    end

    def wb_process_loop
      loop do
        while dat = @@wb_queue.pop
          # dat ====> [hash_name, cmd, key, value]
          @cluster_replication_writer.transmit(dat[1], dat[2], dat[3]) unless dat[0]
          @wb_writer.write(dat[0], dat[1], dat[2], dat[3])
        end
      end
    rescue StandardError => e
      @log.error("#{e}\n#{$@}")
      retry
    end
    private :wb_process_loop
  end # module WriteBehindProcess
end # module Roma
