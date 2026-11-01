require 'roma/messaging/con_pool'

module Roma
  module Command

    module UtilCommandReceiver

      def send_cmd(node_id, cmd)
        con = get_connection(node_id)
        con.send(cmd)
        res = con.gets
        if res == nil
          @routing_table.proc_failed(node_id)
          return nil
        elsif res.start_with?("ERROR") == false
          @routing_table.proc_succeed(node_id)
          return_connection(node_id, con)
        end
        res.chomp
      rescue => e
        @routing_table.proc_failed(node_id)
        @log.error("#{e}\n#{$@}")
        nil
      end

      def broadcast_cmd(cmd)
        res={}
        @routing_table.nodes.each{|node_id|
          res[node_id] = send_cmd(node_id,cmd) if node_id != @stats.my_node_id
        }
        res
      end

      def async_send_cmd(node_id, cmd)
        con = Roma::Messaging::ConPool.instance.get_connection(node_id)
        con.write(cmd)
        res = con.gets
        Roma::Messaging::ConPool.instance.return_connection(node_id, con)
        if res
          res.chomp!
          @routing_table.proc_succeed(node_id)
        else
          @routing_table.proc_failed(node_id)
        end
        res
      rescue => e
        @routing_table.proc_failed(node_id)
        @log.error("#{e}\n#{$@}")
        nil
      end

      def async_broadcast_cmd(cmd,without_node_ids=nil)
        without_node_ids=[@stats.my_node_id] unless without_node_ids
        res = {}
        @routing_table.nodes.each{ |node_id|
          res[node_id] = async_send_cmd(node_id,cmd) unless without_node_ids.include?(node_id)
        }
        res
      rescue => e
        @log.error("#{e}\n#{$@}")
        nil
      end

      # change to actual time for a memcached's expire time value
      def chg_time_expt(expire_time)
        if expire_time == 0
          expire_time = 0x7fffffff
        elsif expire_time < 2592000
          expire_time += Time.now.to_i
        end
        expire_time
      end

    end # module UtilCommandReceiver

  end # module Command
end # module Roma
