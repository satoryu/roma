require 'roma/command_plugin'

module Roma
  module CommandPlugin

    module PluginDebug
      include ::Roma::CommandPlugin

      # DANGER!!
      def ev_eval(s)
        cmd = s[1..-1].join(' ')
        @log.debug("eval(#{cmd})")
        send_data("#{eval(cmd)}\r\n")
      rescue Exception =>e
        send_data("#{e}\r\n")
      end

      def get_key_info(key)
        d = Digest::SHA1.hexdigest(key).hex % @routing_table.hash_space_size
        vnode = @routing_table.get_vnode_id(d)
        nodes = @routing_table.search_nodes_for_write(vnode)
        s = sprintf("d = %s 0x%x\r\n",d,d)
        send_data(s)
        s = sprintf("vn = %s 0x%x\r\n",vnode,vnode)
        send_data(s)
        send_data("nodes = #{nodes.inspect}\r\n")
        "END"
      end

    end
  end
end
