require 'roma/command_plugin'
require 'zlib'
require 'roma/async_event'

module Roma
  module CommandPlugin
    module Storage
      include ::Roma::CommandPlugin

      # "set" means "store this data".
      # <command name> <key> <flags> <exptime> <bytes> [noreply]\r\n
      # <data block>\r\n
      def ev_set(s) = set(:set, s)
      def ev_fset(s) = fset(:set, s)

      # get <key>*\r\n
      def ev_get(s)
        if s.length < 2
          @log.error("get:wrong number of arguments(#{s})")
          return send_data("CLIENT_ERROR Wrong number of arguments.\r\n")
        end

        return ev_gets(s) if s.length > 2

        key, hash_name = s[1].split("\e")
        hash_name ||= @default_hash_name
        d = @routing_table.digest(key)
        vnode = @routing_table.vnode_id(d)
        nodes = @routing_table.search_nodes(vnode)

        unless nodes.include?(@my_node_id)
          @log.warn("forward get #{s[1]}")
          res = forward_get(nodes[0], s[1], d)
          send_data(res || "SERVER_ERROR Message forward failed.\r\n")
          return
        end

        unless @storages.key?(hash_name)
          send_data("SERVER_ERROR #{hash_name} does not exists.\r\n")
          return
        end
        data = @storages[hash_name].get(vnode, key, 0)
        @stats.read_count += 1
        send_data("VALUE #{s[1]} 0 #{data.length}\r\n#{data}\r\n") if data
        send_data("END\r\n")
      end

      # fget <key>
      def ev_fget(s)
        key, hash_name = s[1].split("\e")
        hash_name ||= @default_hash_name
        d = @routing_table.digest(key)
        vnode = @routing_table.vnode_id(d)
        nodes = @routing_table.search_nodes(vnode)

        unless nodes.include?(@my_node_id)
          @log.error("fget failed key=#{s[1]} vnode=#{vnode}")
          return send_data("SERVER_ERROR Routing table is inconsistent.\r\n")
        end

        unless @storages.key?(hash_name)
          send_data("SERVER_ERROR #{hash_name} does not exists.\r\n")
          return
        end
        data = @storages[hash_name].get(vnode, key, 0)
        @stats.read_count += 1
        send_data("VALUE #{s[1]} 0 #{data.length}\r\n#{data}\r\n") if data
        send_data("END\r\n")
      end

      # gets <key>*\r\n
      def ev_gets(s)
        nk = {} # {node-id1=>[key1,key2,..],node-id2=>[key3,key4,..]}
        kvn = {} # {key1=>vn1, key2=>vn2, ... }
        s[1..-1].each do |kh|
          key, = kh.split("\e") # split a hash-name
          d = @routing_table.digest(key)
          kvn[key] = vnode = @routing_table.vnode_id(d)
          nodes = @routing_table.search_nodes(vnode)
          unless nodes.empty? # check the node existence
            nk[nodes[0]] = [] unless nk.key?(nodes[0])
            nk[nodes[0]] << kh
          end
        end

        res = {} # result data {key1=>val1,key2=>val2,...}
        if nk.key?(@my_node_id)
          nk[@my_node_id].each do |kh|
            key, hash_name = kh.split("\e")
            hash_name ||= @default_hash_name
            next unless @storages.key?(hash_name)

            _vn, _t, clock, expire_time, val = @storages[hash_name].raw(kvn[key], key, 0)
            @stats.read_count += 1
            res[key] = [clock, val] if val && Time.now.to_i <= expire_time
          end
          nk.delete(@my_node_id)
        end

        nk.each_pair do |node_id, keys|
          res.merge!(forward_gets(node_id, keys))
        end

        res.each_pair do |key, cv|
          clock, val = cv
          send_data("VALUE #{key} 0 #{val.length} #{clock}\r\n#{val}\r\n")
        end
        send_data("END\r\n")
      end

      # delete <key> [<time>] [noreply]\r\n
      def ev_delete(s)
        if s.length < 2
          @log.error("delete:wrong number of arguments(#{s})")
          return send_data("CLIENT_ERROR Wrong number of arguments.\r\n")
        end

        key, hash_name = s[1].split("\e")
        hash_name ||= @default_hash_name
        d = @routing_table.digest(key)
        vnode = @routing_table.vnode_id(d)
        nodes = @routing_table.search_nodes_for_write(vnode)

        if nodes[0] != @my_node_id
          cmd = "fdelete #{key}\e#{hash_name}"
          s[2..-1].each { |c| cmd << " #{c}" }
          cmd << "\r\n"
          @log.warn("forward delete #{s[1]}")
          res = send_cmd(nodes[0], cmd)
          return send_data("SERVER_ERROR Message forward failed.\r\n") if res.nil? || res.start_with?('ERROR')

          return send_data("#{res}\r\n")
        end

        unless @storages.key?(hash_name)
          send_data("SERVER_ERROR #{hash_name} does not exists.\r\n")
          return
        end

        if @stats.wb_command_map.key?(:delete__prev)
          data = @storages[hash_name].get(vnode, key, d)
          Roma::WriteBehind::Process.push(hash_name, @stats.wb_command_map[:delete__prev], key, data) if data
        end

        res = @storages[hash_name].delete(vnode, key, d)
        @stats.delete_count += 1

        return send_data("NOT_DELETED\r\n") unless res
        return send_data("NOT_FOUND\r\n") if res == :deletemark

        if @stats.wb_command_map.key?(:delete)
          Roma::WriteBehind::Process.push(hash_name, @stats.wb_command_map[:delete], key, res[4])
        end

        nodes[1..-1].each do |node_id|
          res2 = send_cmd(node_id, "rdelete #{key}\e#{hash_name} #{res[2]}\r\n")
          unless res2
            Roma::AsyncEvent.queue.push(Roma::AsyncMessage.new('rdelete', [node_id, hash_name, s[1], res[2]]))
            @log.warn("rdelete failed:#{s[1]}\e#{hash_name} #{d} #{res[2]} -> #{node_id}")
          end
        end
        return send_data("NOT_FOUND\r\n") unless res[4]

        if $roma.cluster_replication_writer.run_replication
          fnc = 'delete'
          Roma::WriteBehind::Process.push(nil, "#{fnc} #{s[1]}\r\n", s[1], nil)
        end

        send_data("DELETED\r\n")
      end

      # fdelete <key> [<time>] [noreply]\r\n
      def ev_fdelete(s)
        key, hash_name = s[1].split("\e")
        hash_name ||= @default_hash_name
        d = @routing_table.digest(key)
        vnode = @routing_table.vnode_id(d)
        nodes = @routing_table.search_nodes_for_write(vnode)
        if nodes.include?(@my_node_id) == false
          @log.error("fdelete failed delete key=#{s[1]} vnode=#{vnode}")
          return send_data("SERVER_ERROR Routing table is inconsistent.\r\n")
        end
        unless @storages.key?(hash_name)
          send_data("SERVER_ERROR #{hash_name} does not exists.\r\n")
          return
        end

        if @stats.wb_command_map.key?(:delete__prev)
          data = @storages[hash_name].get(vnode, key, d)
          Roma::WriteBehind::Process.push(hash_name, @stats.wb_command_map[:delete__prev], key, data) if data
        end

        res = @storages[hash_name].delete(vnode, key, d)
        @stats.delete_count += 1

        return send_data("NOT_DELETED\r\n") unless res
        return send_data("NOT_FOUND\r\n") if res == :deletemark

        if @stats.wb_command_map.key?(:delete)
          Roma::WriteBehind::Process.push(hash_name, @stats.wb_command_map[:delete], key, res[4])
        end

        nodes.delete(@my_node_id)
        nodes.each do |node_id|
          res2 = send_cmd(node_id, "rdelete #{key}\e#{hash_name} #{res[2]}\r\n")
          unless res2
            Roma::AsyncEvent.queue.push(Roma::AsyncMessage.new('rdelete', [node_id, hash_name, s[1], res[2]]))
            @log.warn("rdelete failed:#{s[1]}\e#{hash_name} #{d} #{res[2]} -> #{node_id}")
          end
        end
        return send_data("NOT_FOUND\r\n") unless res[4]

        if $roma.cluster_replication_writer.run_replication
          fnc = 'delete'
          Roma::WriteBehind::Process.push(nil, "#{fnc} #{s[1]}\r\n", s[1], nil)
        end

        send_data("DELETED\r\n")
      end

      # rdelete <key> <clock>
      def ev_rdelete(s)
        key, hash_name = s[1].split("\e")
        hash_name ||= @default_hash_name
        d = @routing_table.digest(key)
        vnode = @routing_table.vnode_id(d)
        unless @storages.key?(hash_name)
          send_data("SERVER_ERROR #{hash_name} does not exists.\r\n")
          return
        end
        if @storages[hash_name].rdelete(vnode, key, d, s[2].to_i)
          send_data("DELETED\r\n")
        else
          send_data("NOT_FOUND\r\n")
        end
      end

      # "add" means that "add a new data to a store"
      # <command name> <key> <flags> <exptime> <bytes> [noreply]\r\n
      # <data block>\r\n
      def ev_add(s) = set(:add, s)
      def ev_fadd(s) = fset(:add, s)

      # "replace" means that "replace the previous data with a new one"
      # <command name> <key> <flags> <exptime> <bytes> [noreply]\r\n
      # <data block>\r\n
      def ev_replace(s) = set(:replace, s)
      def ev_freplace(s) = fset(:replace, s)

      # "append" means that "append a new data to the previous one"
      # <command name> <key> <flags> <exptime> <bytes> [noreply]\r\n
      # <data block>\r\n
      def ev_append(s) = set(:append, s)
      def ev_fappend(s) = fset(:append, s)

      # "prepend" means that "prepend a new data to the previous one"
      # <command name> <key> <flags> <exptime> <bytes> [noreply]\r\n
      # <data block>\r\n
      def ev_prepend(s) = set(:prepend, s)
      def ev_fprepend(s) = fset(:prepend, s)

      # "cas" means that "store this data but only if no one else has updated since I last fetched it."
      # <command name> <key> <flags> <exptime> <bytes> <cas-id>[noreply]\r\n
      # <data block>\r\n
      def ev_cas(s)
        key, hash_name = s[1].split("\e")
        hash_name ||= @default_hash_name
        d = @routing_table.digest(key)
        v = read_value(s[4].to_i)
        vnode = @routing_table.vnode_id(d)
        nodes = @routing_table.search_nodes_for_write(vnode)
        if nodes[0] != @my_node_id
          @log.warn("forward cas key=#{key} vnode=#{vnode} to #{nodes[0]}")
          res = send_cmd(nodes[0], "fcas #{key}\e#{hash_name} #{d} #{s[3]} #{v.length} #{s[5]}\r\n#{v}\r\n")
          return send_data("SERVER_ERROR Message forward failed.\r\n") if res.nil? || res.start_with?('ERROR')

          return send_data("#{res}\r\n")
        end

        store_cas(hash_name, vnode, key, d, s[5].to_i, s[3].to_i, v, nodes[1..-1])
      end

      def ev_fcas(s)
        key, hash_name = s[1].split("\e")
        hash_name ||= @default_hash_name
        d = s[2].to_i
        d = @routing_table.digest(key) if d == 0
        v = read_value(s[4].to_i)
        vnode = @routing_table.vnode_id(d)
        nodes = @routing_table.search_nodes_for_write(vnode)
        if nodes.include?(@my_node_id) == false
          @log.error("fcas failed key = #{s[1]} vnode = #{vnode}")
          return send_data("SERVER_ERROR Routing table is inconsistent.\r\n")
        end

        nodes.delete(@my_node_id)
        store_cas(hash_name, vnode, key, d, s[5].to_i, s[3].to_i, v, nodes)
      end

      # incr <key> <value> [noreply]\r\n
      def ev_incr(s) = incr_decr(:incr, s)
      def ev_fincr(s) = fincr_fdecr(:incr, s)

      # decr <key> <value> [noreply]\r\n
      def ev_decr(s) = incr_decr(:decr, s)
      def ev_fdecr(s) = fincr_fdecr(:decr, s)

      # set_expt <key> <expire_time>
      def ev_set_expt(s)
        key, hash_name = s[1].split("\e")
        hash_name ||= @default_hash_name
        d = @routing_table.digest(key)
        vnode = @routing_table.vnode_id(d)
        nodes = @routing_table.search_nodes_for_write(vnode)
        if nodes[0] != @my_node_id
          @log.warn("forward set_expt key=#{key} vnode=#{vnode} to #{nodes[0]}")
          res = send_cmd(nodes[0], "fset_expt #{s[1]} #{s[2]}\r\n")
          return send_data("#{res}\r\n") if res

          return send_data("SERVER_ERROR Message forward failed.\r\n")
        end

        unless @storages.key?(hash_name)
          send_data("SERVER_ERROR #{hash_name} does not exists.\r\n")
          return
        end

        if @stats.wb_command_map.key?(:set_expt__prev)
          @log.debug(':set_export__prev')
          # [vnode, t, clock, expire_time, val]
          data = @storages[hash_name].raw(vnode, key, d)
          Roma::WriteBehind::Process.push(hash_name, @stats.wb_command_map[:set_expt__prev], key, data[3].to_s) if data
        end

        expire_time = chg_time_expt(s[2].to_i)
        ret = @storages[hash_name].set_expt(vnode, key, d, expire_time)

        return send_data("NOT_STORED\r\n") unless ret

        if @stats.wb_command_map.key?(:set_expt)
          @log.debug(':set_export')
          Roma::WriteBehind::Process.push(hash_name, @stats.wb_command_map[:set_expt], key, expire_time.to_s)
        end
        redundant(nodes[1..-1], hash_name, key, d, ret[2], ret[3], ret[4])
        if $roma.cluster_replication_writer.run_replication
          fnc = 'set_expt'
          Roma::WriteBehind::Process.push(nil, "#{fnc} #{s[1]} #{expire_time}\r\n", s[1], expire_time)
        end
        send_data("STORED\r\n")
      end

      # fset_expt <key> <expire_time>
      def ev_fset_expt(s)
        key, hash_name = s[1].split("\e")
        hash_name ||= @default_hash_name
        d = @routing_table.digest(key)
        vnode = @routing_table.vnode_id(d)
        nodes = @routing_table.search_nodes_for_write(vnode)
        if nodes.include?(@my_node_id) == false
          @log.error("fset_expt failed key = #{s[1]} vnode = #{vnode}")
          return send_data("SERVER_ERROR Routing table is inconsistent.\r\n")
        end

        unless @storages.key?(hash_name)
          send_data("SERVER_ERROR #{hash_name} does not exists.\r\n")
          return
        end

        if @stats.wb_command_map.key?(:set_expt__prev)
          # [vnode, t, clock, expire_time, val]
          data = @storages[hash_name].raw(vnode, key, d)
          Roma::WriteBehind::Process.push(hash_name, @stats.wb_command_map[:set_expt__prev], key, data[3].to_s) if data
        end

        expire_time = chg_time_expt(s[2].to_i)
        ret = @storages[hash_name].set_expt(vnode, key, d, expire_time)

        return send_data("NOT_STORED\r\n") unless ret

        if @stats.wb_command_map.key?(:set_expt)
          Roma::WriteBehind::Process.push(hash_name, @stats.wb_command_map[:set_expt], key, expire_time.to_s)
        end
        redundant(nodes[1..-1], hash_name, key, d, ret[2], ret[3], ret[4])
        if $roma.cluster_replication_writer.run_replication
          fnc = 'set_expt'
          Roma::WriteBehind::Process.push(nil, "#{fnc} #{s[1]} #{expire_time}\r\n", s[1], expire_time)
        end
        send_data("STORED\r\n")
      end

      # If you want to get expired time as UNIXTIME, set the 'unix' in last argument
      # Unless set this, expired time will be sent back as date format.
      # get_expt <key> [unix]
      def ev_get_expt(s)
        unless s.length.between?(2, 3)
          @log.error("get_expt: wrong number of arguments(#{s.length - 1} to 2-3)")
          return send_data("CLIENT_ERROR Wrong number of arguments.\r\n")
        end
        case s[2]
        when 'unix'
          is_unix = true
        when nil
          is_unix = false
        else
          @log.error('get_expt: wrong format of arguments.')
          return send_data("CLIENT_ERROR Wrong format of arguments.\r\n")
        end

        key, hash_name = s[1].split("\e")
        hash_name ||= @default_hash_name
        unless @storages.key?(hash_name)
          send_data("SERVER_ERROR #{hash_name} does not exists.\r\n")
          return
        end

        d = @routing_table.digest(key)
        vnode = @routing_table.vnode_id(d)

        nodes = @routing_table.search_nodes(vnode)
        unless nodes.include?(@my_node_id)
          @log.warn("forward get_expt #{s[1]} #{s[2]}")
          res = forward_get_expt(nodes[0], vnode, s[1], s[2])
          send_data(res || "SERVER_ERROR Message forward failed.\r\n")
          return
        end

        data = @storages[hash_name].db_get(vnode, key)
        if data
          expire_time = if is_unix
                          data.unpack('NNNNa*')[3]
                        else
                          Time.at(data.unpack('NNNNa*')[3])
                        end
          send_data("#{expire_time}\r\n")
        end
        send_data("END\r\n")
      end

      # set_size_of_zredundant <n>
      def ev_set_size_of_zredundant(s)
        return send_data("usage:set_size_of_zredundant <n>\r\n") if s.length != 2 || s[1].to_i == 0

        res = broadcast_cmd("rset_size_of_zredundant #{s[1]}\r\n")
        @stats.compression_threshold = s[1].to_i
        res[@stats.my_node_id] = 'STORED'
        send_data("#{res}\r\n")
      end

      # rset_size_of_zredundant <n>
      def ev_rset_size_of_zredundant(s)
        return send_data("usage:rset_size_of_zredundant <n>\r\n") if s.length != 2 || s[1].to_i == 0

        @stats.compression_threshold = s[1].to_i
        send_data("STORED\r\n")
      end

      private

      def forward_get(node_id, k, _d)
        con = checkout_connection(node_id)
        con.send("fget #{k}\r\n")
        res = con.gets
        if res.nil?
          @routing_table.proc_failed(node_id)
          @log.error("forward get failed:node_id=#{node_id} key=#{k}")
          return nil
        elsif res == "END\r\n"
          # value does not found
        elsif res.start_with?('ERROR')
          @routing_table.proc_succeed(node_id)
          con.close_connection
          return nil
        else
          s = res.split(/ /)
          res << con.read_bytes(s[3].to_i + 2)
          res << con.gets
        end
        checkin_connection(node_id, con)
        @routing_table.proc_succeed(node_id)
        res
      rescue StandardError => e
        @routing_table.proc_failed(node_id) if e.message != 'no connection'
        @log.error("#{e.inspect}/#{$@}")
        @log.error("forward get failed:node_id=#{node_id} key=#{k}")
        nil
      end

      def forward_gets(node_id, keys)
        con = checkout_connection(node_id)
        con.send("gets #{keys.join(' ')}\r\n")
        res = {}
        while (line = con.gets) != "END\r\n"
          s = line.chomp.split(/ /)
          res[s[1]] = [s[4], con.read_bytes(s[3].to_i)]
          con.read_bytes(2)
        end
        checkin_connection(node_id, con)
        @routing_table.proc_succeed(node_id)
        res
      rescue StandardError
        @routing_table.proc_failed(node_id)
        @log.error("forward gets failed:node_id=#{node_id} key=#{keys}")
        {}
      end

      def forward_get_expt(node_id, _vnode, key, is_unix = nil)
        con = checkout_connection(node_id)
        con.send("get_expt #{key} #{is_unix}\r\n")
        res = +''
        while (line = con.gets) != "END\r\n"
          raise 'connection closed' unless line

          res << line
        end
        res << line
        checkin_connection(node_id, con)
        @routing_table.proc_succeed(node_id)
        res
      rescue StandardError
        @routing_table.proc_failed(node_id)
        @log.error("forward get_expt failed:node_id=#{node_id} key=#{key}")
        nil
      end

      def store(fnc, hash_name, vnode, k, d, expire_time, v, nodes)
        expire_time = chg_time_expt(expire_time)
        unless @storages.key?(hash_name)
          send_data("SERVER_ERROR #{hash_name} does not exists.\r\n")
          return
        end

        if @stats.wb_command_map.key?(:"#{fnc}__prev")
          data = @storages[hash_name].get(vnode, k, d)
          Roma::WriteBehind::Process.push(hash_name, @stats.wb_command_map[:"#{fnc}__prev"], k, data) if data
        end

        ret = @storages[hash_name].send(fnc, vnode, k, d, expire_time, v)
        @stats.write_count += 1

        if ret
          if @stats.wb_command_map.key?(fnc)
            Roma::WriteBehind::Process.push(hash_name, @stats.wb_command_map[fnc], k, ret[4])
          end
          redundant(nodes, hash_name, k, d, ret[2], expire_time, ret[4])
          if $roma.cluster_replication_writer.run_replication
            k = "#{k}\e#{hash_name}" if hash_name != @default_hash_name
            Roma::WriteBehind::Process.push(nil, "#{fnc} #{k} 1 #{expire_time} #{v.length} \r\n#{v}\r\n", k, v)
          end
          send_data("STORED\r\n")
        else
          @log.error("#{fnc} NOT_STORED:#{hash_name} #{vnode} #{k} #{d} #{expire_time}")
          send_data("NOT_STORED\r\n")
        end
      end

      def store_cas(hash_name, vnode, k, d, clock, expire_time, v, nodes)
        expire_time = chg_time_expt(expire_time)
        unless @storages.key?(hash_name)
          send_data("SERVER_ERROR #{hash_name} does not exists.\r\n")
          return
        end

        if @stats.wb_command_map.key?(:cas__prev)
          data = @storages[hash_name].get(vnode, k, d)
          Roma::WriteBehind::Process.push(hash_name, @stats.wb_command_map[:cas__prev], k, data) if data
        end

        ret = @storages[hash_name].cas(vnode, k, d, clock, expire_time, v)
        @stats.write_count += 1

        case ret
        when nil
          @log.error("cas NOT_STORED:#{hash_name} #{vnode} #{k} #{d} #{expire_time} #{clock}")
          send_data("NOT_STORED\r\n")
        when :not_found
          send_data("NOT_FOUND\r\n")
        when :exists
          send_data("EXISTS\r\n")
        else
          if @stats.wb_command_map.key?(:cas)
            Roma::WriteBehind::Process.push(hash_name, @stats.wb_command_map[:cas], k, ret[4])
          end
          if $roma.cluster_replication_writer.run_replication
            rk = hash_name == @default_hash_name ? k : "#{k}\e#{hash_name}"
            fnc = 'set' # To restrain a defference between main and replica cluster due to clock
            Roma::WriteBehind::Process.push(nil, "#{fnc} #{rk} 0 #{expire_time} #{v.length} \r\n#{v}\r\n", rk, v)
          end
          redundant(nodes, hash_name, k, d, ret[2], expire_time, ret[4])
          send_data("STORED\r\n")
        end
      end

      def redundant(nodes, hash_name, k, d, clock, expire_time, v)
        if @stats.compression_threshold > 0 && @stats.compression_threshold < v.length
          return zredundant(nodes, hash_name, k, d, clock, expire_time, v)
        end

        nodes.each do |node_id|
          res = send_cmd(node_id, "rset #{k}\e#{hash_name} #{d} #{clock} #{expire_time} #{v.length}\r\n#{v}\r\n")
          next unless res.nil? || res.start_with?('ERROR')

          Roma::AsyncEvent.queue.push(Roma::AsyncMessage.new('redundant',
                                                             [node_id, hash_name, k, d, clock, expire_time, v]))
          @log.warn("redundant failed:#{k}\e#{hash_name} #{d} #{clock} #{expire_time} #{v.length} -> #{node_id}")
        end
      end

      def zredundant(nodes, hash_name, k, d, clock, expire_time, v)
        zv = Zlib::Deflate.deflate(v)

        nodes.each do |node_id|
          res = send_cmd(node_id, "rzset #{k}\e#{hash_name} #{d} #{clock} #{expire_time} #{zv.length}\r\n#{zv}\r\n")
          next unless res.nil? || res.start_with?('ERROR')

          Roma::AsyncEvent.queue.push(Roma::AsyncMessage.new('zredundant',
                                                             [node_id, hash_name, k, d, clock, expire_time, zv]))
          @log.warn("zredundant failed:#{k}\e#{hash_name} #{d} #{clock} #{expire_time} #{zv.length} -> #{node_id}")
        end
      end

      def set(fnc, s)
        if s.length != 5
          @log.error("set:wrong number of arguments(#{s})")
          return send_data("CLIENT_ERROR Wrong number of arguments.\r\n")
        end

        bytes = s[4].to_i
        if bytes < 0
          @log.error("set:wrong value size(#{s})")
          return send_data("CLIENT_ERROR Wrong value size.\r\n")
        end

        key, hash_name = s[1].split("\e")
        hash_name ||= @default_hash_name
        d = @routing_table.digest(key)
        v = read_value(bytes)
        vnode = @routing_table.vnode_id(d)
        nodes = @routing_table.search_nodes_for_write(vnode)
        if nodes[0] != @my_node_id
          @log.warn("forward #{fnc} key=#{key} vnode=#{vnode} to #{nodes[0]}")
          res = send_cmd(nodes[0], "f#{fnc} #{s[1]} #{d} #{s[3]} #{s[4]}\r\n#{v}\r\n")
          return send_data("SERVER_ERROR Message forward failed.\r\n") if res.nil? || res.start_with?('ERROR')

          return send_data("#{res}\r\n")
        end

        store(fnc, hash_name, vnode, key, d, s[3].to_i, v, nodes[1..-1])
      end

      def fset(fnc, s)
        key, hash_name = s[1].split("\e")
        hash_name ||= @default_hash_name
        d = s[2].to_i
        d = @routing_table.digest(key) if d == 0
        v = read_value(s[4].to_i)
        vnode = @routing_table.vnode_id(d)
        nodes = @routing_table.search_nodes_for_write(vnode)
        if nodes.include?(@my_node_id) == false
          @log.error("f#{fnc} failed key = #{s[1]} vnode = #{vnode}")
          return send_data("SERVER_ERROR Routing table is inconsistent.\r\n")
        end

        nodes.delete(@my_node_id)
        store(fnc, hash_name, vnode, key, d, s[3].to_i, v, nodes)
      end

      def store_incr_decr(fnc, hash_name, vnode, k, d, v, nodes)
        unless @storages.key?(hash_name)
          send_data("SERVER_ERROR #{hash_name} does not exists.\r\n")
          return
        end

        if @stats.wb_command_map.key?(:"#{fnc}__prev")
          data = @storages[hash_name].get(vnode, k, d)
          Roma::WriteBehind::Process.push(hash_name, @stats.wb_command_map[:"#{fnc}__prev"], k, data) if data
        end

        res = @storages[hash_name].send(fnc, vnode, k, d, v)
        @stats.write_count += 1

        if res
          if @stats.wb_command_map.key?(fnc)
            Roma::WriteBehind::Process.push(hash_name, @stats.wb_command_map[fnc], k, res[4])
          end
          if $roma.cluster_replication_writer.run_replication
            rk = hash_name == @default_hash_name ? k : "#{k}\e#{hash_name}"
            Roma::WriteBehind::Process.push(nil, "#{fnc} #{rk} #{v}\r\n", rk, v)
          end
          redundant(nodes, hash_name, k, d, res[2], res[3], res[4])
          send_data("#{res[4]}\r\n")
        else
          send_data("NOT_FOUND\r\n")
        end
      end

      def incr_decr(fnc, s)
        key, hash_name = s[1].split("\e")
        hash_name ||= @default_hash_name
        d = @routing_table.digest(key)
        v = s[2].to_i
        vnode = @routing_table.vnode_id(d)
        nodes = @routing_table.search_nodes_for_write(vnode)
        if nodes[0] != @my_node_id
          @log.debug("forward #{fnc} key=#{s[1]} vnode=#{vnode} to #{nodes[0]}")
          res = send_cmd(nodes[0], "f#{fnc} #{s[1]} #{d} #{s[2]}\r\n")
          return send_data("SERVER_ERROR Message forward failed.\r\n") if res.nil? || res.start_with?('ERROR')

          return send_data("#{res}\r\n")
        end

        store_incr_decr(fnc, hash_name, vnode, key, d, v, nodes[1..-1])
      end

      def fincr_fdecr(fnc, s)
        key, hash_name = s[1].split("\e")
        hash_name ||= @default_hash_name
        d = s[2].to_i
        d = @routing_table.digest(key) if d == 0
        v = s[3].to_i
        vnode = @routing_table.vnode_id(d)
        nodes = @routing_table.search_nodes_for_write(vnode)
        if nodes.include?(@my_node_id) == false
          @log.debug("f#{fnc} failed key = #{s[1]} vnode = #{vnode}")
          return send_data("SERVER_ERROR Routing table is inconsistent.\r\n")
        end

        nodes.delete(@my_node_id)
        store_incr_decr(fnc, hash_name, vnode, key, d, v, nodes)
      end
    end # module Storage
  end # module CommandPlugin
end # module Roma
