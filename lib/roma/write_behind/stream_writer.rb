require 'socket'
require 'timeout'
require 'roma/messaging/connection_pool'

module Roma
  module WriteBehind
    class StreamWriter
      attr_accessor :run_replication, :run_existing_data_replication
      attr_reader :replica_mklhash, :replica_nodelist, :replica_rttable

      # +pool+ gives the connections to the nodes of the replica cluster.
      def initialize(log, pool: Roma::Messaging::ConnectionPool.instance)
        @log = log
        @pool = pool
        @run_replication = false
        @run_existing_data_replication = false
        @replica_mklhash = nil
        @replica_nodelist = []
        @replica_rttable = nil
        @do_transmit = false
      end

      def stat
        ret = {}
        ret['write-behind.run_replication'] = @run_replication
        ret['write-behind.run_existing_data_replication'] = @run_existing_data_replication
        ret['write-behind.replica_mklhash'] = @replica_mklhash
        ret['write-behind.replica_nodelist'] = @replica_nodelist
        ret
      end

      # Starts the replication to the cluster of +node_id+, with its mklhash,
      # nodes and routing table. With +existing_data+, the data that this
      # cluster has is copied too.
      def activate(node_id, existing_data: false)
        update_mklhash(node_id)
        update_nodelist(node_id)
        update_rttable(node_id)
        @run_replication = true
        @run_existing_data_replication = true if existing_data
      end

      def deactivate
        @replica_mklhash = nil
        @replica_nodelist = []
        @replica_rttable = nil
        @run_replication = false
        @run_existing_data_replication = false
      end

      def change_mklhash?
        con = @pool.checkout(@replica_nodelist[0])
        con.write("mklhash 0\r\n")
        current_mklhash = con.gets.chomp
        @pool.checkin(@replica_nodelist[0], con)

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
          con = @pool.checkout(node_id)
          con.write("mklhash 0\r\n")
          @replica_mklhash = con.gets.chomp
          @pool.checkin(node_id, con)
          @log.debug("replica_mklhash has updated: [#{@replica_mklhash}]")
        end
      rescue StandardError => e
        @log.error("#{e}\n#{$@}")
      end

      def update_nodelist(node_id)
        Timeout.timeout(1) do
          con = @pool.checkout(node_id)
          con.write("nodelist\r\n")
          @replica_nodelist = con.gets.chomp.split("\s")
          @pool.checkin(node_id, con)
          @log.debug("replica_nodelist has updated: #{@replica_nodelist}")
        end
      rescue StandardError => e
        @log.error("#{e}\n#{$@}")
      end

      def update_rttable(node_id)
        Timeout.timeout(1) do
          con = @pool.checkout(node_id)
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
          @pool.checkin(node_id, con)
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

      # value is for error log
      def transmit(cmd, key, value)
        Timeout.timeout(5) do
          @do_transmit = true
          node_id = search_replica_primary_node(key)
          con = @pool.checkout(node_id)
          con.write(cmd)
          con.gets # for return connection
          @pool.checkin(node_id, con)
        end
      rescue StandardError => e
        @log.error("#{e}\n#{$@}")
        @log.error("replication error: key=#{key} value=#{value}\r\n")
      ensure
        @do_transmit = false
      end

      def close_all
        @replica_nodelist.each do |node_id|
          @pool.close_at(node_id)
        end
      end
    end
  end
end
