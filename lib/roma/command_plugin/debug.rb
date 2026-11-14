require 'roma/command_plugin'

module Roma
  module CommandPlugin
    module Debug
      include ::Roma::CommandPlugin

      # DANGER!!
      def ev_eval(s)
        cmd = s[1..-1].join(' ')
        @log.debug("eval(#{cmd})")
        send_data("#{eval(cmd)}\r\n")
      rescue Exception => e
        send_data("#{e}\r\n")
      end

      private

      # Tells where +key+ is, for eval: eval key_info('key')
      def key_info(key)
        d = @routing_table.digest(key)
        vnode = @routing_table.vnode_id(d)
        nodes = @routing_table.search_nodes_for_write(vnode)
        s = format("d = %s 0x%x\r\n", d, d)
        send_data(s)
        s = format("vn = %s 0x%x\r\n", vnode, vnode)
        send_data(s)
        send_data("nodes = #{nodes.inspect}\r\n")
        'END'
      end
    end
  end
end
