require 'roma/command_plugin'
require 'roma/safe_marshal'
require 'json'
require 'roma/command/definition'

module Roma
  module CommandPlugin
    module Mapcount
      include ::Roma::CommandPlugin
      include ::Roma::Command::Definition

      # mapcount_countup <key> <expire_time> <sub_keys_length>\r\n
      # <sub_keys> \r\n
      #
      # (
      # VALUE <key> 0 <length of json string>\r\n
      # <json string>\r\n
      # END\r\n
      # |CLIENT_ERROR invalid sub_keys format: <sub_keys>\r\n
      # |SERVER_ERROR <error message>\r\n)
      def_write_command_with_key_value :mapcount_countup, 3, :multi_line do |ctx|
        countup(ctx, :json)
      end

      # mapcount_countup_ms <key> <expire_time> <sub_keys_length>\r\n
      # <sub_keys> \r\n
      #
      # (
      # VALUE <key> 0 <length of Marshal string>\r\n
      # <Marshal string>\r\n
      # END\r\n
      # |CLIENT_ERROR invalid sub_keys format: <sub_keys>\r\n
      # |SERVER_ERROR <error message>\r\n)
      def_write_command_with_key_value :mapcount_countup_ms, 3, :multi_line do |ctx|
        countup(ctx, :marshal)
      end

      # mapcount_update <key> <expire_time> <sub_keys_length>\r\n
      # <sub_keys>\r\n
      #
      # (
      # [VALUE <key> 0 <length of json string>\r\n
      # <json string>\r\n]
      # END\r\n
      # |SERVER_ERROR <error message>\r\n)
      def_write_command_with_key_value :mapcount_update, 3, :multi_line do |ctx|
        update(ctx, :json)
      end

      # mapcount_update_ms <key> <expire_time> <sub_keys_length>\r\n
      # <sub_keys>\r\n
      #
      # (
      # [VALUE <key> 0 <length of Marshal string>\r\n
      # <Marshal string>\r\n]
      # END\r\n
      # |SERVER_ERROR <error message>\r\n)
      def_write_command_with_key_value :mapcount_update_ms, 3, :multi_line do |ctx|
        update(ctx, :marshal)
      end

      # mapcount_get <key> 0 <sub_keys_str_len>\r\n
      # <sub_keys>\r\n
      #
      # (
      # [VALUE <key> 0 <length of json string>\r\n
      # <json string>\r\n]
      # END\r\n
      # |SERVER_ERROR <error message>\r\n)
      def_read_command_with_key_value :mapcount_get, 3, :multi_line do |ctx|
        get(ctx, :json)
      end

      # mapcount_get_ms <key> 0 <sub_keys_str_len>\r\n
      # <sub_keys>\r\n
      #
      # (
      # [VALUE <key> 0 <length of Marshal string>\r\n
      # <Marshal string>\r\n]
      # END\r\n
      # |SERVER_ERROR <error message>\r\n)
      def_read_command_with_key_value :mapcount_get_ms, 3, :multi_line do |ctx|
        get(ctx, :marshal)
      end

      private

      def countup(ctx, stype)
        v = {}
        v = data_load(ctx.stored.value) if ctx.stored

        args = ctx.params.value.split(/\s*,\s*/)
        args.each do |arg|
          raise ClientError, "invalid sub_keys format: #{ctx.params.value}" unless arg =~ /^([A-Za-z0-9]+)(:(-?\d+))?$/

          key = ::Regexp.last_match(1)
          count = 1
          count = ::Regexp.last_match(3).to_i if ::Regexp.last_match(3)
          v[key] ||= 0
          v[key] += count
        end

        v['last_updated_date'] = Time.now.strftime(DATE_FORMAT)
        expire_time = chg_time_expt(ctx.argv[2].to_i)

        ret_str = return_str(v, stype)
        ret_msg = "VALUE #{ctx.params.key} 0 #{ret_str.length}\r\n#{ret_str}\r\nEND"
        [0, expire_time, Marshal.dump(v), :write, ret_msg]
      end

      def update(ctx, stype)
        unless ctx.stored
          send_data("END\r\n")
          return
        end
        v = data_load(ctx.stored.value)
        v['last_updated_date'] = Time.now.strftime(DATE_FORMAT)

        if v.is_a?(Hash)
          args = ctx.params.value.split(/\s*,\s*/)
          if args.count == 0
            ret = return_str(v, stype)
          else
            ret = {}
            ret['last_updated_date'] = v['last_updated_date']
            args.each do |arg|
              ret[arg] = v[arg] unless v[arg].nil?
            end
            ret = return_str(ret, stype)
          end
        end

        expire_time = chg_time_expt(ctx.argv[2].to_i)

        ret_msg = "VALUE #{ctx.params.key} 0 #{ret.length}\r\n#{ret}\r\nEND"
        [0, expire_time, Marshal.dump(v), :write, ret_msg]
      end

      def get(ctx, stype)
        ret = nil
        if ctx.stored
          ret_val = data_load(ctx.stored.value)

          if ret_val.is_a?(Hash)
            args = ctx.params.value.split(/\s*,\s*/)
            if args.count == 0
              ret = return_str(ret_val, stype)
            else
              ret = {}
              ret['last_updated_date'] = ret_val['last_updated_date']
              args.each do |arg|
                ret[arg] = ret_val[arg] unless ret_val[arg].nil?
              end
              ret = return_str(ret, stype)
            end
          end
        end

        send_data("VALUE #{ctx.params.key} 0 #{ret.length}\r\n#{ret}\r\n") if ret
        send_data("END\r\n")
      end

      def return_str(data, stype)
        return Marshal.dump(data) if stype == :marshal

        data.to_json
      end

      def data_load(data)
        SafeMarshal.load(data)
      rescue StandardError => e
        msg = "SERVER_ERROR #{e} #{$@}".tr("\r\n", ' ')
        send_data("#{msg}\r\n")
        @log.error("#{e} #{$@}")
      end

      DATE_FORMAT = '%Y-%m-%dT%H:%M:%S +00'

      PLUGIN_MAPCOUNT_VERSION = '1.0.1'
    end
  end
end
