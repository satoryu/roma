module Roma
  module WriteBehind
    module Process
      @@queue = Queue.new

      def self.push(hash_name, cmd, key, val)
        @@queue.push([hash_name, cmd, key, val])
      end

      def start_write_behind_process
        @thread = Thread.new do
          process_loop
        end
        @thread[:name] = 'write_behind'
      rescue StandardError => e
        @log.error("#{e}\n#{$@}")
      end

      def stop_write_behind_process
        sleep 0.01 until @@queue.empty?
        @thread.exit
        @wb_writer.close_all
        @cluster_replication_writer.close_all
      end

      def write_behind_stat
        @wb_writer.stat.merge(@cluster_replication_writer.stat)
      end

      def process_loop
        loop do
          while dat = @@queue.pop
            # dat ====> [hash_name, cmd, key, value]
            @cluster_replication_writer.transmit(dat[1], dat[2], dat[3]) unless dat[0]
            @wb_writer.write(dat[0], dat[1], dat[2], dat[3])
          end
        end
      rescue StandardError => e
        @log.error("#{e}\n#{$@}")
        retry
      end
      private :process_loop
    end # module Process
  end # module WriteBehind
end # module Roma
