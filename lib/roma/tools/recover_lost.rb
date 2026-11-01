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
        raise Error, "The time should be YYYYMMDDHHMMSS." if since && since !~ /\A\d{14}\z/
        rd = @client.routing_data(node_id)
        if all
          vnodes = rd.v_idx.keys
        else
          vnodes = rd.get_lost_vnodes
          vnodes |= history_of_lost(node_id, since) if since
          @out.puts "#{vnodes.length} vnodes where data was lost."
          return if vnodes.empty?
        end
        each_storage(storage_path, vnodes) do |hname, storage|
          vnodes.each_with_index { |vn, idx| recover_vnode(rd, hname, storage, vn, "#{idx}/#{vnodes.length}") }
        end
      end

      # Recovers only the data of +keys+, to the nodes that have it now.
      def recover_keys(node_id, storage_path, keys)
        rd = @client.routing_data(node_id)
        each_storage(storage_path, rd.v_idx.keys) do |hname, storage|
          keys.each { |key| recover_key(rd, hname, storage, key) }
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
        StorageFiles.each_hash(path) do |hname, dir|
          @out.puts "#{hname} #{dir}"
          storage = open_storage(dir, vnodes)
          begin
            yield hname, storage
          ensure
            storage.closedb
          end
        end
      end

      def open_storage(dir, vnodes)
        StorageFiles.open(dir, vnodes)
      end

      # A vnode without nodes is given to a node, which the others are told.
      def recover_vnode(rd, hname, storage, vn, progress)
        nids = rd.v_idx[vn]
        assign = nids.nil? || nids.empty?
        if assign
          nids = [rd.nodes.sample(random: @random)]
          @out.puts "#{progress} #{vn} assign to #{nids.inspect}"
        else
          @out.puts "#{progress} #{vn} was auto assigned at #{nids.inspect}"
        end
        nids.each do |nid|
          res = push(nid, hname, vn) { |con| storage.each_vn_dump(vn) { |data| write_data(con, clock_to_zero(data)) } }
          raise Error, "Pushing vnode #{vn} to #{nid} failed: #{res}" unless res == 'STORED'
        end
        return unless assign

        cmd = "setroute #{vn} #{rd.v_clk[vn]} #{nids[0]}"
        res = @client.request(nids[0], cmd)
        raise Error, "#{nids[0]} replied to #{cmd}: #{res}" unless res == 'STORED'
        (rd.nodes - nids).each do |nid|
          @client.request(nid, cmd)
        rescue Error => e
          @out.puts e.message
        end
      end

      def recover_key(rd, hname, storage, key)
        data = storage.get_raw2(key)
        return unless data
        @out.puts "hit => #{key}"
        vn = (Digest::SHA1.hexdigest(key).hex % (2**rd.dgst_bits)) & rd.search_mask
        _vn, last, _clk, expt, val = data
        Array(rd.v_idx[vn]).each do |nid|
          res = begin
                  push(nid, hname, vn) { |con| write_data(con, pack(vn, last, 0, expt, key, val)) }
                rescue Error => e
                  e.message
                end
          @out.puts "#{nid}=>#{res}"
        end
      end

      # Sends the data written in the block by the push command, and returns
      # the reply, STORED or an error.
      def push(nid, hname, vn)
        @client.connect(nid) do |con|
          con.write("#{@pushv_cmd} #{hname} #{vn}\r\n")
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

      # The data is vn, last, clock, expt, the key length, the key, the value
      # length and the value. The clock is the third.
      def clock_to_zero(data)
        data = data.b
        data[8, 4] = [0].pack('N')
        data
      end

      def pack(vn, last, clk, expt, key, val)
        key = key.b
        if val
          val = val.b
          [vn, last, clk, expt, key.bytesize, key, val.bytesize, val].pack('NNNNNa*Na*')
        else
          [vn, last, clk, expt, key.bytesize, key, 0].pack('NNNNNa*N')
        end
      end
    end
  end
end
