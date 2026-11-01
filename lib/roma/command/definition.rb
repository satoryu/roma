module Roma
  module Command
    module Definition

      # Raised in a command, they are replied as CLIENT_ERROR and SERVER_ERROR.
      class ClientError < StandardError; end
      class ServerError < StandardError; end

      # Deprecated: the old names of ClientError and ServerError.
      ClientErrorException = ClientError
      ServerErrorException = ServerError
      deprecate_constant :ClientErrorException, :ServerErrorException

      def self.included(base)
        # include ClassMethods module into an eigen-class of a +base+
        base.extend ClassMethods
      end

      module ClassMethods

        def def_command_with_relay(cmd, &block)
          # check a duplicated command definition in a same scope
          if public_method_defined? "ev_#{cmd}".to_sym
            raise "ev_#{cmd} already defined."
          end

          # define a command receiver
          define_method "ev_#{cmd}" do |s|
            begin
              res = {}
              res[@stats.my_node_id] = instance_exec(s, &block)
              # command relay
              res.merge! broadcast_cmd("r#{cmd} #{s[1..-1].join(' ')}\r\n")
              send_data("#{res}\r\n")
            rescue ClientError => e
              send_data("CLIENT_ERROR #{e.message}\r\n")
            rescue ServerError => e
              send_data("SERVER_ERROR #{e.message}\r\n")
            rescue LocalJumpError => e
              @log.warn("#{e} #{$@}")
              e.exit_value
            end
          end

          # define a relaid command receiver
          define_method "ev_r#{cmd}" do |s|
            begin
              send_data("#{instance_exec(s, &block)}\r\n")
            rescue ClientError => e
              send_data("CLIENT_ERROR #{e.message}\r\n")
            rescue ServerError => e
              send_data("SERVER_ERROR #{e.message}\r\n")
            rescue LocalJumpError => e
              @log.warn("#{e} #{$@}")
              e.exit_value
            end
          end
        end # def_command_with_relay

        CommandParams = Struct.new(:key, :hash_name, :digest, :vnode, :nodes, :value)
        StoredData = Struct.new(:vnode, :last, :clock, :flg, :expire_time, :value)
        CommandContext = Struct.new(:argv, :params, :stored)

        def def_read_command_with_key(cmd, forward = :one_line, &block)
          define_method "ev_#{cmd}" do |s|
            return send_data("CLIENT_ERROR does not find key\r\n") if s.length < 2
            begin
              params = CommandParams.new
              params.key, params.hash_name = s[1].split("\e")
              params.hash_name ||= @default_hash_name
              params.digest = Digest::SHA1.hexdigest(params.key).hex % @routing_table.hash_space_size
              params.vnode = @routing_table.get_vnode_id(params.digest)
              params.nodes = @routing_table.search_nodes_for_write(params.vnode)
              if params.nodes[0] != @my_node_id
                if forward == :one_line
                  return forward_and_one_line_receive(params.nodes[0], s)
                elsif  forward == :multi_line
                  return forward_and_multi_line_receive(params.nodes[0], s)
                end
              end
              stored = StoredData.new
              unless @storages[params.hash_name]
                return send_data("SERVER_ERROR #{params.hash_name} does not exists.\r\n")
              end

              stored.vnode, stored.last, stored.clock, stored.expire_time, stored.value =
                @storages[params.hash_name].get_raw(params.vnode, params.key, params.digest)
              stored = nil if stored.vnode == nil || Time.now.to_i > stored.expire_time
              ctx = CommandContext.new(s, params, stored)
              instance_exec(ctx, &block)
              @stats.read_count += 1
            rescue ClientError => e
              send_data("CLIENT_ERROR #{e.message}\r\n")
            rescue ServerError => e
              send_data("SERVER_ERROR #{e.message}\r\n")
            rescue LocalJumpError => e
              @log.warn("#{e} #{$@}")
              e.exit_value
            end
          end
        end # def_read_command_with_key

        def def_write_command_with_key(cmd, forward = :one_line, &block)
          define_method "ev_#{cmd}" do |s|
            return send_data("CLIENT_ERROR does not find key\r\n") if s.length < 2
            begin
              params = CommandParams.new
              params.key, params.hash_name = s[1].split("\e")
              params.hash_name ||= @default_hash_name
              params.digest = Digest::SHA1.hexdigest(params.key).hex % @routing_table.hash_space_size
              params.vnode = @routing_table.get_vnode_id(params.digest)
              params.nodes = @routing_table.search_nodes_for_write(params.vnode)
              if params.nodes[0] != @my_node_id
                if forward == :one_line
                  return forward_and_one_line_receive(params.nodes[0], s)
                elsif  forward == :multi_line
                  return forward_and_multi_line_receive(params.nodes[0], s)
                end
              end
              stored = StoredData.new
              unless @storages[params.hash_name]
                return send_data("SERVER_ERROR #{params.hash_name} does not exists.\r\n")
              end

              stored.vnode, stored.last, stored.clock, stored.expire_time, stored.value =
                @storages[params.hash_name].get_raw(params.vnode, params.key, params.digest)
              stored = nil if stored.vnode == nil || Time.now.to_i > stored.expire_time
              if stored && @stats.wb_command_map.key?("#{cmd}__prev".to_sym)
                Roma::WriteBehindProcess::push(params.hash_name,
                                               @stats.wb_command_map["#{cmd}__prev".to_sym],
                                               params.key, stored.value)
              end
              ctx = CommandContext.new(s, params, stored)

              ret = instance_exec(ctx, &block)
              if ret.instance_of? Array
                _flg, expire_time, value, count, msg = ret
                ret = @storages[ctx.params.hash_name].set(ctx.params.vnode, 
                                                          ctx.params.key,
                                                          ctx.params.digest,
                                                          expire_time,
                                                          value)
                if count == :write
                  @stats.write_count += 1
                elsif count == :delete
                  @stats.delete_count += 1
                end

                if ret
                  if @stats.wb_command_map.key?(cmd.to_sym)
                    Roma::WriteBehindProcess::push(ctx.params.hash_name,
                                                   @stats.wb_command_map[cmd.to_sym],
                                                   ctx.params.key, ret[4])
                  end
                  redundant(ctx.params.nodes[1..-1], ctx.params.hash_name,
                            ctx.params.key, ctx.params.digest, ret[2],
                            expire_time, ret[4])
                  send_data("#{msg}\r\n")
                else
                  send_data("NOT_#{msg}\r\n")
                end
              end
            rescue ClientError => e
              send_data("CLIENT_ERROR #{e.message}\r\n")
            rescue ServerError => e
              send_data("SERVER_ERROR #{e.message}\r\n")
            rescue LocalJumpError => e
              @log.warn("#{e} #{$@}")
              e.exit_value
            end
          end
        end # def_write_command_with_key

        def def_command_with_key(cmd, forward = :one_line, &block)
          define_method "ev_#{cmd}" do |s|
            return send_data("CLIENT_ERROR does not find key\r\n") if s.length < 2
            begin
              params = CommandParams.new
              params.key, params.hash_name = s[1].split("\e")
              params.hash_name ||= @default_hash_name
              params.digest = Digest::SHA1.hexdigest(params.key).hex % @routing_table.hash_space_size
              params.vnode = @routing_table.get_vnode_id(params.digest)
              params.nodes = @routing_table.search_nodes_for_write(params.vnode)
              if params.nodes[0] != @my_node_id
                if forward == :one_line
                  return forward_and_one_line_receive(params.nodes[0], s)
                elsif  forward == :multi_line
                  return forward_and_multi_line_receive(params.nodes[0], s)
                end
              end
              stored = StoredData.new
              unless @storages[params.hash_name]
                return send_data("SERVER_ERROR #{params.hash_name} does not exists.\r\n")
              end

              stored.vnode, stored.last, stored.clock, stored.expire_time, stored.value =
                @storages[params.hash_name].get_raw(params.vnode, params.key, params.digest)
              stored = nil if stored.vnode == nil || Time.now.to_i > stored.expire_time
              ctx = CommandContext.new(s, params, stored)
              instance_exec(ctx, &block)
            rescue ClientError => e
              send_data("CLIENT_ERROR #{e.message}\r\n")
            rescue ServerError => e
              send_data("SERVER_ERROR #{e.message}\r\n")
            rescue LocalJumpError => e
              @log.warn("#{e} #{$@}")
              e.exit_value
            end
          end
        end # def_command_with_key

        def def_write_command_with_key_value(cmd, idx_of_val_len, forward = :one_line, &block)
          define_method "ev_#{cmd}" do |s|
            return send_data("CLIENT_ERROR does not find key\r\n") if s.length < 2
            begin
              params = CommandParams.new
              params.key, params.hash_name = s[1].split("\e")
              params.hash_name ||= @default_hash_name
              params.digest = Digest::SHA1.hexdigest(params.key).hex % @routing_table.hash_space_size
              params.vnode = @routing_table.get_vnode_id(params.digest)
              params.nodes = @routing_table.search_nodes_for_write(params.vnode)
              params.value = read_bytes(s[idx_of_val_len].to_i)
              read_bytes(2)
              if params.nodes[0] != @my_node_id
                if forward == :one_line
                  return forward_and_one_line_receive(params.nodes[0], s, params.value)
                elsif  forward == :multi_line
                  return forward_and_multi_line_receive(params.nodes[0], s, params.value)
                end
              end
              stored = StoredData.new
              unless @storages[params.hash_name]
                return send_data("SERVER_ERROR #{params.hash_name} does not exists.\r\n")
              end

              stored.vnode, stored.last, stored.clock, stored.expire_time, stored.value =
                @storages[params.hash_name].get_raw(params.vnode, params.key, params.digest)
              stored = nil if stored.vnode == nil || Time.now.to_i > stored.expire_time

              if stored && @stats.wb_command_map.key?("#{cmd}__prev".to_sym)
                Roma::WriteBehindProcess::push(params.hash_name,
                                               @stats.wb_command_map["#{cmd}__prev".to_sym],
                                               params.key, stored.value)
              end

              ctx = CommandContext.new(s, params, stored)
              
              ret = instance_exec(ctx, &block)
              if ret.instance_of? Array
                _flg, expire_time, value, count, msg = ret
                ret = @storages[ctx.params.hash_name].set(ctx.params.vnode, 
                                                          ctx.params.key,
                                                          ctx.params.digest,
                                                          expire_time,
                                                          value)
                if count == :write
                  @stats.write_count += 1
                elsif count == :delete
                  @stats.delete_count += 1
                end

                if ret
                  if @stats.wb_command_map.key?(cmd.to_sym)
                    Roma::WriteBehindProcess::push(ctx.params.hash_name,
                                                   @stats.wb_command_map[cmd.to_sym],
                                                   ctx.params.key, ret[4])
                  end
                  redundant(ctx.params.nodes[1..-1], ctx.params.hash_name, 
                            ctx.params.key, ctx.params.digest, ret[2], 
                            expire_time, ret[4])
                  send_data("#{msg}\r\n")
                else
                  send_data("NOT_#{msg}\r\n")
                end
              end
            rescue ClientError => e
              send_data("CLIENT_ERROR #{e.message}\r\n")
            rescue ServerError => e
              send_data("SERVER_ERROR #{e.message}\r\n")
            rescue LocalJumpError => e
              @log.warn("#{e} #{$@}")
              e.exit_value
            end
          end
        end # def_write_command_with_key_value

        def def_read_command_with_key_value(cmd, idx_of_val_len, forward = :one_line, &block)
          define_method "ev_#{cmd}" do |s|
            return send_data("CLIENT_ERROR does not find key\r\n") if s.length < 2
            begin
              params = CommandParams.new
              params.key, params.hash_name = s[1].split("\e")
              params.hash_name ||= @default_hash_name
              params.digest = Digest::SHA1.hexdigest(params.key).hex % @routing_table.hash_space_size
              params.vnode = @routing_table.get_vnode_id(params.digest)
              params.nodes = @routing_table.search_nodes_for_write(params.vnode)
              params.value = read_bytes(s[idx_of_val_len].to_i)
              read_bytes(2)
              if params.nodes[0] != @my_node_id
                if forward == :one_line
                  return forward_and_one_line_receive(params.nodes[0], s, params.value)
                elsif  forward == :multi_line
                  return forward_and_multi_line_receive(params.nodes[0], s, params.value)
                end
              end
              stored = StoredData.new
              unless @storages[params.hash_name]
                return send_data("SERVER_ERROR #{params.hash_name} does not exists.\r\n")
              end

              stored.vnode, stored.last, stored.clock, stored.expire_time, stored.value =
                @storages[params.hash_name].get_raw(params.vnode, params.key, params.digest)
              stored = nil if stored.vnode == nil || Time.now.to_i > stored.expire_time
              ctx = CommandContext.new(s, params, stored)

              instance_exec(ctx, &block)
              @stats.read_count += 1
            rescue ClientError => e
              send_data("CLIENT_ERROR #{e.message}\r\n")
            rescue ServerError => e
              send_data("SERVER_ERROR #{e.message}\r\n")
            rescue LocalJumpError => e
              @log.warn("#{e} #{$@}")
              e.exit_value
            end
          end
        end # def_read_command_with_key_value

        def def_command_with_key_value(cmd, idx_of_val_len, forward = :one_line, &block)
          define_method "ev_#{cmd}" do |s|
            return send_data("CLIENT_ERROR does not find key\r\n") if s.length < 2
            begin
              params = CommandParams.new
              params.key, params.hash_name = s[1].split("\e")
              params.hash_name ||= @default_hash_name
              params.digest = Digest::SHA1.hexdigest(params.key).hex % @routing_table.hash_space_size
              params.vnode = @routing_table.get_vnode_id(params.digest)
              params.nodes = @routing_table.search_nodes_for_write(params.vnode)
              params.value = read_bytes(s[idx_of_val_len].to_i)
              read_bytes(2)
              if params.nodes[0] != @my_node_id
                if forward == :one_line
                  return forward_and_one_line_receive(params.nodes[0], s, params.value)
                elsif  forward == :multi_line
                  return forward_and_multi_line_receive(params.nodes[0], s, params.value)
                end
              end
              stored = StoredData.new
              unless @storages[params.hash_name]
                return send_data("SERVER_ERROR #{params.hash_name} does not exists.\r\n")
              end

              stored.vnode, stored.last, stored.clock, stored.expire_time, stored.value =
                @storages[params.hash_name].get_raw(params.vnode, params.key, params.digest)
              stored = nil if stored.vnode == nil || Time.now.to_i > stored.expire_time
              ctx = CommandContext.new(s, params, stored)
              instance_exec(ctx, &block)
            rescue ClientError => e
              send_data("CLIENT_ERROR #{e.message}\r\n")
            rescue ServerError => e
              send_data("SERVER_ERROR #{e.message}\r\n")
            rescue LocalJumpError => e
              @log.warn("#{e} #{$@}")
              e.exit_value
            end
          end
        end # def_command_with_key_value

      end # module ClassMethods

      #
      def forward_and_one_line_receive(nid, rs, data = nil)
        if rs.last == "forward"
          return send_data("SERVER_ERROR Routing table is inconsistent.\r\n")
        end

        @log.warn("forward #{rs} to #{nid}");

        buf = rs.join(' ') + " forward\r\n"
        buf << data + "\r\n" if data
        res = send_cmd(nid, buf)
        if res == nil || res.start_with?("ERROR")
          return send_data("SERVER_ERROR Message forward failed.\r\n")
        end
        send_data("#{res}\r\n")
      end

      # 
      def forward_and_multi_line_receive(nid, rs, data=nil)
        if rs.last == "forward"
          return send_data("SERVER_ERROR Routing table is inconsistent.\r\n")
        end

        @log.warn("forward #{rs} to #{nid}");

        buf = rs.join(' ') + " forward\r\n"
        buf << data + "\r\n" if data

        con = get_connection(nid)
        con.send(buf)

        buf = con.gets
        if buf == nil
          @routing_table.proc_failed(nid)
          @log.error("forward get failed:nid=#{nid} rs=#{rs} #{$@}")
          return send_data("SERVER_ERROR Message forward failed.\r\n")
        elsif buf.start_with?("ERROR")
          @routing_table.proc_succeed(nid)
          con.close_connection
          @log.error("forward get failed:nid=#{nid} rs=#{rs} #{$@}")
          return send_data("SERVER_ERROR Message forward failed.\r\n")
        elsif buf.start_with?("VALUE") == false
          return_connection(nid, con)
          @routing_table.proc_succeed(nid)
          return send_data(buf)
        end

        res = +''
        begin
          res << buf
          s = buf.split(/ /)
          if s[0] != 'VALUE'
            return_connection(nid, con)
            @routing_table.proc_succeed(nid)
            return send_data(buf)
          end
          res << con.read_bytes(s[3].to_i + 2)
        end while (buf = con.gets)!="END\r\n"

        res << "END\r\n"

        return_connection(nid, con)
        @routing_table.proc_succeed(nid)

        send_data(res)
      rescue => e
        @routing_table.proc_failed(nid) if e.message != "no connection"
        @log.error("forward get failed:nid=#{nid} rs=#{rs} #{e} #{$@}")
        send_data("SERVER_ERROR Message forward failed.\r\n")
      end

    end #  module Definition
  end # module Command
end # module Roma
