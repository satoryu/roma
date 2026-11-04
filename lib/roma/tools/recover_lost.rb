require 'digest/sha1'
require 'roma/tools/admin_client'
require 'roma/tools/error'
require 'roma/tools/storage_files'

module Roma
  module Tools
    # Pushes the data in the storage files of a node back to the cluster,
    # for the vnodes whose data was lost.
    class RecoverLost
      # +out+ is where the progress goes. With +alist+, the data is pushed
      # by alist_spushv for the list plugin. +push_wait+ is the seconds to
      # wait after each data, and +random+ chooses the node for a vnode that
      # has none.
      def initialize(out: $stdout, client: AdminClient.new, alist: false, push_wait: 0.0001, random: Random)
        @out = out
        @client = client
        @pushv_cmd = alist ? 'alist_spushv' : 'spushv'
        @push_wait = push_wait
        @random = random
      end

      # Recovers the vnodes that have no node in the routing table of
      # +node_id+, and the ones lost since +since+ (YYYYMMDDHHMMSS) if it is
      # given. With +all+, every vnode. +storage_path+ has a directory of
      # storage files for each hash. Raises Error if it fails.
      def recover(node_id, storage_path, since: nil, all: false)
        raise Error, 'The time should be YYYYMMDDHHMMSS.' if since && since !~ /\A\d{14}\z/

        routing_data = @client.routing_data(node_id)
        if all
          vnodes = routing_data.routes.keys
        else
          vnodes = routing_data.get_lost_vnodes
          vnodes |= history_of_lost(node_id, since) if since
          @out.puts "#{vnodes.length} vnodes where data was lost."
          return if vnodes.empty?
        end
        each_storage(storage_path, vnodes) do |hash_name, storage|
          vnodes.each_with_index do |vnode, idx|
            recover_vnode(routing_data, hash_name, storage, vnode, "#{idx}/#{vnodes.length}")
          end
        end
      end

      # Recovers only the data of +keys+, to the nodes that have it now.
      def recover_keys(node_id, storage_path, keys)
        routing_data = @client.routing_data(node_id)
        each_storage(storage_path, routing_data.routes.keys) do |hash_name, storage|
          keys.each { |key| recover_key(routing_data, hash_name, storage, key) }
        end
      end

      private

      def history_of_lost(node_id, since)
        @client.connect(node_id) do |con|
          con.write("history_of_lost #{since}\r\n")
          vnodes = []
          while (line = con.gets) != "END\r\n"
            raise Error, "#{node_id} replied to history_of_lost: #{line.to_s.chomp}" unless line =~ /\A\d+\r\n\z/

            vnodes << line.to_i
          end
          vnodes
        end
      end

      def each_storage(path, vnodes)
        StorageFiles.each_hash(path) do |hash_name, dir|
          @out.puts "#{hash_name} #{dir}"
          storage = open_storage(dir, vnodes)
          begin
            yield hash_name, storage
          ensure
            storage.closedb
          end
        end
      end

      def open_storage(dir, vnodes)
        StorageFiles.open(dir, vnodes)
      end

      # A vnode without nodes is given to a node, which the others are told.
      def recover_vnode(routing_data, hash_name, storage, vnode, progress)
        node_ids = routing_data.routes[vnode]
        assign = node_ids.nil? || node_ids.empty?
        if assign
          node_ids = [routing_data.nodes.sample(random: @random)]
          @out.puts "#{progress} #{vnode} assign to #{node_ids.inspect}"
        else
          @out.puts "#{progress} #{vnode} was auto assigned at #{node_ids.inspect}"
        end
        node_ids.each do |node_id|
          res = push(node_id, hash_name, vnode) do |con|
            storage.each_vn_dump(vnode) do |data|
              write_data(con, clock_to_zero(data))
            end
          end
          raise Error, "Pushing vnode #{vnode} to #{node_id} failed: #{res}" unless res == 'STORED'
        end
        return unless assign

        cmd = "setroute #{vnode} #{routing_data.clocks[vnode]} #{node_ids[0]}"
        res = @client.request(node_ids[0], cmd)
        raise Error, "#{node_ids[0]} replied to #{cmd}: #{res}" unless res == 'STORED'

        (routing_data.nodes - node_ids).each do |node_id|
          @client.request(node_id, cmd)
        rescue Error => e
          @out.puts e.message
        end
      end

      def recover_key(routing_data, hash_name, storage, key)
        data = storage.get_raw2(key)
        return unless data

        @out.puts "hit => #{key}"
        vnode = (Digest::SHA1.hexdigest(key).hex % (2**routing_data.digest_bits)) & routing_data.search_mask
        _vn, last, _clk, expire_time, val = data
        Array(routing_data.routes[vnode]).each do |node_id|
          res = begin
            push(node_id, hash_name, vnode) { |con| write_data(con, pack(vnode, last, 0, expire_time, key, val)) }
          rescue Error => e
            e.message
          end
          @out.puts "#{node_id}=>#{res}"
        end
      end

      # Sends the data written in the block by the push command, and returns
      # the reply, STORED or an error.
      def push(node_id, hash_name, vnode)
        @client.connect(node_id) do |con|
          con.write("#{@pushv_cmd} #{hash_name} #{vnode}\r\n")
          res = con.gets
          next res.to_s.chomp unless res == "READY\r\n"

          yield con
          con.write("\0" * 20) # the end of the stream
          con.gets.to_s.chomp
        end
      end

      def write_data(con, data)
        con.write(data)
        sleep @push_wait
      end

      # The data is vnode, last, clock, expire_time, the key length, the key, the value
      # length and the value. The clock is the third.
      def clock_to_zero(data)
        data = data.b
        data[8, 4] = [0].pack('N')
        data
      end

      def pack(vnode, last, clock, expire_time, key, val)
        key = key.b
        if val
          val = val.b
          [vnode, last, clock, expire_time, key.bytesize, key, val.bytesize, val].pack('NNNNNa*Na*')
        else
          [vnode, last, clock, expire_time, key.bytesize, key, 0].pack('NNNNNa*N')
        end
      end
    end
  end
end
