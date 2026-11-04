require 'socket'
require 'timeout'
require 'roma/messaging/con_pool'

module Roma
  module WriteBehind
    class StreamWriter
      attr_accessor :run_replication, :run_existing_data_replication, :replica_mklhash, :replica_nodelist,
                    :replica_rttable

      def initialize(log)
        @log = log
        @run_replication = false
        @run_existing_data_replication = false
        @replica_mklhash = nil
        @replica_nodelist = []
        @replica_rttable = nil
        @do_transmit = false
      end

      def get_stat
        ret = {}
        ret['write-behind.run_replication'] = @run_replication
        ret['write-behind.run_existing_data_replication'] = @run_existing_data_replication
        ret['write-behind.replica_mklhash'] = @replica_mklhash
        ret['write-behind.replica_nodelist'] = @replica_nodelist
        ret
      end

      def change_mklhash?
        con = Roma::Messaging::ConPool.instance.get_connection(@replica_nodelist[0])
        con.write("mklhash 0\r\n")
        current_mklhash = con.gets.chomp
        Roma::Messaging::ConPool.instance.return_connection(@replica_nodelist[0], con)

        return false if current_mklhash == @replica_mklhash

        true
      rescue StandardError
        @replica_nodelist.shift
        if @replica_nodelist.length == 0
          @run_replication = false
          @log.error('Replicate Cluster was down.')
        else
          retry
        end
      end

      def update_mklhash(node_id)
        Timeout.timeout(1) do
          con = Roma::Messaging::ConPool.instance.get_connection(node_id)
          con.write("mklhash 0\r\n")
          @replica_mklhash = con.gets.chomp
          Roma::Messaging::ConPool.instance.return_connection(node_id, con)
          @log.debug("replica_mklhash has updated: [#{@replica_mklhash}]")
        end
      rescue StandardError => e
        @log.error("#{e}\n#{$@}")
      end

      def update_nodelist(node_id)
        Timeout.timeout(1) do
          con = Roma::Messaging::ConPool.instance.get_connection(node_id)
          con.write("nodelist\r\n")
          @replica_nodelist = con.gets.chomp.split("\s")
          Roma::Messaging::ConPool.instance.return_connection(node_id, con)
          @log.debug("replica_nodelist has updated: #{@replica_nodelist}")
        end
      rescue StandardError => e
        @log.error("#{e}\n#{$@}")
      end

      def update_rttable(node_id)
        Timeout.timeout(1) do
          con = Roma::Messaging::ConPool.instance.get_connection(node_id)
          con.write "routingdump\r\n"
          routes_length = con.gets.to_i
          if routes_length <= 0
            con.close
            @log.error("#{__method__} process was failed.\r\n") if routes_length < 0
            return nil
          end

          routes = ''
          routes += con.read(routes_length - routes.length) while routes.length != routes_length
          con.read(2) # "\r\n"
          con.gets
          routing_data = Marshal.load(routes)
          Roma::Messaging::ConPool.instance.return_connection(node_id, con)
          @replica_rttable = routing_data
          @log.debug("replica_rttable has updated: [#{@replica_rttable}]")
        end
      rescue StandardError => e
        @log.error("#{e}\n#{$@}")
        nil
      end

      def search_replica_primary_node(key)
        d = Digest::SHA1.hexdigest(key).hex % (2**@replica_rttable.digest_bits)
        nodes = @replica_rttable.routes[d & @replica_rttable.search_mask]
        nodes[0] # for send primary node of replica cluster
      rescue StandardError => e
        @log.error("#{e}\n#{$@}")
        nil
      end

      def transmit(cmd, key, value) # value is for error log
        Timeout.timeout(5) do
          @do_transmit = true
          node_id = search_replica_primary_node(key)
          con = Roma::Messaging::ConPool.instance.get_connection(node_id)
          con.write(cmd)
          con.gets # for return connection
          Roma::Messaging::ConPool.instance.return_connection(node_id, con)
        end
      rescue StandardError => e
        @log.error("#{e}\n#{$@}")
        @log.error("replication error: key=#{key} value=#{value}\r\n")
      ensure
        @do_transmit = false
      end

      def close_all
        @replica_nodelist.each do |node_id|
          Roma::Messaging::ConPool.instance.close_at(node_id)
        end
      end
    end # class StreamWriter
  end # module WriteBehind
end # module Roma
