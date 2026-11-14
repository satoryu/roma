require 'roma/command_plugin'
require 'roma/safe_marshal'
require 'timeout'
require 'roma/messaging/connection_pool'
require 'json'
require 'roma/configuration'

module Roma
  module CommandPlugin
    module Alist
      include ::Roma::CommandPlugin

      # alist_at <key> <index> [forward]\r\n
      #
      # (
      # [VALUE <key> 0 <value length>\r\n
      # <value>\r\n]
      # END\r\n
      # |SERVER_ERROR <error message>\r\n)
      def ev_alist_at(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        return forward_and_multi_line_receive(nodes[0], s) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, d)
        @stats.read_count += 1
        return send_data("END\r\n") unless ddata

        values = SafeMarshal.load(ddata)[0]
        return send_data("END\r\n") if values.length <= s[2].to_i

        ret = values.at(s[2].to_i)
        ret ||= ''
        send_data("VALUE #{s[1]} 0 #{ret.length}\r\n#{ret}\r\nEND\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_clear <key> [forward]\r\n
      #
      # (CLEARED|NOT_CLEARED|SERVER_ERROR <error message>)\r\n
      def ev_alist_clear(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        return forward_and_one_line_receive(nodes[0], s) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, d)
        return send_data("NOT_FOUND\r\n") unless ddata

        stored = store_list(hash_name, k, d, vnode, nodes, [[], []])
        @stats.delete_count += 1
        return send_data("NOT_CLEARED\r\n") unless stored

        push_to_write_behind(:alist_clear, hash_name, k, ddata)
        send_data("CLEARED\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_delete <key> <bytes> [forward]\r\n
      # <data block>\r\n
      #
      # (DELETED|NOT_DELETED|NOT_FOUND|SERVER_ERROR <error message>)\r\n
      def ev_alist_delete(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        data = read_value(s[2].to_i)
        return forward_and_one_line_receive(nodes[0], s, data) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, d)
        return send_data("NOT_FOUND\r\n") unless ddata

        values, times = SafeMarshal.load(ddata)
        return send_data("NOT_DELETED\r\n") unless values.include?(data)

        while (idx = values.index(data))
          values.delete_at(idx)
          times.delete_at(idx)
        end

        stored = store_list(hash_name, k, d, vnode, nodes, [values, times])
        @stats.delete_count += 1
        return send_data("NOT_DELETED\r\n") unless stored

        push_to_write_behind(:alist_delete, hash_name, k, data)
        send_data("DELETED\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_delete_at <key> <index> [forward]\r\n
      #
      # (DELETED|NOT_DELETED|NOT_FOUND|SERVER_ERROR <error message>)\r\n
      def ev_alist_delete_at(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        return forward_and_one_line_receive(nodes[0], s) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, d)
        return send_data("NOT_FOUND\r\n") unless ddata

        values, times = SafeMarshal.load(ddata)
        dret = values.delete_at(s[2].to_i)
        return send_data("NOT_DELETED\r\n") unless dret

        times.delete_at(s[2].to_i)

        stored = store_list(hash_name, k, d, vnode, nodes, [values, times])
        @stats.delete_count += 1
        return send_data("NOT_DELETED\r\n") unless stored

        push_to_write_behind(:alist_delete_at, hash_name, k, dret)
        send_data("DELETED\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_empty? <key> [forward]\r\n
      #
      # (true|false|NOT_FOUND|SERVER_ERROR <error message>)\r\n
      def ev_alist_empty?(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        return forward_and_one_line_receive(nodes[0], s) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, d)
        @stats.read_count += 1

        return send_data("NOT_FOUND\r\n") unless ddata

        values, _times = SafeMarshal.load(ddata)
        ret = values.empty?

        send_data("#{ret}\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_first <key> [forward]\r\n
      #
      # (
      # [VALUE <key> 0 <value length>\r\n
      # <value>\r\n]
      # END\r\n
      # |SERVER_ERROR <error message>\r\n)
      def ev_alist_first(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        return forward_and_multi_line_receive(nodes[0], s) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, d)
        @stats.read_count += 1

        return send_data("END\r\n") unless ddata

        values = SafeMarshal.load(ddata)[0]
        return send_data("END\r\n") if values.length == 0

        ret = values.first
        send_data("VALUE #{s[1]} 0 #{ret.length}\r\n#{ret}\r\nEND\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_gets <key> [index|range] [forward]\r\n
      #
      # (
      # [VALUE <key> 0 <length of length string>\r\n
      # <length string>\r\n
      # (VALUE <key> 0 <value length>\r\n
      # <value>\r\n)*
      # ]
      # END\r\n
      # |SERVER_ERROR <error message>\r\n)
      def ev_alist_gets(s)
        hash_name, k, _d, vnode, nodes = calc_hash(s[1])
        return forward_and_multi_line_receive(nodes[0], s) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, 0)
        @stats.read_count += 1

        return send_data("END\r\n") unless ddata

        values = SafeMarshal.load(ddata)[0]
        if /(?:^(\d+)$|^(\d+)..((?:-)?\d+)$)/ =~ s[2]
          if ::Regexp.last_match(1)
            return send_data("END\r\n") if values.length <= ::Regexp.last_match(1).to_i

            buf = values[Range.new(::Regexp.last_match(1).to_i, ::Regexp.last_match(1).to_i)]
          else
            buf = values[Range.new(::Regexp.last_match(2).to_i, ::Regexp.last_match(3).to_i)]
          end
        else
          buf = values
        end
        len = values.length
        send_data("VALUE #{s[1]} 0 #{len.to_s.length}\r\n#{len}\r\n")
        buf.each do |val|
          send_data("VALUE #{s[1]} 0 #{val.length}\r\n#{val}\r\n")
        end
        send_data("END\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_gets_with_time <key> [index|range] [forward]\r\n
      #
      # (
      # [VALUE <key> 0 <length of length string>\r\n
      # <length string>\r\n
      # (VALUE <key> 0 <value length>\r\n
      # <value string>\r\n
      # VALUE <key> 0 <value length>\r\n
      # <time string>\r\n)*
      # ]
      # END\r\n
      # |SERVER_ERROR <error message>\r\n)
      def ev_alist_gets_with_time(s)
        hash_name, k, _d, vnode, nodes = calc_hash(s[1])
        return forward_and_multi_line_receive(nodes[0], s) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, 0)
        @stats.read_count += 1

        return send_data("END\r\n") unless ddata

        values, times = SafeMarshal.load(ddata)
        if /(?:^(\d+)$|^(\d+)..((?:-)?\d+)$)/ =~ s[2]
          if ::Regexp.last_match(1)
            return send_data("END\r\n") if values.length <= ::Regexp.last_match(1).to_i

            v_buf = values[Range.new(::Regexp.last_match(1).to_i, ::Regexp.last_match(1).to_i)]
            t_buf = times[Range.new(::Regexp.last_match(1).to_i, ::Regexp.last_match(1).to_i)]
          else
            v_buf = values[Range.new(::Regexp.last_match(2).to_i, ::Regexp.last_match(3).to_i)]
            t_buf = times[Range.new(::Regexp.last_match(2).to_i, ::Regexp.last_match(3).to_i)]
          end
        else
          v_buf = values
          t_buf = times
        end
        len = values.length
        send_data("VALUE #{s[1]} 0 #{len.to_s.length}\r\n#{len}\r\n")
        v_buf.each_with_index do |val, idx|
          send_data("VALUE #{s[1]} 0 #{val.length}\r\n#{val}\r\n")
          send_data("VALUE #{s[1]} 0 #{t_buf[idx].to_s.length}\r\n#{t_buf[idx]}\r\n")
        end
        send_data("END\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_include? <key> <bytes> [forward]\r\n
      # <data block>\r\n
      #
      # (true|false|NOT_FOUND|SERVER_ERROR <error message>)\r\n
      def ev_alist_include?(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        data = read_value(s[2].to_i)
        return forward_and_one_line_receive(nodes[0], s, data) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, d)
        @stats.read_count += 1

        return send_data("NOT_FOUND\r\n") unless ddata

        values = SafeMarshal.load(ddata)[0]
        ret = values.include?(data)

        send_data("#{ret}\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_index <key> <bytes> [forward]\r\n
      # <data block>\r\n
      #
      # (<index>|nil|NOT_FOUND|SERVER_ERROR <error message>)\r\n
      def ev_alist_index(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        data = read_value(s[2].to_i)
        return forward_and_one_line_receive(nodes[0], s, data) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, d)
        @stats.read_count += 1

        return send_data("NOT_FOUND\r\n") unless ddata

        values = SafeMarshal.load(ddata)[0]
        ret = values.index(data)
        if ret
          send_data("#{ret}\r\n")
        else
          send_data("nil\r\n")
        end
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_insert <key> <index> <bytes> [forward]\r\n
      # <data block>\r\n
      #
      # (STORED|NOT_STORED|SERVER_ERROR <error message>)\r\n
      def ev_alist_insert(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        data = read_value(s[3].to_i)
        return forward_and_one_line_receive(nodes[0], s, data) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, d)
        values, times = ddata ? SafeMarshal.load(ddata) : [[], []]

        values.insert(s[2].to_i, data)
        times.insert(s[2].to_i, Time.now.to_i)
        stored = store_list(hash_name, k, d, vnode, nodes, [values, times])
        @stats.write_count += 1
        return send_data("NOT_STORED\r\n") unless stored

        push_to_write_behind(:alist_insert, hash_name, k, data)
        send_data("STORED\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      def ev_alist_sized_prepend(s) = ev_alist_sized_insert(s)

      # alist_sized_insert <key> <array-size> <bytes> [forward]\r\n
      # <data block>\r\n
      #
      # (STORED|NOT_STORED|SERVER_ERROR <error message>)\r\n
      def ev_alist_sized_insert(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        data = read_value(s[3].to_i)
        return forward_and_one_line_receive(nodes[0], s, data) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, d)
        values, times = ddata ? SafeMarshal.load(ddata) : [[], []]

        values.insert(0, data)
        values = values[0..(s[2].to_i - 1)]
        times.insert(0, Time.now.to_i)
        times = times[0..(s[2].to_i - 1)]

        stored = store_list(hash_name, k, d, vnode, nodes, [values, times])
        @stats.write_count += 1
        return send_data("NOT_STORED\r\n") unless stored

        push_to_write_behind(:alist_sized_insert, hash_name, k, data)
        send_data("STORED\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      def ev_alist_delete_and_prepend(s) = ev_alist_swap_and_insert(s)

      # alist_swap_and_insert <key> <bytes> [forward]\r\n
      # <data block>\r\n
      #
      # (STORED|NOT_STORED|SERVER_ERROR <error message>)\r\n
      def ev_alist_swap_and_insert(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        data = read_value(s[2].to_i)
        return forward_and_one_line_receive(nodes[0], s, data) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, d)
        values, times = ddata ? SafeMarshal.load(ddata) : [[], []]

        idx = values.index(data)
        if idx
          values.delete_at(idx)
          times.delete_at(idx)
        end
        values.insert(0, data)
        times.insert(0, Time.now.to_i)

        stored = store_list(hash_name, k, d, vnode, nodes, [values, times])
        @stats.write_count += 1
        return send_data("NOT_STORED\r\n") unless stored

        push_to_write_behind(:alist_swap_and_insert, hash_name, k, data)
        send_data("STORED\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      def ev_alist_sized_delete_and_prepend(s) = ev_alist_swap_and_sized_insert(s)

      # alist_swap_and_sized_insert <key> <array-size> <bytes> [forward]\r\n
      # <data block>\r\n
      #
      # (STORED|NOT_STORED|SERVER_ERROR <error message>)\r\n
      def ev_alist_swap_and_sized_insert(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        data = read_value(s[3].to_i)
        return forward_and_one_line_receive(nodes[0], s, data) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, d)
        values, times = ddata ? SafeMarshal.load(ddata) : [[], []]

        idx = values.index(data)
        if idx
          values.delete_at(idx)
          times.delete_at(idx)
        end
        values.insert(0, data)
        times.insert(0, Time.now.to_i)
        values = values[0..(s[2].to_i - 1)]
        times = times[0..(s[2].to_i - 1)]

        stored = store_list(hash_name, k, d, vnode, nodes, [values, times])
        @stats.write_count += 1
        return send_data("NOT_STORED\r\n") unless stored

        push_to_write_behind(:alist_swap_and_sized_insert, hash_name, k, data)
        send_data("STORED\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_expired_swap_and_insert <key> <expire-time> <bytes> [forward]\r\n
      # <data block>\r\n
      #
      # the data expire-time's ago will be deleated.
      # the unit of the expire-time's is a second.
      # however,as follows when there is a suffix.
      # 'h' as +expire-time+ suffix is hour.
      # 'd' as +expire-time+ suffix is day.
      #
      # (STORED|NOT_STORED|SERVER_ERROR <error message>)\r\n
      def ev_alist_expired_swap_and_insert(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        data = read_value(s[3].to_i)
        return forward_and_one_line_receive(nodes[0], s, data) if nodes[0] != @my_node_id

        et = expired_str_to_i(s[2])
        return send_data("SERVER_ERROR format error in expire-time.\r\n") unless et

        list = to_alist_value_for_write(hash_name, vnode, k, d)
        return send_data("SERVER_ERROR data other than alist's format already exist.\r\n") unless list

        values, times = list

        # @log.debug("#{s[2]} et=#{et}")
        expired_swap(values, times, data, et)

        values.insert(0, data)
        times.insert(0, Time.now.to_i)

        stored = store_list(hash_name, k, d, vnode, nodes, [values, times])
        @stats.write_count += 1
        return send_data("NOT_STORED\r\n") unless stored

        push_to_write_behind(:alist_expired_swap_and_insert, hash_name, k, data)
        send_data("STORED\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_expired_swap_and_sized_insert <key> <expire-time> <array-size> <bytes> [forward]\r\n
      # <data block>\r\n
      #
      # the data expire-time's ago will be deleated.
      # the unit of the expire-time's is a second.
      # however,as follows when there is a suffix.
      # 'h' as +expire-time+ suffix is hour.
      # 'd' as +expire-time+ suffix is day.
      #
      # (STORED|NOT_STORED|SERVER_ERROR <error message>)\r\n
      def ev_alist_expired_swap_and_sized_insert(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        data = read_value(s[4].to_i)
        return forward_and_one_line_receive(nodes[0], s, data) if nodes[0] != @my_node_id

        et = expired_str_to_i(s[2])
        return send_data("SERVER_ERROR format error in expire-time.\r\n") unless et

        list = to_alist_value_for_write(hash_name, vnode, k, d)
        return send_data("SERVER_ERROR data other than alist's format already exist.\r\n") unless list

        values, times = list

        # @log.debug("#{s[2]} et=#{et}")
        expired_swap(values, times, data, et)

        values.insert(0, data)
        values = values[0..(s[3].to_i - 1)]
        times.insert(0, Time.now.to_i)
        times = times[0..(s[3].to_i - 1)]

        stored = store_list(hash_name, k, d, vnode, nodes, [values, times])
        @stats.write_count += 1
        return send_data("NOT_STORED\r\n") unless stored

        push_to_write_behind(:alist_expired_swap_and_sized_insert, hash_name, k, data)
        send_data("STORED\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_join_with_time <key> <bytes> [index|range] [forward]\r\n
      # <separator block>\r\n
      #
      # (
      # [VALUE <key> 0 <length of length string>\r\n
      # <length string>\r\n
      # VALUE <key> 0 <value length>\r\n
      # <value string>\r\n
      # VALUE <key> 0 <value length>\r\n
      # <time string>\r\n]
      # END\r\n
      # |SERVER_ERROR <error message>\r\n)
      def ev_alist_join_with_time(s)
        hash_name, k, _d, vnode, nodes = calc_hash(s[1])
        data = read_value(s[2].to_i)
        return forward_and_multi_line_receive(nodes[0], s, data) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, 0)
        @stats.read_count += 1
        return send_data("END\r\n") unless ddata

        values, times = SafeMarshal.load(ddata)
        if /(?:^(\d+)$|^(\d+)..((?:-)?\d+)$)/ =~ s[3]
          if ::Regexp.last_match(1)
            return send_data("END\r\n") if values.length <= ::Regexp.last_match(1).to_i

            v_buf = values[Range.new(::Regexp.last_match(1).to_i, ::Regexp.last_match(1).to_i)]
            t_buf = times[Range.new(::Regexp.last_match(1).to_i, ::Regexp.last_match(1).to_i)]
          else
            v_buf = values[Range.new(::Regexp.last_match(2).to_i, ::Regexp.last_match(3).to_i)]
            t_buf = times[Range.new(::Regexp.last_match(2).to_i, ::Regexp.last_match(3).to_i)]
          end
        else
          v_buf = values
          t_buf = times
        end
        len = values.length
        v_ret = v_buf.join(data)
        t_ret = t_buf.join(data)
        send_data("VALUE #{s[1]} 0 #{len.to_s.length}\r\n#{len}\r\n")
        send_data("VALUE #{s[1]} 0 #{v_ret.length}\r\n#{v_ret}\r\n")
        send_data("VALUE #{s[1]} 0 #{t_ret.length}\r\n#{t_ret}\r\nEND\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_join <key> <bytes> [index|range] [forward]\r\n
      # <separator block>\r\n
      #
      # (
      # [VALUE <key> 0 <length of length string>\r\n
      # <length string>\r\n
      # VALUE <key> 0 <value length>\r\n
      # <value>\r\n]
      # END\r\n
      # |SERVER_ERROR <error message>\r\n)
      def ev_alist_join(s)
        hash_name, k, _d, vnode, nodes = calc_hash(s[1])
        data = read_value(s[2].to_i)
        return forward_and_multi_line_receive(nodes[0], s, data) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, 0)
        @stats.read_count += 1

        return send_data("END\r\n") unless ddata

        values = SafeMarshal.load(ddata)[0]
        if /(?:^(\d+)$|^(\d+)..((?:-)?\d+)$)/ =~ s[3]
          if ::Regexp.last_match(1)
            return send_data("END\r\n") if values.length <= ::Regexp.last_match(1).to_i

            buf = values[Range.new(::Regexp.last_match(1).to_i, ::Regexp.last_match(1).to_i)]
          else
            buf = values[Range.new(::Regexp.last_match(2).to_i, ::Regexp.last_match(3).to_i)]
          end
        else
          buf = values
        end
        len = values.length
        ret = buf.join(data)
        send_data("VALUE #{s[1]} 0 #{len.to_s.length}\r\n#{len}\r\n")
        send_data("VALUE #{s[1]} 0 #{ret.length}\r\n#{ret}\r\nEND\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_to_json <key> [index|range] [forward]\r\n
      #
      # (
      # VALUE <key> 0 <length of json string>\r\n
      # <json string>\r\n
      # END\r\n
      # |SERVER_ERROR <error message>\r\n)
      def ev_alist_to_json(s)
        hash_name, k, _d, vnode, nodes = calc_hash(s[1])
        return forward_and_multi_line_receive(nodes[0], s) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, 0)
        @stats.read_count += 1

        return send_data("END\r\n") unless ddata

        values = SafeMarshal.load(ddata)[0]
        ret = nil
        if /(?:^(\d+)$|^(\d+)..((?:-)?\d+)$)/ =~ s[2]
          if ::Regexp.last_match(1)
            return send_data("END\r\n") if values.length <= ::Regexp.last_match(1).to_i

            ret = JSON.generate(values[Range.new(::Regexp.last_match(1).to_i, ::Regexp.last_match(1).to_i)])
          else
            ret = JSON.generate(values[Range.new(::Regexp.last_match(2).to_i, ::Regexp.last_match(3).to_i)])
          end
        else
          ret = JSON.generate(values)
        end
        send_data("VALUE #{s[1]} 0 #{ret.length}\r\n#{ret}\r\nEND\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_last <key> [forward]\r\n
      #
      # (
      # [VALUE <key> 0 <value length>\r\n
      # <value>\r\n]
      # END\r\n
      # |SERVER_ERROR <error message>\r\n)
      def ev_alist_last(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        return forward_and_multi_line_receive(nodes[0], s) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, d)
        @stats.read_count += 1

        return send_data("END\r\n") unless ddata

        values = SafeMarshal.load(ddata)[0]
        return send_data("END\r\n") if values.length == 0

        ret = values.last
        send_data("VALUE #{s[1]} 0 #{ret.length}\r\n#{ret}\r\nEND\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_length <key> [forward]\r\n
      #
      # (<length>|NOT_FOUND|SERVER_ERROR <error message>)\r\n
      def ev_alist_length(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        return forward_and_one_line_receive(nodes[0], s) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, d)
        @stats.read_count += 1

        return send_data("NOT_FOUND\r\n") unless ddata

        values = SafeMarshal.load(ddata)[0]
        ret = values.length
        send_data("#{ret}\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_pop <key> [forward]\r\n
      #
      # (
      # [VALUE <key> 0 <value length>\r\n
      # <value>\r\n]
      # END
      # |NOT_STORED|SERVER_ERROR <error message>)\r\n
      def ev_alist_pop(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        return forward_and_multi_line_receive(nodes[0], s) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, d)
        return send_data("END\r\n") unless ddata

        values, times = SafeMarshal.load(ddata)
        return send_data("END\r\n") if values.length == 0

        retv = values.pop
        times.pop
        stored = store_list(hash_name, k, d, vnode, nodes, [values, times])
        @stats.read_count += 1
        @stats.write_count += 1
        return send_data("NOT_STORED\r\n") unless stored

        send_data("VALUE #{s[1]} 0 #{retv.length}\r\n#{retv}\r\nEND\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_push <key> <bytes> [forward]\r\n
      # <data block>\r\n
      #
      # (STORED|NOT_STORED|SERVER_ERROR <error message>)\r\n
      def ev_alist_push(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        data = read_value(s[2].to_i)
        return forward_and_one_line_receive(nodes[0], s, data) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, d)
        values, times = ddata ? SafeMarshal.load(ddata) : [[], []]

        values.push(data)
        times.push(Time.now.to_i)
        stored = store_list(hash_name, k, d, vnode, nodes, [values, times])
        @stats.write_count += 1
        return send_data("NOT_STORED\r\n") unless stored

        push_to_write_behind(:alist_push, hash_name, k, data)
        send_data("STORED\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_sized_push <key> <array-size> <bytes> [forward]\r\n
      # <data block>\r\n
      #
      # (STORED|NOT_PUSHED|NOT_STORED|SERVER_ERROR <error message>)\r\n
      def ev_alist_sized_push(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        data = read_value(s[3].to_i)
        return forward_and_one_line_receive(nodes[0], s, data) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, d)
        values, times = ddata ? SafeMarshal.load(ddata) : [[], []]

        max = s[2].to_i
        return send_data("NOT_PUSHED\r\n") if values.length >= max

        values.push(data)
        values = values[0..(max - 1)]
        times.push(Time.now.to_i)
        times = times[0..(max - 1)]

        stored = store_list(hash_name, k, d, vnode, nodes, [values, times])
        @stats.write_count += 1
        return send_data("NOT_STORED\r\n") unless stored

        push_to_write_behind(:alist_sized_push, hash_name, k, data)
        send_data("STORED\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_swap_and_push <key> <bytes> [forward]\r\n
      # <data block>\r\n
      #
      # (STORED|NOT_STORED|SERVER_ERROR <error message>)\r\n
      def ev_alist_swap_and_push(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        data = read_value(s[2].to_i)
        return forward_and_one_line_receive(nodes[0], s, data) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, d)
        values, times = ddata ? SafeMarshal.load(ddata) : [[], []]

        idx = values.index(data)
        if idx
          values.delete_at(idx)
          times.delete_at(idx)
        end
        values.push(data)
        times.push(Time.now.to_i)

        stored = store_list(hash_name, k, d, vnode, nodes, [values, times])
        @stats.write_count += 1
        return send_data("NOT_STORED\r\n") unless stored

        push_to_write_behind(:alist_swap_and_push, hash_name, k, data)
        send_data("STORED\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_swap_and_sized_push <key> <array-size> <bytes> [forward]\r\n
      # <data block>\r\n
      #
      # (STORED|NOT_PUSHED|NOT_STORED|SERVER_ERROR <error message>)\r\n
      def ev_alist_swap_and_sized_push(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        data = read_value(s[3].to_i)
        return forward_and_one_line_receive(nodes[0], s, data) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, d)
        values, times = ddata ? SafeMarshal.load(ddata) : [[], []]

        max = s[2].to_i

        idx = values.index(data)
        if idx
          values.delete_at(idx)
          times.delete_at(idx)
        elsif values.length >= max
          return send_data("NOT_PUSHED\r\n")
        end
        values.push(data)
        values = values[0..(max - 1)]
        times.push(Time.now.to_i)
        times = times[0..(max - 1)]

        stored = store_list(hash_name, k, d, vnode, nodes, [values, times])
        @stats.write_count += 1
        return send_data("NOT_STORED\r\n") unless stored

        push_to_write_behind(:alist_swap_and_sized_push, hash_name, k, data)
        send_data("STORED\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_expired_swap_and_push <key> <expire-time> <bytes> [forward]\r\n
      # <data block>\r\n
      #
      # the data expire-time's ago will be deleated.
      # the unit of the expire-time's is a second.
      # however,as follows when there is a suffix.
      # 'h' as +expire-time+ suffix is hour.
      # 'd' as +expire-time+ suffix is day.
      #
      # (STORED|NOT_STORED|SERVER_ERROR <error message>)\r\n
      def ev_alist_expired_swap_and_push(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        data = read_value(s[3].to_i)
        return forward_and_one_line_receive(nodes[0], s, data) if nodes[0] != @my_node_id

        et = expired_str_to_i(s[2])
        return send_data("SERVER_ERROR format error in expire-time.\r\n") unless et

        list = to_alist_value_for_write(hash_name, vnode, k, d)
        return send_data("SERVER_ERROR data other than alist's format already exist.\r\n") unless list

        values, times = list

        # @log.debug("#{s[2]} et=#{et}")
        expired_swap(values, times, data, et)

        values.push(data)
        times.push(Time.now.to_i)

        stored = store_list(hash_name, k, d, vnode, nodes, [values, times])
        @stats.write_count += 1
        return send_data("NOT_STORED\r\n") unless stored

        push_to_write_behind(:alist_expired_swap_and_push, hash_name, k, data)
        send_data("STORED\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_expired_swap_and_sized_push <key> <expire-time> <array-size> <bytes> [forward]\r\n
      # <data block>\r\n
      #
      # the data expire-time's ago will be deleated.
      # the unit of the expire-time's is a second.
      # however,as follows when there is a suffix.
      # 'h' as +expire-time+ suffix is hour.
      # 'd' as +expire-time+ suffix is day.
      #
      # (STORED|NOT_STORED|SERVER_ERROR <error message>)\r\n
      def ev_alist_expired_swap_and_sized_push(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        data = read_value(s[4].to_i)
        return forward_and_one_line_receive(nodes[0], s, data) if nodes[0] != @my_node_id

        et = expired_str_to_i(s[2])
        return send_data("SERVER_ERROR format error in expire-time.\r\n") unless et

        list = to_alist_value_for_write(hash_name, vnode, k, d)
        return send_data("SERVER_ERROR data other than alist's format already exist.\r\n") unless list

        values, times = list

        # @log.debug("#{s[2]} et=#{et}")
        expired_swap(values, times, data, et)

        max = s[3].to_i
        return send_data("NOT_PUSHED\r\n") if values.length >= max

        values.push(data)
        values = values[0..(max - 1)]
        times.push(Time.now.to_i)
        times = times[0..(max - 1)]

        stored = store_list(hash_name, k, d, vnode, nodes, [values, times])
        @stats.write_count += 1
        return send_data("NOT_STORED\r\n") unless stored

        push_to_write_behind(:alist_expired_swap_and_sized_push, hash_name, k, data)
        send_data("STORED\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_update_at <key> <index> <bytes>[forward]\r\n
      # <data block>\r\n
      #
      # (STORED|NOT_STORED|NOT_FOUND|SERVER_ERROR <error message>)\r\n
      def ev_alist_update_at(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        data = read_value(s[3].to_i)
        return forward_and_one_line_receive(nodes[0], s, data) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, d)
        return send_data("NOT_FOUND\r\n") unless ddata

        values, times = SafeMarshal.load(ddata)

        idx = s[2].to_i
        return send_data("NOT_FOUND\r\n") if idx < 0 || values.length <= idx

        values[idx] = data
        times[idx] = Time.now.to_i

        stored = store_list(hash_name, k, d, vnode, nodes, [values, times])
        @stats.write_count += 1
        return send_data("NOT_STORED\r\n") unless stored

        push_to_write_behind(:alist_update_at, hash_name, k, data)
        send_data("STORED\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_shift <key> [forward]\r\n
      #
      # (
      # [VALUE <key> 0 <value length>\r\n
      # <value>\r\n]
      # END
      # |NOT_STORED|SERVER_ERROR <error message>)\r\n
      def ev_alist_shift(s)
        hash_name, k, d, vnode, nodes = calc_hash(s[1])
        return forward_and_multi_line_receive(nodes[0], s) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, d)
        return send_data("END\r\n") unless ddata

        values, times = SafeMarshal.load(ddata)
        return send_data("END\r\n") if values.length == 0

        retv = values.shift
        times.shift
        stored = store_list(hash_name, k, d, vnode, nodes, [values, times])
        @stats.read_count += 1
        @stats.write_count += 1
        return send_data("NOT_STORED\r\n") unless stored

        send_data("VALUE #{s[1]} 0 #{retv.length}\r\n#{retv}\r\nEND\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_to_s <key> [index|range] [forward]\r\n
      #
      # (
      # [VALUE <key> 0 <length of length string>\r\n
      # <length string>\r\n
      # VALUE <key> 0 <value length>\r\n
      # <value>\r\n]
      # END\r\n
      # |SERVER_ERROR <error message>\r\n)
      def ev_alist_to_s(s)
        hash_name, k, _d, vnode, nodes = calc_hash(s[1])
        return forward_and_multi_line_receive(nodes[0], s) if nodes[0] != @my_node_id

        ddata = @storages[hash_name].get(vnode, k, 0)
        @stats.read_count += 1

        return send_data("END\r\n") unless ddata

        list = to_alist_value(ddata)
        return send_data("SERVER_ERROR data other than alist's format already exist.\r\n") unless list

        values, _times = list

        ret = if /(?:^(\d+)$|^(\d+)..((?:-)?\d+)$)/ =~ s[2]
                if ::Regexp.last_match(1)
                  values[Range.new(::Regexp.last_match(1).to_i, ::Regexp.last_match(1).to_i)].to_s
                else
                  values[Range.new(::Regexp.last_match(2).to_i, ::Regexp.last_match(3).to_i)].to_s
                end
              else
                values.to_s
              end
        len = values.length
        send_data("VALUE #{s[1]} 0 #{len.to_s.length}\r\n#{len}\r\n")
        send_data("VALUE #{s[1]} 0 #{ret.length}\r\n#{ret}\r\nEND\r\n")
      rescue StandardError => e
        reply_server_error(e)
      end

      # alist_spushv <hash-name> <vnode-id>
      # src                                   dst
      #  |  ['alist_spushv' <hash_name> <vnode>\r\n]->|
      #  |<-['READY'\r\n]                      |
      #  |                       [<dumpdata>]->|
      #  |                             :       |
      #  |                             :       |
      #  |                    [<end of dump>]->|
      #  |<-['STORED'\r\n]                     |
      def ev_alist_spushv(s)
        if s.length != 3
          @log.error("#{__method__}:wrong number of arguments(#{s})")
          return send_data("CLIENT_ERROR Wrong number of arguments.\r\n")
        end
        if @stats.spushv_protection
          @log.info("#{__method__}:In spushv_protection")
          return send_data("SERVER_ERROR In spushv_protection.\r\n")
        end
        @stats.run_receive_a_vnode["#{s[1]}_#{s[2]}"] = true

        $roma.stop_clean_up

        send_data("READY\r\n")

        count = 0
        loop do
          context_bin = read_bytes(20, 100)
          vnode, last, clock, expire_time, klen = context_bin.unpack('NNNNN')
          break if klen == 0 # end of dump ?

          k = read_bytes(klen)
          vlen_bin = read_bytes(4, 100)
          vlen, =  vlen_bin.unpack('N')
          v = read_bytes(vlen, 100)
          val = to_alist_value(v)
          if val
            # @log.debug("listdata #{vnode} #{k} #{val.inspect}")
            count += 1 if merge_list(s[1], vnode, last, clock, expire_time, k, v, val)
          elsif @storages[s[1]].load_stream_dump(vnode, last, clock, expire_time, k, v)
            # @log.debug("not listdata #{vnode} #{k} #{val}")
            count += 1
          end
        end
        if @stats.spushv_protection
          @log.info("#{__method__}:Canceled because of spushv_protection")
          send_data("CANCELED\r\n")
        else
          send_data("STORED\r\n")
        end
        @log.debug("alist #{count} keys loaded.")
      rescue Roma::Storage::StorageException => e
        @log.error("#{e.inspect} #{$@}")
        close_connection
        if Roma.config.storage.exception_action == :shutdown
          @log.error("#{__method__}:The server will stop")
          @stop_event_loop = true
        end
      rescue StandardError => e
        @log.error("#{e}\n#{$@}")
      ensure
        @stats.run_receive_a_vnode.delete("#{s[1]}_#{s[2]}") if s.length == 3
      end

      private

      # Deletes +rcv_val+ and the values added +et+ seconds ago or earlier
      # from the list.
      def expired_swap(values, times, rcv_val, et)
        del = [rcv_val]
        expire_time = Time.now.to_i - et
        times.each_with_index do |t, i|
          del << values[i] if expire_time >= t
        end
        del.each do |dat|
          i = values.index(dat)
          if i
            values.delete_at(i)
            times.delete_at(i)
          end
        end
      end

      def expired_str_to_i(s)
        return unless s.upcase =~ /(\d+)([H|D])?/

        t = ::Regexp.last_match(1).to_i
        if ::Regexp.last_match(2) == 'D'
          t *= 86_400
        elsif ::Regexp.last_match(2) == 'H'
          t *= 3600
        end
        t
      end

      def to_alist_value_for_write(hash_name, vnode, k, d)
        ddata = @storages[hash_name].get(vnode, k, d)
        ddata ? to_alist_value(ddata) : [[], []]
      end

      def to_alist_value(v)
        # Marshal.dump([[],[]])[0..3].unpack("cc a c")
        # => [4, 8, "[", 7]
        # marshal format version 4.8
        # array object "["
        # array.length fixednum format 7 (7-5=2)
        return nil if v.nil? || v[0..3] != "\x04\b[\a"

        val = SafeMarshal.load(v)
        return val if val[0].instance_of?(Array) && val[1].instance_of?(Array)

        nil
      rescue StandardError
        nil
      end

      def merge_list(hash_name, vnode, last, clock, expire_time, k, v, val)
        ddata = @storages[hash_name].get(vnode, k, 0)
        if ddata
          lv = SafeMarshal.load(ddata)
          lv[0].each do |buf|
            idx = val[0].index(buf)
            if idx
              val[0].delete_at(idx)
              val[1].delete_at(idx)
            end
          end
          lv[0] += val[0]
          lv[1] += val[1]
          @storages[hash_name].set(vnode, k, 0, expire_time, Marshal.dump(lv))
        else
          @storages[hash_name].load_stream_dump(vnode, last, clock, expire_time, k, v)
        end
      end

      def calc_hash(key)
        k, hash_name = key.split("\e")
        hash_name ||= @default_hash_name
        d = @routing_table.digest(k)
        vnode = @routing_table.vnode_id(d)
        nodes = @routing_table.search_nodes_for_write(vnode)
        [hash_name, k, d, vnode, nodes]
      end

      # Stores +list+ for the key, which never expires, and replicates it.
      # Returns nil or false if the storage didn't store it.
      def store_list(hash_name, k, d, vnode, nodes, list)
        ret = @storages[hash_name].set(vnode, k, d, NEVER_EXPIRES, Marshal.dump(list))
        return ret unless ret

        _vnode, _last, clock, _expire_time, value = ret
        redundant(nodes[1..], hash_name, k, d, clock, NEVER_EXPIRES, value)
        ret
      end
    end
  end
end
