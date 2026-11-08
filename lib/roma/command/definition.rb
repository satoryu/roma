module Roma
  module Command
    module Definition
      # Raised in a command, they are replied as CLIENT_ERROR and SERVER_ERROR.
      class ClientError < StandardError; end
      class ServerError < StandardError; end

      # The key of a request, where it is, and the value that came with it.
      CommandParams = Struct.new(:key, :hash_name, :digest, :vnode, :nodes, :value)
      # The data that the storage has for the key.
      StoredData = Struct.new(:vnode, :last, :clock, :flags, :expire_time, :value)
      # What the block of a command gets: the words of the request line, its
      # CommandParams and its StoredData, or nil if the key isn't stored.
      CommandContext = Struct.new(:argv, :params, :stored)

      def self.included(base)
        base.extend ClassMethods
      end

      module ClassMethods
        # Defines the command +cmd+, which runs the block here and on the
        # other nodes and replies the results of all, and r+cmd+, which the
        # other nodes run.
        def def_command_with_relay(cmd, &)
          raise "ev_#{cmd} already defined." if public_method_defined? :"ev_#{cmd}"

          define_method "ev_#{cmd}" do |s|
            replying_errors do
              res = { @stats.my_node_id => instance_exec(s, &) }
              res.merge! broadcast_cmd("r#{cmd} #{s[1..].join(' ')}\r\n")
              send_data("#{res}\r\n")
            end
          end

          define_method "ev_r#{cmd}" do |s|
            replying_errors { send_data("#{instance_exec(s, &)}\r\n") }
          end
        end

        # The commands below take a key as the first argument. On a node that
        # isn't the primary of the key, they forward the request to it, and
        # +forward+ tells how many lines its reply has: :one_line or
        # :multi_line. Any other value runs the command here.
        #
        # The block gets a CommandContext and replies by itself.

        # Defines a command that reads the key, and counts a read.
        def def_read_command_with_key(cmd, forward = :one_line, &)
          def_key_command(cmd, forward, nil, :read, &)
        end

        # Defines a command that writes the key. The block returns
        # [flags, expire time, value, :write or :delete, message], or
        # anything else to store nothing. The value is stored and
        # replicated, and the message is replied, or NOT_<message> if it
        # couldn't be stored.
        def def_write_command_with_key(cmd, forward = :one_line, &)
          def_key_command(cmd, forward, nil, :write, &)
        end

        def def_command_with_key(cmd, forward = :one_line, &)
          def_key_command(cmd, forward, nil, nil, &)
        end

        # The commands below also read a value after the request line, whose
        # length is the argument at +idx_of_val_len+.

        def def_write_command_with_key_value(cmd, idx_of_val_len, forward = :one_line, &)
          def_key_command(cmd, forward, idx_of_val_len, :write, &)
        end

        def def_read_command_with_key_value(cmd, idx_of_val_len, forward = :one_line, &)
          def_key_command(cmd, forward, idx_of_val_len, :read, &)
        end

        def def_command_with_key_value(cmd, idx_of_val_len, forward = :one_line, &)
          def_key_command(cmd, forward, idx_of_val_len, nil, &)
        end

        private

        # +access+ is :read, :write or nil.
        def def_key_command(cmd, forward, idx_of_val_len, access, &)
          define_method "ev_#{cmd}" do |s|
            return send_data("CLIENT_ERROR does not find key\r\n") if s.length < 2

            replying_errors do
              params = command_params(s, idx_of_val_len)
              if params.nodes[0] != @my_node_id
                case forward
                when :one_line then return forward_and_one_line_receive(params.nodes[0], s, params.value)
                when :multi_line then return forward_and_multi_line_receive(params.nodes[0], s, params.value)
                end
              end
              unless @storages[params.hash_name]
                return send_data("SERVER_ERROR #{params.hash_name} does not exists.\r\n")
              end

              ctx = CommandContext.new(s, params, stored_data(params))
              case access
              when :read
                instance_exec(ctx, &)
                @stats.read_count += 1
              when :write
                push_to_write_behind(:"#{cmd}__prev", params.hash_name, params.key, ctx.stored.value) if ctx.stored
                store_result(cmd, params, instance_exec(ctx, &))
              else
                instance_exec(ctx, &)
              end
            end
          end
        end
      end

      private

      # Runs the block, and replies a ClientError or a ServerError that it
      # raises. A return in the block of a command raises LocalJumpError.
      def replying_errors
        yield
      rescue ClientError => e
        send_data("CLIENT_ERROR #{e.message}\r\n")
      rescue ServerError => e
        send_data("SERVER_ERROR #{e.message}\r\n")
      rescue LocalJumpError => e
        @log.warn("#{e} #{$@}")
        e.exit_value
      end

      # The CommandParams of the request line +s+. It reads the value if
      # +idx_of_val_len+ tells where its length is.
      def command_params(s, idx_of_val_len)
        params = CommandParams.new
        params.key, params.hash_name = s[1].split("\e")
        params.hash_name ||= @default_hash_name
        params.digest = @routing_table.digest(params.key)
        params.vnode = @routing_table.vnode_id(params.digest)
        params.nodes = @routing_table.search_nodes_for_write(params.vnode)
        params.value = read_value(s[idx_of_val_len].to_i) if idx_of_val_len
        params
      end

      # The StoredData of the key of +params+, or nil if it isn't stored or
      # has expired.
      def stored_data(params)
        vnode, last, clock, expire_time, value =
          @storages[params.hash_name].raw(params.vnode, params.key, params.digest)
        return nil if vnode.nil? || Time.now.to_i > expire_time

        StoredData.new(vnode, last, clock, nil, expire_time, value)
      end

      # Stores what the block of the write command +cmd+ returned, and
      # replies. See def_write_command_with_key.
      def store_result(cmd, params, result)
        return unless result.instance_of? Array

        _flags, expire_time, value, count, msg = result
        ret = @storages[params.hash_name].set(params.vnode, params.key, params.digest, expire_time, value)
        case count
        when :write then @stats.write_count += 1
        when :delete then @stats.delete_count += 1
        end
        return send_data("NOT_#{msg}\r\n") unless ret

        _vnode, _last, clock, _expire_time, stored_value = ret
        push_to_write_behind(cmd.to_sym, params.hash_name, params.key, stored_value)
        redundant(params.nodes[1..], params.hash_name, params.key, params.digest, clock, expire_time, stored_value)
        send_data("#{msg}\r\n")
      end
    end
  end
end
